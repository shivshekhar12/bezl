import Foundation

/// What the renderer needs from the audio, updated once per analysis hop (~94 Hz at 48 kHz).
public struct LightState: Sendable, Equatable {
    /// Loudness envelope normalized by a slow automatic gain control, 0...1.
    public var level: Double = 0
    /// Spikes to the onset strength on each detected beat, then decays (τ ≈ 180 ms), 0...1.
    public var pulse: Double = 0
    /// True on the hop where an onset was detected.
    public var onset: Bool = false
    /// True after 5 s below the silence gate.
    public var isSilent: Bool = true
    /// Raw RMS in dBFS (for the debug readout).
    public var rmsDB: Double = -120
    /// Total onsets so far. Lets a renderer running at a different rate notice every beat,
    /// even ones that fell between its frames.
    public var beatCount: Int = 0

    public init() {}
}

/// Streaming beat/onset detector: low-band spectral flux with an adaptive median threshold,
/// plus an RMS envelope with automatic gain. Feed it mono samples in any chunk size.
/// Not thread-safe; owned by a single analysis queue.
public final class BeatEngine {
    public struct Tuning: Sendable {
        public var frameSize = 1024
        public var hopSize = 512
        public var kickBand: (Double, Double) = (30, 150)
        public var broadBand: (Double, Double) = (150, 8000)
        public var broadWeight: Double = 0.3
        /// Seconds of flux history for the adaptive threshold.
        public var historySeconds = 1.0
        public var thresholdMultiplier = 3.5
        /// Fraction of the recent flux peak added to the threshold.
        public var thresholdPeakFraction = 0.4
        /// Absolute flux floor: anything quieter is never an onset.
        public var minimumFlux = 0.05
        /// Frames on each side an onset must dominate (adds this many hops of latency).
        public var peakHalfWidth = 3
        public var minimumOnsetInterval = 0.2
        public var silenceGateDB = -60.0
        public var silenceHoldSeconds = 5.0
        public var levelAttack = 0.010
        public var levelRelease = 0.300
        public var pulseDecay = 0.180
        /// Time for the AGC peak to fall by ~63%.
        public var agcDecaySeconds = 10.0
        public init() {}
    }

    public let sampleRate: Double
    public let tuning: Tuning
    public private(set) var state = LightState()
    /// Count of onsets since creation (handy for tests and the debug readout).
    public private(set) var onsetCount = 0
    /// Time in seconds (stream time) of every onset; capped to the last 4096.
    public private(set) var onsetTimes: [Double] = []

    private let fft: FFTAnalyzer
    private let kickBins: ClosedRange<Int>
    private let broadBins: ClosedRange<Int>
    private var frame: [Float]
    private var pending: [Float] = []
    private var prevMags: [Float]
    private var hasPrev = false

    private var fluxHistory: [Double]
    private var fluxIndex = 0
    private var fluxFilled = 0
    private var sortScratch: [Double]

    private var hopsProcessed = 0
    private var lastOnsetTime = -Double.infinity
    private var envelope = 0.0
    private var agcPeak = 0.0
    private var silentFor = 0.0
    private var recentFluxPeak = 0.0

    private var hopSeconds: Double { Double(tuning.hopSize) / sampleRate }

    public init(sampleRate: Double, tuning: Tuning = Tuning()) {
        self.sampleRate = sampleRate
        self.tuning = tuning
        fft = FFTAnalyzer(frameSize: tuning.frameSize, sampleRate: sampleRate)
        kickBins = fft.bins(from: tuning.kickBand.0, to: tuning.kickBand.1)
        broadBins = fft.bins(from: tuning.broadBand.0, to: min(tuning.broadBand.1, sampleRate / 2 - 1))
        frame = [Float](repeating: 0, count: tuning.frameSize)
        prevMags = [Float](repeating: 0, count: tuning.frameSize / 2)
        let historyLength = max(8, Int(tuning.historySeconds * sampleRate / Double(tuning.hopSize)))
        fluxHistory = [Double](repeating: 0, count: historyLength)
        sortScratch = [Double](repeating: 0, count: historyLength)
        pending.reserveCapacity(tuning.hopSize * 4)
    }

    /// Feeds samples; returns the state after the last complete hop (or the current state).
    @discardableResult
    public func process(_ samples: UnsafeBufferPointer<Float>) -> LightState {
        pending.append(contentsOf: samples)
        var start = 0
        while pending.count - start >= tuning.hopSize {
            pending.withUnsafeBufferPointer { buf in
                processHop(UnsafeBufferPointer(rebasing: buf[start..<(start + tuning.hopSize)]))
            }
            start += tuning.hopSize
        }
        if start > 0 { pending.removeFirst(start) }
        return state
    }

    @discardableResult
    public func process(_ samples: [Float]) -> LightState {
        samples.withUnsafeBufferPointer { process($0) }
    }

    public func reset() {
        state = LightState()
        pending.removeAll(keepingCapacity: true)
        frame = [Float](repeating: 0, count: tuning.frameSize)
        hasPrev = false
        fluxIndex = 0
        fluxFilled = 0
        envelope = 0
        agcPeak = 0
        silentFor = 0
        recentFluxPeak = 0
        lastOnsetTime = -.infinity
    }

    // MARK: - Per-hop analysis

    private func processHop(_ hop: UnsafeBufferPointer<Float>) {
        let dt = hopSeconds
        hopsProcessed += 1
        let now = Double(hopsProcessed) * dt

        // Slide the analysis frame.
        let keep = tuning.frameSize - tuning.hopSize
        frame.withUnsafeMutableBufferPointer { f in
            if keep > 0 {
                f.baseAddress!.update(from: f.baseAddress! + tuning.hopSize, count: keep)
            }
            (f.baseAddress! + keep).update(from: hop.baseAddress!, count: tuning.hopSize)
        }

        // Loudness.
        var sumSquares = 0.0
        for s in hop { sumSquares += Double(s) * Double(s) }
        let rms = (sumSquares / Double(hop.count)).squareRoot()
        let rmsDB = rms > 0 ? 20 * log10(rms) : -120
        let gated = rmsDB < tuning.silenceGateDB
        silentFor = gated ? silentFor + dt : 0

        let target = gated ? 0 : rms
        let coeff = target > envelope ? tuning.levelAttack : tuning.levelRelease
        envelope += (target - envelope) * (1 - exp(-dt / coeff))
        agcPeak = max(envelope, agcPeak * exp(-dt / tuning.agcDecaySeconds))
        let level = agcPeak > 1e-6 ? min(1, envelope / agcPeak) : 0

        // Spectral flux.
        frame.withUnsafeBufferPointer { fft.analyze($0) }
        let mags = fft.magnitudes
        var flux = 0.0
        if hasPrev && !gated {
            var kick = 0.0
            for k in kickBins { kick += Double(max(0, mags[k] - prevMags[k])) }
            kick /= Double(kickBins.count)
            var broad = 0.0
            for k in broadBins { broad += Double(max(0, mags[k] - prevMags[k])) }
            broad /= Double(broadBins.count)
            flux = kick + tuning.broadWeight * broad
        }
        prevMags = mags
        hasPrev = true

        fluxHistory[fluxIndex] = flux
        fluxIndex = (fluxIndex + 1) % fluxHistory.count
        fluxFilled = min(fluxFilled + 1, fluxHistory.count)
        recentFluxPeak = max(flux, recentFluxPeak * exp(-dt / 2.0))

        // Peak picking: the candidate is `peakHalfWidth` hops in the past so we can see both sides.
        var onset = false
        var strength = 0.0
        let w = tuning.peakHalfWidth
        if fluxFilled > 2 * w + 1 {
            let candidate = fluxAt(hopsAgo: w)
            var isPeak = candidate > 0
            if isPeak {
                for ago in 0...(2 * w) where ago != w {
                    if fluxAt(hopsAgo: ago) > candidate { isPeak = false; break }
                }
            }
            if isPeak {
                let threshold = medianFlux() * tuning.thresholdMultiplier
                    + tuning.thresholdPeakFraction * recentFluxPeak
                let candidateTime = now - Double(w) * dt
                if candidate > max(threshold, tuning.minimumFlux),
                   candidateTime - lastOnsetTime >= tuning.minimumOnsetInterval {
                    onset = true
                    lastOnsetTime = candidateTime
                    strength = min(1, max(0.35, candidate / max(recentFluxPeak, 1e-6)))
                    onsetCount += 1
                    if onsetTimes.count >= 4096 { onsetTimes.removeFirst(1024) }
                    onsetTimes.append(candidateTime)
                }
            }
        }

        var pulse = state.pulse * exp(-dt / tuning.pulseDecay)
        if onset { pulse = max(pulse, strength) }

        state.level = level
        state.pulse = pulse
        state.onset = onset
        state.isSilent = silentFor >= tuning.silenceHoldSeconds
        state.rmsDB = rmsDB
        state.beatCount = onsetCount
    }

    private func fluxAt(hopsAgo: Int) -> Double {
        let n = fluxHistory.count
        return fluxHistory[(fluxIndex - 1 - hopsAgo + 2 * n) % n]
    }

    private func medianFlux() -> Double {
        let n = fluxFilled
        guard n > 0 else { return 0 }
        for i in 0..<n { sortScratch[i] = fluxHistory[i] }
        sortScratch[0..<n].sort()
        return sortScratch[n / 2]
    }
}
