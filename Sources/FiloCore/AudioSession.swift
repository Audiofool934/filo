import Foundation
import CoreAudio
import FiloPCM

public struct TransportMetrics: Codable {
    public let callbacks: UInt64
    public let frames: UInt64
    public let nonzeroSamples: UInt64
    public let invalidBuffers: UInt64
    public let capturedFrames: UInt64
    public let inputBuffers: UInt32
    public let inputFirstChannels: UInt32
    public let inputLastChannels: UInt32
    public let inputLastBytes: UInt32
    init(_ m: FiloMetrics) {
        callbacks = m.callbacks; frames = m.frames; nonzeroSamples = m.nonzeroSamples
        invalidBuffers = m.invalidBuffers; capturedFrames = m.capturedFrames
        inputBuffers = m.inputBuffers; inputFirstChannels = m.inputFirstChannels
        inputLastChannels = m.inputLastChannels; inputLastBytes = m.inputLastBytes
    }
}

/// All lifecycle operations belong to one control queue. The C callback owns its sample storage.
public final class AudioSession {
    private var tap: AudioObjectID = 0
    private var aggregate: AudioObjectID = 0
    private var device: AudioObjectID = 0
    private var hogDevice: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var transport: OpaquePointer?
    private var inputSkip: UInt32 = 0
    private var inputCount: UInt32 = 1
    private var inputStreamCount: UInt32 = 0
    public private(set) var inputFormat: PCMFormat?
    public private(set) var outputFormat: PCMFormat?
    public private(set) var running = false
    public init() {}
    deinit { stop() }

    public var metrics: TransportMetrics { TransportMetrics(filo_transport_metrics(transport)) }

    public func startEmitter(device output: OutputDevice, bits: UInt32) throws {
        stop()
        device = output.id
        do {
            let format = PCMFormat(try HAL.streamFormat(device, scope: kAudioObjectPropertyScopeOutput))
            guard format.isFloatStereo else { throw AudioFailure("The test output requires stereo Float32.") }
            outputFormat = format
            try startIO(emit: true, relay: false, bits: bits, captureFrames: 0)
        } catch { stop(); throw error }
    }

    /// Laboratory-only digital loopback input. Normal app playback never calls this.
    public func startLoopback(device input: OutputDevice, captureFrames: UInt64) throws {
        stop(); device = input.id
        do {
            inputFormat = PCMFormat(try HAL.streamFormat(device, scope: kAudioObjectPropertyScopeInput))
            outputFormat = PCMFormat(try HAL.streamFormat(device, scope: kAudioObjectPropertyScopeOutput))
            let channels = try HAL.bufferChannels(device, scope: kAudioObjectPropertyScopeInput)
            guard inputFormat?.isFloatStereo == true, channels == [2] else { throw AudioFailure("Loopback requires one interleaved stereo Float32 input.") }
            inputSkip = 0; inputCount = 1; inputStreamCount = 1
            try startIO(emit: false, relay: false, bits: 24, captureFrames: captureFrames)
        } catch { stop(); throw error }
    }

    public func startCapture(processIDs: [AudioObjectID], output: OutputDevice,
                             relay: Bool, exclusive: Bool = false, captureFrames: UInt64 = 0) throws {
        stop()
        guard !processIDs.isEmpty else { throw AudioFailure("The source has no audio process. Start playback first.") }
        do {
            // Pin to the same output stream as the aggregate clock. No global mix or sample-rate converter.
            let description = CATapDescription(processes: processIDs, deviceUID: output.uid, stream: 0)
            description.name = "filo source"
            description.isPrivate = true
            description.muteBehavior = relay ? .mutedWhenTapped : .unmuted
            try HAL.check(AudioHardwareCreateProcessTap(description, &tap), "Create source tap")
            let tapUID = try HAL.string(tap, kAudioTapPropertyUID)
            let tapFormat = try HAL.value(tap, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
            guard PCMFormat(tapFormat).isFloatStereo, tapFormat.mSampleRate == output.rate else { throw AudioFailure("The source tap requires matching-rate stereo Float32 PCM.") }

            if exclusive {
                let owner = try HAL.value(output.id, kAudioDevicePropertyHogMode, default: Int32(-1))
                guard owner == -1 else { throw AudioFailure("Another process owns exclusive access to this output.") }
                try HAL.set(output.id, kAudioDevicePropertyHogMode, getpid())
                hogDevice = output.id
                guard try HAL.value(output.id, kAudioDevicePropertyHogMode, default: Int32(-1)) == getpid() else {
                    throw AudioFailure("The output did not grant exclusive access.")
                }
            }
            let config: [String: Any] = [
                kAudioAggregateDeviceNameKey: "filo connection",
                kAudioAggregateDeviceUIDKey: "filo.session.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceMainSubDeviceKey: output.uid,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output.uid, kAudioSubDeviceInputChannelsKey: 0, kAudioSubDeviceDriftCompensationKey: false]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: false]],
                kAudioAggregateDeviceTapAutoStartKey: true
            ]
            try HAL.check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate), "Create connection")
            device = aggregate
            let inputStreams = try HAL.array(device, kAudioDevicePropertyStreams, seed: AudioObjectID(0), scope: kAudioObjectPropertyScopeInput)
            inputStreamCount = UInt32(inputStreams.count)
            guard let tapStream = inputStreams.last else { throw AudioFailure("The aggregate has no tap input stream.") }
            inputFormat = PCMFormat(try HAL.value(tapStream, kAudioStreamPropertyVirtualFormat, default: AudioStreamBasicDescription()))
            outputFormat = PCMFormat(try HAL.streamFormat(device, scope: kAudioObjectPropertyScopeOutput))
            guard let inputFormat, let outputFormat, inputFormat.isFloatStereo, outputFormat.isFloatStereo,
                  inputFormat.rate == outputFormat.rate, inputFormat.rate == output.rate else {
                throw AudioFailure("Capture and output formats differ. The connection was stopped without resampling.")
            }
            let channels = try HAL.bufferChannels(device, scope: kAudioObjectPropertyScopeInput)
            inputCount = inputFormat.flags & kAudioFormatFlagIsNonInterleaved == 0 ? 1 : 2
            let expected: [UInt32] = inputCount == 1 ? [2] : [1, 1]
            guard channels.count >= inputCount, Array(channels.suffix(Int(inputCount))) == expected else {
                throw AudioFailure("The tap input buffer layout is unsupported.")
            }
            inputSkip = UInt32(channels.count) - inputCount
            try startIO(emit: false, relay: relay, bits: 24, captureFrames: captureFrames)
            guard try HAL.string(aggregate, kAudioAggregateDevicePropertyMainSubDevice) == output.uid else {
                throw AudioFailure("CoreAudio did not confirm the selected output clock.")
            }
        } catch { stop(); throw error }
    }

    private func startIO(emit: Bool, relay: Bool, bits: UInt32, captureFrames: UInt64) throws {
        guard let state = filo_transport_create(emit, relay, bits, captureFrames) else { throw AudioFailure("Could not allocate audio buffers.") }
        transport = state
        filo_transport_set_input_offset(state, inputSkip, inputCount)
        try HAL.check(AudioDeviceCreateIOProcID(device, filo_io, UnsafeMutableRawPointer(state), &ioProc), "Create audio callback")
        guard let ioProc else { throw AudioFailure("CoreAudio returned no audio callback.") }
        if !emit { try HAL.check(filo_select_tap_input(device, ioProc, inputStreamCount), "Select source tap input") }
        try HAL.check(AudioDeviceStart(device, ioProc), "Start audio (check System Audio Recording permission)")
        running = true
    }

    /// Stops IO before reading preallocated test storage. Never use to record subscription music.
    public func finishCapture() -> [Float] {
        stopIO()
        guard let ptr = filo_transport_capture(transport) else { return [] }
        let count = Int(metrics.capturedFrames) * 2
        return Array(UnsafeBufferPointer(start: ptr, count: count))
    }

    private func stopIO() {
        if let ioProc {
            AudioDeviceStop(device, ioProc)
            AudioDeviceDestroyIOProcID(device, ioProc)
            self.ioProc = nil
        }
        running = false
    }
    public func stop() {
        stopIO()
        if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
        if hogDevice != 0 {
            if (try? HAL.value(hogDevice, kAudioDevicePropertyHogMode, default: Int32(-1))) == getpid() {
                try? HAL.set(hogDevice, kAudioDevicePropertyHogMode, Int32(-1))
            }
            hogDevice = 0
        }
        filo_transport_destroy(transport); transport = nil; device = 0
    }
}
