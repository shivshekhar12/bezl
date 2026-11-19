import Foundation
import Testing
@testable import BezlCore

/// Synthetic signals only — no audio files in the repo.
enum Signals {
    static let sampleRate = 48_000.0

    /// Deterministic white noise in -1...1.
    static func noise(count: Int, amplitude: Double, seed: UInt64 = 7) -> [Float] {
        var rng = SplitMix64(seed: seed)
        return (0..<count).map { _ in Float((rng.nextUnit() * 2 - 1) * amplitude) }
    }

    /// Kick-like bursts: 60 Hz sine, 50 ms, fast attack, exponential decay, at `bpm`, over noise.
    static func clickTrack(bpm: Double, seconds: Double, gain: Double = 0.8,
                           noiseDB: Double = -30, seed: UInt64 = 7) -> (samples: [Float], beats: [Double]) {
        let n = Int(seconds * sampleRate)
        var out = noise(count: n, amplitude: pow(10, noiseDB / 20) * gain / 0.8, seed: seed)
        let period = 60 / bpm
        var beats: [Double] = []
        var t = 0.5
        while t < seconds - 0.1 {
            beats.append(t)
            let start = Int(t * sampleRate)
            let length = Int(0.05 * sampleRate)
            for i in 0..<length where start + i < n {
                let time = Double(i) / sampleRate
                let env = min(1, time / 0.002) * exp(-time / 0.015)
                out[start + i] += Float(gain * env * sin(2 * .pi * 60 * time))
            }
            t += period
        }
        return (out, beats)
    }

    static func sine(freq: Double, seconds: Double, amplitude: Double) -> [Float] {
        (0..<Int(seconds * sampleRate)).map { Float(amplitude * sin(2 * .pi * freq * Double($0) / sampleRate)) }
    }
}

/// Feeds a signal in realistic 480-sample chunks (10 ms device buffers).
func run(_ engine: BeatEngine, _ samples: [Float], chunk: Int = 480) {
    var i = 0
    while i < samples.count {
        let end = min(i + chunk, samples.count)
        samples[i..<end].withUnsafeBufferPointer { engine.process($0) }
        i = end
    }
}

/// Matches detected onset times to true beats within `tolerance`.
func score(detected: [Double], truth: [Double], tolerance: Double) -> (hits: Int, falsePositives: Int, maxError: Double) {
    var used = Set<Int>()
    var hits = 0
    var maxError = 0.0
    for b in truth {
        if let (idx, t) = detected.enumerated().filter({ !used.contains($0.offset) })
            .min(by: { abs($0.element - b) < abs($1.element - b) }), abs(t - b) <= tolerance {
            used.insert(idx)
            hits += 1
            maxError = max(maxError, abs(t - b))
        }
    }
    return (hits, detected.count - used.count, maxError)
}

@Suite struct BeatEngineTests {
    /// The engine reports the time of the analysis frame END; a 1024-sample frame lags the
    /// burst onset by up to one frame. Compensate when comparing to ground truth.
    static let frameLatency = 1024.0 / Signals.sampleRate

    @Test func detectsClickTrackAt120BPM() {
        let (samples, beats) = Signals.clickTrack(bpm: 120, seconds: 20)
        let engine = BeatEngine(sampleRate: Signals.sampleRate)
        run(engine, samples)
        let detected = engine.onsetTimes.map { $0 - Self.frameLatency / 2 }
        let s = score(detected: detected, truth: beats, tolerance: 0.025)
        #expect(Double(s.hits) >= 0.95 * Double(beats.count), "hits \(s.hits)/\(beats.count)")
        #expect(Double(s.falsePositives) < 0.05 * Double(beats.count), "false positives \(s.falsePositives)")
    }

    @Test func detectsFastTempo() {
        let (samples, beats) = Signals.clickTrack(bpm: 174, seconds: 15)
        let engine = BeatEngine(sampleRate: Signals.sampleRate)
        run(engine, samples)
        let detected = engine.onsetTimes.map { $0 - Self.frameLatency / 2 }
        let s = score(detected: detected, truth: beats, tolerance: 0.025)
        #expect(Double(s.hits) >= 0.95 * Double(beats.count), "hits \(s.hits)/\(beats.count)")
        #expect(Double(s.falsePositives) < 0.05 * Double(beats.count))
    }

    @Test func loudAndQuietTracksMatch() {
        let loud = Signals.clickTrack(bpm: 120, seconds: 12, gain: 0.9)
        let quiet = Signals.clickTrack(bpm: 120, seconds: 12, gain: 0.05)
        let a = BeatEngine(sampleRate: Signals.sampleRate)
        let b = BeatEngine(sampleRate: Signals.sampleRate)
        run(a, loud.samples)
        run(b, quiet.samples)
        #expect(abs(a.onsetCount - b.onsetCount) <= 1, "loud \(a.onsetCount) vs quiet \(b.onsetCount)")
        #expect(a.onsetCount >= Int(0.95 * Double(loud.beats.count)))
    }

    @Test func steadySineHasNoOnsets() {
        let engine = BeatEngine(sampleRate: Signals.sampleRate)
        let samples = Signals.sine(freq: 80, seconds: 10, amplitude: 0.5)
        run(engine, Array(samples.prefix(Int(Signals.sampleRate))))   // 1 s warm-up
        let before = engine.onsetCount
        run(engine, Array(samples.dropFirst(Int(Signals.sampleRate))))
        #expect(engine.onsetCount - before == 0)
    }

    @Test func steadyNoiseRarelyTriggers() {
        let engine = BeatEngine(sampleRate: Signals.sampleRate)
        let samples = Signals.noise(count: Int(20 * Signals.sampleRate), amplitude: 0.3)
        run(engine, samples)
        // Pure noise has no beat; allow at most one stray pulse every 2 seconds.
        #expect(engine.onsetCount <= 10, "onsets on noise: \(engine.onsetCount)")
    }

    @Test func silenceIsDetected() {
        let engine = BeatEngine(sampleRate: Signals.sampleRate)
        let (music, _) = Signals.clickTrack(bpm: 120, seconds: 3)
        run(engine, music)
        #expect(engine.state.isSilent == false)
        run(engine, [Float](repeating: 0, count: Int(4 * Signals.sampleRate)))
        #expect(engine.state.isSilent == false, "should hold for 5 s")
        run(engine, [Float](repeating: 0, count: Int(1.5 * Signals.sampleRate)))
        #expect(engine.state.isSilent == true)
        #expect(engine.state.level < 0.01)
        #expect(engine.state.pulse < 0.01)
    }

    @Test func pulseSpikesAndDecays() {
        let engine = BeatEngine(sampleRate: Signals.sampleRate)
        let (samples, _) = Signals.clickTrack(bpm: 60, seconds: 6)
        var maxPulse = 0.0
        var i = 0
        while i < samples.count {
            let end = min(i + 480, samples.count)
            let s = samples[i..<end].withUnsafeBufferPointer { engine.process($0) }
            maxPulse = max(maxPulse, s.pulse)
            i = end
        }
        #expect(maxPulse > 0.3)
        // 0.5 s after the last beat (at 5.5 s), the pulse has decayed well below its peak.
        #expect(engine.state.pulse < 0.2)
    }

    @Test func chunkSizeDoesNotMatter() {
        let (samples, _) = Signals.clickTrack(bpm: 128, seconds: 8)
        let a = BeatEngine(sampleRate: Signals.sampleRate)
        let b = BeatEngine(sampleRate: Signals.sampleRate)
        run(a, samples, chunk: 128)
        run(b, samples, chunk: 4096)
        #expect(a.onsetTimes == b.onsetTimes)
    }

    @Test func worksAt44_1kHz() {
        let sr = 44_100.0
        let engine = BeatEngine(sampleRate: sr)
        // Resample the 48k click track crudely by regenerating at 44.1k.
        let period = 0.5
        var samples = [Float](repeating: 0, count: Int(10 * sr))
        var beats: [Double] = []
        var t = 0.5
        while t < 9.9 {
            beats.append(t)
            let start = Int(t * sr)
            for i in 0..<Int(0.05 * sr) where start + i < samples.count {
                let time = Double(i) / sr
                samples[start + i] = Float(0.8 * min(1, time / 0.002) * exp(-time / 0.015) * sin(2 * .pi * 60 * time))
            }
            t += period
        }
        run(engine, samples)
        #expect(Double(engine.onsetCount) >= 0.95 * Double(beats.count))
        #expect(engine.onsetCount <= beats.count + 1)
    }

    @Test func analysisIsFastEnough() {
        let samples = Signals.noise(count: Int(60 * Signals.sampleRate), amplitude: 0.3)
        let engine = BeatEngine(sampleRate: Signals.sampleRate)
        let start = ContinuousClock.now
        run(engine, samples, chunk: 4800)
        let elapsed = ContinuousClock.now - start
        // Budget is 300 ms for 60 s of audio in release builds; debug builds get 10x headroom.
        #expect(elapsed < .seconds(3), "60 s of audio took \(elapsed)")
    }
}
