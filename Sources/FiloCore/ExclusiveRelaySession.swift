import CoreAudio
import Foundation
import FiloPCM

public struct ExclusiveRelayMetrics: Codable {
    public let inputCallbacks: UInt64, outputCallbacks: UInt64
    public let capturedFrames: UInt64, deliveredFrames: UInt64, queuedFrames: UInt64
    public let startupSilenceFrames: UInt64, initialQueuedFrames: UInt64, underflows: UInt64, overflows: UInt64
    public let invalidBuffers: UInt64, representationFailures: UInt64, renderedCaptureFrames: UInt64
    public let inputTimestampMissing: UInt64, outputTimestampMissing: UInt64
    public let inputTimestampDiscontinuities: UInt64, outputTimestampDiscontinuities: UInt64
    public let fault: UInt32
    public let started: Bool
    init(_ v: FiloBridgeMetrics) {
        inputCallbacks = v.inputCallbacks; outputCallbacks = v.outputCallbacks
        capturedFrames = v.capturedFrames; deliveredFrames = v.deliveredFrames; queuedFrames = v.queuedFrames
        startupSilenceFrames = v.startupSilenceFrames; initialQueuedFrames = v.initialQueuedFrames
        underflows = v.underflows; overflows = v.overflows
        invalidBuffers = v.invalidBuffers; representationFailures = v.representationFailures
        renderedCaptureFrames = v.renderedCaptureFrames; fault = v.fault; started = v.started
        inputTimestampMissing = v.inputTimestampMissing; outputTimestampMissing = v.outputTimestampMissing
        inputTimestampDiscontinuities = v.inputTimestampDiscontinuities; outputTimestampDiscontinuities = v.outputTimestampDiscontinuities
    }
}

/// Two independent IOProcs: virtual capture and direct, exclusively owned integer DAC output.
/// Lifecycle and clock updates are called only on one non-realtime control queue.
public final class ExclusiveRelaySession {
    private let outputLease = ExclusiveDevice()
    private var clock: VirtualClock?
    private var bridge: OpaquePointer?
    private var tap: AudioObjectID = 0
    private var aggregate: AudioObjectID = 0
    private var inputProc: AudioDeviceIOProcID?
    private var outputProc: AudioDeviceIOProcID?
    private var source: OutputDevice?
    private var follower: ClockFollower?
        private var lastTick: TimeInterval = 0
    private var lastInputCount: UInt64 = 0, lastOutputCount: UInt64 = 0
    private var inputProgress: TimeInterval = 0, outputProgress: TimeInterval = 0
    public private(set) var inputFormat: PCMFormat?
    public private(set) var outputFormat: PCMFormat?
    public private(set) var physicalFormat: PCMFormat?
    public private(set) var running = false
    public private(set) var clockPitch: Float = 0.5
    public private(set) var clockTargetFrames: UInt64 = 0
    public var outputASBD: AudioStreamBasicDescription { outputLease.virtualFormat }
    public private(set) var cleanupErrors: [String] = []
    public var metrics: ExclusiveRelayMetrics { ExclusiveRelayMetrics(filo_bridge_metrics(bridge)) }
    public init() {}
    deinit { stop() }

    public func start(processIDs: [AudioObjectID], source: OutputDevice, output: OutputDevice,
                      sourceBits: UInt32 = 0, captureFrames: UInt64 = 0, followClock: Bool = true,
                      rejectionCaptureFrames: UInt32 = 0) throws {
        stop()
        guard bridge == nil else { throw AudioFailure("A previous audio callback could not be released. Quit filo before retrying.") }
        cleanupErrors = []; clockTargetFrames = 0; clockPitch = 0.5
        guard rejectionCaptureFrames <= FILO_BRIDGE_MAX_REJECTION_CAPTURE_FRAMES else {
            throw AudioFailure("Rejected-input inspection is limited to 8192 stereo frames.")
        }
        guard source.uid != output.uid, !processIDs.isEmpty else { throw AudioFailure("Exclusive relay needs a separate virtual source and an active source process.") }
        self.source = source
        do {
            if followClock {
                let clock = try VirtualClock(device: source)
                self.clock = clock; try clock.acquire()
            }
            try outputLease.acquire(output: output, rate: source.rate, minimumBits: sourceBits == 16 ? 16 : 24)
            let description = CATapDescription(processes: processIDs, deviceUID: source.uid, stream: 0)
            description.name = "filo isolated source"; description.isPrivate = true; description.muteBehavior = .mutedWhenTapped
            try HAL.check(AudioHardwareCreateProcessTap(description, &tap), "Create isolated source tap")
            let tapUID = try HAL.string(tap, kAudioTapPropertyUID)
            let tapFormat = try HAL.value(tap, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
            guard PCMFormat(tapFormat).isFloatStereo, tapFormat.mSampleRate == source.rate else {
                throw AudioFailure("The virtual source tap is not matching-rate stereo Float32.")
            }
            let config: [String: Any] = [
                kAudioAggregateDeviceNameKey: "filo isolated capture",
                kAudioAggregateDeviceUIDKey: "filo.capture.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceMainSubDeviceKey: source.uid,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: source.uid, kAudioSubDeviceInputChannelsKey: 0, kAudioSubDeviceDriftCompensationKey: false]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: false]],
                kAudioAggregateDeviceTapAutoStartKey: true
            ]
            try HAL.check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate), "Create isolated capture device")
            let streams = try HAL.array(aggregate, kAudioDevicePropertyStreams, seed: AudioObjectID(0), scope: kAudioObjectPropertyScopeInput)
            guard let tapStream = streams.last,
                  try HAL.string(aggregate, kAudioAggregateDevicePropertyMainSubDevice) == source.uid else { throw AudioFailure("The source clock was not confirmed.") }
            let inputASBD = try HAL.value(tapStream, kAudioStreamPropertyVirtualFormat, default: AudioStreamBasicDescription())
            guard PCMFormat(inputASBD).isFloatStereo, inputASBD.mSampleRate == source.rate else { throw AudioFailure("The source stream changed format.") }
            let channels = try HAL.bufferChannels(aggregate, scope: kAudioObjectPropertyScopeInput)
            let inputCount = inputASBD.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0 ? 1 : 2
            let expected: [UInt32] = inputCount == 1 ? [2] : [1, 1]
            guard channels.count >= inputCount, Array(channels.suffix(inputCount)) == expected else { throw AudioFailure("The capture layout is unsupported.") }
            var capacity: UInt64 = 1
            while capacity < UInt64(source.rate * 2) { capacity <<= 1 }
            let prime = max(UInt64(2048), UInt64(source.rate * 0.15))
            var bridgeConfig = FiloBridgeConfig(capacityFrames: capacity, primeFrames: prime, renderCaptureFrames: captureFrames,
                inputFormat: inputASBD, outputFormat: outputLease.virtualFormat,
                inputBufferOffset: UInt32(channels.count - inputCount), inputBufferCount: UInt32(inputCount),
                sourceBits: sourceBits, rejectionCaptureFrames: rejectionCaptureFrames)
            guard let bridge = filo_bridge_create(&bridgeConfig) else { throw AudioFailure("Unsupported integer bridge format or buffer allocation failure.") }
            self.bridge = bridge
            inputFormat = PCMFormat(inputASBD); outputFormat = PCMFormat(outputLease.virtualFormat); physicalFormat = PCMFormat(outputLease.physicalFormat)
            try HAL.check(AudioDeviceCreateIOProcID(aggregate, filo_bridge_capture_io, UnsafeMutableRawPointer(bridge), &inputProc), "Create source callback")
            guard let inputProc else { throw AudioFailure("No source callback was created.") }
            try HAL.check(filo_select_tap_input(aggregate, inputProc, UInt32(streams.count)), "Select only the source tap")
            try HAL.check(AudioDeviceCreateIOProcID(output.id, filo_bridge_output_io, UnsafeMutableRawPointer(bridge), &outputProc), "Create exclusive output callback")
            guard let outputProc else { throw AudioFailure("No output callback was created.") }
            try HAL.check(AudioDeviceStart(aggregate, inputProc), "Start isolated source")
            try HAL.check(AudioDeviceStart(output.id, outputProc), "Start exclusive output")
            lastTick = ProcessInfo.processInfo.systemUptime
            inputProgress = lastTick; outputProgress = lastTick; lastInputCount = 0; lastOutputCount = 0
            running = true
            try outputLease.validate()
        } catch { stop(); throw error }
    }

    public func tick() throws {
        guard running, let source else { return }
        try outputLease.validate()
        guard try HAL.string(source.id, kAudioDevicePropertyDeviceUID) == source.uid, try HAL.rate(source.id) == source.rate else {
            throw AudioFailure("The virtual source device or sample rate changed.")
        }
        let m = metrics, now = ProcessInfo.processInfo.systemUptime
        guard m.fault == 0 else { throw AudioFailure(Self.failureDescription(m.fault)) }
        if m.inputCallbacks != lastInputCount { inputProgress = now; lastInputCount = m.inputCallbacks }
        if m.outputCallbacks != lastOutputCount { outputProgress = now; lastOutputCount = m.outputCallbacks }
        guard (m.inputCallbacks == 0 || now - inputProgress < 3), now - outputProgress < 3 else { throw AudioFailure("An exclusive relay callback stalled.") }
        if let clock {
            try clock.validate()
            if m.started {
                if follower == nil {
                    // Starting a USB device can block while capture continues.
                    // Preserve that reserve; do not drain it by changing musical samples.
                    clockTargetFrames = m.initialQueuedFrames
                    guard clockTargetFrames > 0, clockTargetFrames < UInt64(source.rate) else {
                        throw AudioFailure("The initial clock reserve is outside the supported range.")
                    }
                    follower = ClockFollower(sampleRate: source.rate, targetFrames: clockTargetFrames)
                }
                clockPitch = try follower!.update(queuedFrames: m.queuedFrames, elapsed: now - lastTick)
                clockPitch = try clock.setPitch(clockPitch)
            }
        }
        lastTick = now
    }

    static func failureDescription(_ fault: UInt32) -> String {
        switch fault {
        case 1, 2: return "The audio buffer layout changed or is unsupported. Exclusive preview stopped."
        case 3: return "The source filled the audio buffer faster than the DAC could consume it. Exclusive preview stopped."
        case 4: return "The DAC ran out of queued audio samples. Exclusive preview stopped."
        case 5: return "The captured samples cannot be represented exactly in the selected integer format. Exclusive preview stopped."
        case 6: return "The audio callback timeline changed unexpectedly. Exclusive preview stopped."
        default: return "The relay could not preserve the sample sequence (fault \(fault)). Exclusive preview stopped."
        }
    }

    /// Stop callbacks before taking the final segment evidence; do not free the bridge yet.
    public func finishMetrics() -> ExclusiveRelayMetrics {
        stopIO()
        return metrics
    }
    public func finishCapture() -> [Float] {
        stopIO()
        guard inputProc == nil, outputProc == nil else { return [] }
        guard let pointer = filo_bridge_render_capture(bridge) else { return [] }
        return Array(UnsafeBufferPointer(start: pointer, count: Int(metrics.renderedCaptureFrames) * 2))
    }
    public func finishRawCapture() -> Data {
        stopIO()
        guard inputProc == nil, outputProc == nil,
              let pointer = filo_bridge_render_bytes(bridge) else { return Data() }
        return Data(bytes: pointer, count: Int(filo_bridge_render_byte_count(bridge)))
    }
    /// Returns no sample storage unless explicitly enabled and both callbacks are released.
    public func finishInputRejection() -> InputRejectionSnapshot? {
        stopIO()
        guard inputProc == nil, outputProc == nil else { return nil }
        let value = filo_bridge_rejection(bridge)
        guard value.available, let pointer = filo_bridge_rejection_samples(bridge) else { return nil }
        return InputRejectionSnapshot(value, sampleBits: Array(UnsafeBufferPointer(
            start: pointer, count: Int(value.capturedFrames) * 2)))
    }
    private func stopIO() {
        if let outputProc, let output = outputLease.device {
            AudioDeviceStop(output.id, outputProc)
            let result = AudioDeviceDestroyIOProcID(output.id, outputProc)
            if result == noErr { self.outputProc = nil }
            else { cleanupErrors.append("Could not release the output callback (\(result)). Its memory is retained until process exit.") }
        }
        if let inputProc {
            AudioDeviceStop(aggregate, inputProc)
            let result = AudioDeviceDestroyIOProcID(aggregate, inputProc)
            if result == noErr { self.inputProc = nil }
            else { cleanupErrors.append("Could not release the capture callback (\(result)). Its memory is retained until process exit.") }
        }
        running = false
    }
    public func stop() {
        stopIO()
        // Never free a context that an unconfirmed IOProc could still reference.
        guard inputProc == nil, outputProc == nil else { return }
        if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
        filo_bridge_destroy(bridge); bridge = nil
        cleanupErrors += outputLease.restore()
        if let clock { cleanupErrors += clock.restore() }
        clock = nil; source = nil; follower = nil
    }
}
