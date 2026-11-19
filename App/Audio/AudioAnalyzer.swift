import BezlCore
import BezlRing
import Foundation
import os

/// Drains the ring buffer on a background queue (~every 10 ms), runs the beat engine and
/// publishes the latest `LightState` through a lock the renderer can read each frame.
final class AudioAnalyzer: @unchecked Sendable {
    let ring: OpaquePointer
    private let queue = DispatchQueue(label: "bezl.audio.analysis", qos: .userInitiated)
    private let latest = OSAllocatedUnfairLock(initialState: LightState())
    private let stats = OSAllocatedUnfairLock(initialState: Stats())

    // Confined to `queue`.
    private var timer: DispatchSourceTimer?
    private var engine: BeatEngine?
    private var readBuffer = [Float](repeating: 0, count: 8192)
    private var wasSilent = true

    /// Called on the main actor when audio goes silent or comes back.
    private let onSilenceChange: @Sendable @MainActor (Bool) -> Void

    struct Stats: Sendable {
        var sampleRate: Double = 0
        var onsetCount = 0
        var samplesReceived = 0
        /// Seconds of consecutive exact-zero input (a denied permission delivers pure zeros).
        var zeroSeconds = 0.0
    }

    init(onSilenceChange: @escaping @Sendable @MainActor (Bool) -> Void) {
        guard let ring = bezl_ring_create(1 << 16) else { fatalError("Could not allocate the audio ring buffer") }
        self.ring = ring
        self.onSilenceChange = onSilenceChange
    }

    deinit {
        timer?.cancel()
        bezl_ring_destroy(ring)
    }

    var current: LightState { latest.withLock { $0 } }
    var currentStats: Stats { stats.withLock { $0 } }

    func start(sampleRate: Double) {
        queue.async { [self] in
            timer?.cancel()
            bezl_ring_clear(ring)
            engine = BeatEngine(sampleRate: sampleRate)
            wasSilent = true
            latest.withLock { $0 = LightState() }
            stats.withLock { $0 = Stats(sampleRate: sampleRate) }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
            t.setEventHandler { [weak self] in self?.drain() }
            t.resume()
            timer = t
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            engine = nil
            latest.withLock { $0 = LightState() }
            bezl_ring_clear(ring)
        }
    }

    private func drain() {
        guard let engine else { return }
        var total = 0
        var allZero = true
        while true {
            let n = readBuffer.withUnsafeMutableBufferPointer { buf in
                bezl_ring_read(ring, buf.baseAddress!, buf.count)
            }
            if n == 0 { break }
            total += n
            readBuffer.withUnsafeBufferPointer { buf in
                let slice = UnsafeBufferPointer(rebasing: buf[0..<n])
                if allZero { allZero = !slice.contains { $0 != 0 } }
                engine.process(slice)
            }
        }
        guard total > 0 else { return }
        let state = engine.state
        latest.withLock { $0 = state }
        let received = total
        let zero = allZero
        let seconds = Double(received) / engine.sampleRate
        let onsets = engine.onsetCount
        stats.withLock {
            $0.samplesReceived += received
            $0.onsetCount = onsets
            $0.zeroSeconds = zero ? $0.zeroSeconds + seconds : 0
        }
        if state.isSilent != wasSilent {
            wasSilent = state.isSilent
            let silent = state.isSilent
            let callback = onSilenceChange
            Task { @MainActor in callback(silent) }
        }
    }
}
