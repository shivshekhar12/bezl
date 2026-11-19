import AudioToolbox
import BezlRing
import CoreAudio
import Foundation
import os

private let log = Logger(subsystem: "io.github.shivshekhar12.bezl", category: "audio")

enum AudioTapError: LocalizedError {
    case os(String, OSStatus)
    case noOutputDevice

    var errorDescription: String? {
        switch self {
        case let .os(what, status): "\(what) failed (OSStatus \(status))"
        case .noOutputDevice: "No audio output device"
        }
    }
}

/// Receives audio on Core Audio's real-time IO thread, mixes it to mono and pushes it into
/// the lock-free ring. Nothing here allocates, locks, logs or touches Swift concurrency.
final class TapSink: @unchecked Sendable {
    let ring: OpaquePointer
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchCapacity: Int

    init(ring: OpaquePointer, scratchCapacity: Int = 16_384) {
        self.ring = ring
        self.scratchCapacity = scratchCapacity
        scratch = .allocate(capacity: scratchCapacity)
        scratch.initialize(repeating: 0, count: scratchCapacity)
    }

    deinit { scratch.deallocate() }

    /// Called on the IO thread. Assumes 32-bit float samples (process taps deliver Float32).
    func consume(_ list: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard buffers.count > 0, let first = buffers[0].mData else { return }

        if buffers.count == 1 {
            // Interleaved: one buffer, N channels.
            let channels = Int(max(buffers[0].mNumberChannels, 1))
            let frames = min(Int(buffers[0].mDataByteSize) / (4 * channels), scratchCapacity)
            let samples = first.assumingMemoryBound(to: Float.self)
            let scale = 1 / Float(channels)
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += samples[i * channels + c] }
                scratch[i] = sum * scale
            }
            _ = bezl_ring_write(ring, scratch, frames)
        } else {
            // Non-interleaved: one buffer per channel.
            let frames = min(Int(buffers[0].mDataByteSize) / 4, scratchCapacity)
            let scale = 1 / Float(buffers.count)
            for i in 0..<frames { scratch[i] = 0 }
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let samples = data.assumingMemoryBound(to: Float.self)
                let n = min(frames, Int(buffer.mDataByteSize) / 4)
                for i in 0..<n { scratch[i] += samples[i] * scale }
            }
            _ = bezl_ring_write(ring, scratch, frames)
        }
    }
}

/// Captures everything the Mac is playing (never the microphone) with a Core Audio process tap
/// wrapped in a private aggregate device. Requires macOS 14.2 and the "System Audio Recording"
/// permission, which macOS asks for on first start.
@MainActor
final class SystemAudioTap {
    private let sink: TapSink
    private let ioQueue = DispatchQueue(label: "bezl.audio.io", qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var outputListener: AudioObjectPropertyListenerBlock?

    private(set) var isRunning = false
    private(set) var sampleRate: Double = 48_000
    private(set) var lastError: String?

    /// Called after the default output device changes and the tap was rebuilt.
    var onRestart: ((Double) -> Void)?

    init(ring: OpaquePointer) {
        sink = TapSink(ring: ring)
    }

    func start() throws {
        guard !isRunning else { return }
        do {
            try build()
            isRunning = true
            lastError = nil
            installOutputListener()
            log.info("System audio tap started at \(self.sampleRate) Hz")
        } catch {
            teardown()
            lastError = error.localizedDescription
            log.error("System audio tap failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func stop() {
        removeOutputListener()
        teardown()
        isRunning = false
    }

    // MARK: - Build / teardown

    private func build() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Bezl"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw AudioTapError.os("Creating the process tap", status) }
        tapID = tap

        let outputUID = try Self.defaultOutputDeviceUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Bezl Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var aggregateDevice = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateDevice)
        guard status == noErr else { throw AudioTapError.os("Creating the aggregate device", status) }
        aggregateID = aggregateDevice

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard status == noErr else { throw AudioTapError.os("Reading the tap format", status) }
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32 else {
            throw AudioTapError.os("Unsupported tap format", -1)
        }
        sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 48_000

        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, ioQueue, Self.makeIOBlock(sink: sink))
        guard status == noErr, let proc else { throw AudioTapError.os("Creating the IO proc", status) }
        procID = proc

        status = AudioDeviceStart(aggregateID, proc)
        guard status == noErr else { throw AudioTapError.os("Starting the device", status) }
    }

    /// Builds the IO block OUTSIDE the main actor. A closure written inside a @MainActor method
    /// inherits main-actor isolation, and Swift 6 traps when Core Audio calls it on its
    /// real-time thread (`dispatch_assert_queue` failure).
    private nonisolated static func makeIOBlock(sink: TapSink) -> AudioDeviceIOBlock {
        { _, input, _, _, _ in sink.consume(input) }
    }

    /// Releases everything in reverse order. Safe to call repeatedly.
    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: - Default output changes (AirPods connect, etc.)

    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private func installOutputListener() {
        guard outputListener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.outputDeviceChanged() }
        }
        outputListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, .main, block)
    }

    private func removeOutputListener() {
        guard let block = outputListener else { return }
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, .main, block)
        outputListener = nil
    }

    private func outputDeviceChanged() {
        guard isRunning else { return }
        log.info("Default output changed; rebuilding tap")
        teardown()
        do {
            try build()
            onRestart?(sampleRate)
        } catch {
            isRunning = false
            lastError = error.localizedDescription
            removeOutputListener()
        }
    }

    // MARK: - Helpers

    static func defaultOutputDeviceUID() throws -> String {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultOutputAddress,
                                                0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else { throw AudioTapError.noOutputDevice }

        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        status = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let uid else { throw AudioTapError.os("Reading the output device UID", status) }
        return uid.takeRetainedValue() as String
    }
}
