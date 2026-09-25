import AudioToolbox
import CoreAudio
import CryptoKit
import Darwin
import Foundation

// Registration-only prerequisite. This source contains no start, prime, tap,
// aggregate, route, DAC ownership, or playback operations.
let help = """
Usage: audioqueue-registration --reference ORIGINAL.wav --mode default|explicit-unity --receipt NEW.json
       audioqueue-registration --offline-check --reference ORIGINAL.wav
       audioqueue-registration --signal-check
Only filo's exact original five-second 44100 Hz stereo 24-bit fixture is accepted.
Creates and binds one UNSTARTED AudioQueue to BlackHole 2ch, enqueues the unchanged
reference followed by ten seconds of zeros, and polls its own HAL registration for
at most five seconds. It never changes the default route, starts playback, primes
an AudioQueue, creates a tap, or acquires a DAC. Existing receipts are refused.
--help, --offline-check, and --signal-check do not access audio hardware or create a queue.
"""
struct Failure: LocalizedError {
    let text: String
    var errorDescription: String? { text }
    init(_ text: String) { self.text = text }
}
struct Options {
    let reference: URL, receipt: URL?
    let mode: String
    let offline: Bool
    init(_ arguments: [String]) throws {
        var values: [String: String] = [:], offline = false, index = 0
        while index < arguments.count {
            let key = arguments[index]
            if key == "--offline-check", !offline { offline = true; index += 1; continue }
            guard ["--reference", "--receipt", "--mode"].contains(key), values[key] == nil,
                  index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else { throw Failure(help) }
            values[key] = arguments[index + 1]; index += 2
        }
        guard let path = values["--reference"] else { throw Failure(help) }
        if offline { guard values["--receipt"] == nil, values["--mode"] == nil else { throw Failure(help) } }
        else { guard values["--receipt"] != nil, ["default", "explicit-unity"].contains(values["--mode"] ?? "") else { throw Failure(help) } }
        reference = URL(fileURLWithPath: path).standardizedFileURL
        receipt = values["--receipt"].map { URL(fileURLWithPath: $0).standardizedFileURL }
        mode = values["--mode"] ?? "offline"; self.offline = offline
    }
}
func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
let expectedHash = "43728e416e9d6c4b27f03a46aecc604e3353ee1d51dec8b0fcb2037a2f2cd58e"
func referenceSamples(_ url: URL) throws -> [Float] {
    let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard attributes.isRegularFile == true, attributes.fileSize == 1_323_044 else { throw Failure("Reference file type or length is not canonical.") }
    let data = try Data(contentsOf: url)
    guard digest(data) == expectedHash else { throw Failure("Canonical WAV SHA-256 mismatch.") }
    let bytes = [UInt8](data)
    func u16(_ offset: Int) -> UInt16 { UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8 }
    func u32(_ offset: Int) -> UInt32 { UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16 }
    guard String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF", u32(4) == 1_323_036,
          String(decoding: bytes[8..<16], as: UTF8.self) == "WAVEfmt ", u32(16) == 16,
          u16(20) == 1, u16(22) == 2, u32(24) == 44100, u32(28) == 264600,
          u16(32) == 6, u16(34) == 24, String(decoding: bytes[36..<40], as: UTF8.self) == "data",
          u32(40) == 1_323_000 else { throw Failure("Canonical RIFF format mismatch.") }
    var samples: [Float] = []; samples.reserveCapacity(441000)
    for frame in 0..<220500 {
        for channel in 0..<2 {
            let offset = 44 + (frame * 2 + channel) * 3
            let word = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16
            let integer = Int32(bitPattern: word << 8) >> 8
            var x = UInt32(frame) ^ (channel == 0 ? 0x27d4eb2f : 0xc2b2ae35)
            x ^= x >> 16; x = x &* 0x7feb352d; x ^= x >> 15; x = x &* 0x846ca68b; x ^= x >> 16
            guard integer == Int32(x & 16383) - 8192 else { throw Failure("Canonical integer payload mismatch at frame \(frame).") }
            samples.append(Float(integer) / 8388608)
        }
    }
    guard samples[0] != 0, samples[1] != 0 else { throw Failure("Canonical reference must begin with nonzero stereo samples.") }
    return samples
}
func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var result = initial, size = UInt32(MemoryLayout<T>.size)
    let status = withUnsafeMutablePointer(to: &result) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
    guard status == noErr, size == MemoryLayout<T>.size else { throw Failure("Read property \(selector) failed (\(status)).") }
    return result
}
func name(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
    let value: Unmanaged<CFString>? = try property(object, selector, initial: Optional<Unmanaged<CFString>>.none)
    guard let value else { throw Failure("Missing device string.") }
    return value.takeRetainedValue() as String
}
func blackHole() throws -> (AudioObjectID, String) {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    let sizeStatus = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
    guard sizeStatus == noErr, size > 0, size % 4 == 0 else { throw Failure("Cannot enumerate devices (\(sizeStatus)).") }
    var devices = [AudioObjectID](repeating: 0, count: Int(size) / 4)
    let status = devices.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!) }
    guard status == noErr else { throw Failure("Cannot read devices (\(status)).") }
    let matches = devices.filter { (try? name($0, kAudioObjectPropertyName)) == "BlackHole 2ch" }
    guard matches.count == 1, let device = matches.first else { throw Failure("Exactly one BlackHole 2ch is required.") }
    let rate = try property(device, kAudioDevicePropertyNominalSampleRate, initial: Double(0))
    let format = try property(device, kAudioDevicePropertyStreamFormat, initial: AudioStreamBasicDescription(), scope: kAudioObjectPropertyScopeOutput)
    guard rate == 44100, format.mSampleRate == 44100, format.mFormatID == kAudioFormatLinearPCM,
          format.mFormatFlags == kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
          format.mChannelsPerFrame == 2, format.mBitsPerChannel == 32, format.mBytesPerFrame == 8 else {
        throw Failure("BlackHole must already be interleaved stereo Float32 at 44100 Hz; this probe never changes its rate.")
    }
    return (device, try name(device, kAudioDevicePropertyDeviceUID))
}
struct Call: Codable {
    let operation: String, status: Int32, monotonicSeconds: Double
    var value: Float?
    var selectedDeviceMatches: Bool?
}
struct Discovery: Codable {
    let stage: String
    let elapsedSeconds: Double, translateStatus: Int32, nonzeroObject: Bool
    let pidReadStatus: Int32?, pidMatches: Bool?
    let runningOutputReadStatus: Int32?, runningOutput: Bool?
}
func observeProcess(stage: String, elapsed: Double) -> Discovery {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var pid = getpid(), object: AudioObjectID = kAudioObjectUnknown, size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
    var pidStatus: OSStatus?, matchesPID: Bool?, outputStatus: OSStatus?, outputRunning: Bool?
    if status == noErr, size == 4, object != kAudioObjectUnknown {
        var checkPID: pid_t = 0, pidSize = UInt32(MemoryLayout<pid_t>.size)
        address.mSelector = kAudioProcessPropertyPID
        let result = AudioObjectGetPropertyData(object, &address, 0, nil, &pidSize, &checkPID)
        pidStatus = result; matchesPID = result == noErr && pidSize == 4 && checkPID == pid
        address.mSelector = kAudioProcessPropertyIsRunningOutput
        var runningValue: UInt32 = 0, runningSize: UInt32 = 4
        let read = AudioObjectGetPropertyData(object, &address, 0, nil, &runningSize, &runningValue)
        outputStatus = read; outputRunning = read == noErr && runningSize == 4 ? runningValue != 0 : nil
    }
    return Discovery(stage: stage, elapsedSeconds: elapsed, translateStatus: status,
        nonzeroObject: status == noErr && size == 4 && object != kAudioObjectUnknown,
        pidReadStatus: pidStatus, pidMatches: matchesPID, runningOutputReadStatus: outputStatus, runningOutput: outputRunning)
}
final class Context {
    var returnedBuffers = 0, returnedFrames = 0
}
final class Signals {
    private let lock = NSLock()
    private var receivedValue: Int32?
    private let queue = DispatchQueue(label: "filo.audioqueue-registration.signals")
    var received: Int32? { lock.lock(); defer { lock.unlock() }; return receivedValue }
    private func record(_ number: Int32) { lock.lock(); receivedValue = number; lock.unlock() }
    let numbers = [SIGINT, SIGTERM, SIGHUP]
    // SIG_DFL is a null function pointer, which must survive storage and restoration.
    var prior: [sig_t?] = [], sources: [DispatchSourceSignal] = []
    init() {
        for number in numbers {
            let previous: sig_t? = signal(number, SIG_IGN)
            prior.append(previous)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [weak self] in self?.record(number) }; source.resume(); sources.append(source)
        }
    }
    deinit { sources.forEach { $0.cancel() }; for (number, old) in zip(numbers, prior) { signal(number, old) } }
}
func signalLifecycleCheck() throws {
    let numbers = [SIGINT, SIGTERM, SIGHUP]
    let originals: [sig_t?] = numbers.map { number in
        let previous: sig_t? = signal(number, SIG_DFL)
        return previous
    }
    defer { for (number, original) in zip(numbers, originals) { signal(number, original) } }
    var watch: Signals? = Signals()
    guard watch?.prior.count == 3, watch?.prior.allSatisfy({ $0 == nil }) == true else {
        throw Failure("Default signal handlers were not retained as null pointers.")
    }
    // Match an external process-directed termination request after source registration.
    Thread.sleep(forTimeInterval: 0.05)
    guard kill(getpid(), SIGTERM) == 0 else { throw Failure("Could not deliver the task-local signal control.") }
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while watch?.received == nil, ProcessInfo.processInfo.systemUptime < deadline {
        _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        Thread.sleep(forTimeInterval: 0.005)
    }
    guard watch?.received == SIGTERM else { throw Failure("Signal delivery did not reach the watcher within two seconds.") }
    watch = nil
    for number in numbers {
        let restored: sig_t? = signal(number, SIG_IGN)
        signal(number, SIG_DFL)
        guard restored == nil else { throw Failure("A default signal handler was not restored after watcher destruction.") }
    }
    print("SIGNAL_CHECK_OK: three null default handlers preserved/restored; SIGTERM delivered; no audio APIs used.")
}
struct Receipt: Encodable {
    let scope = "Unstarted AudioQueue preparation and HAL registration only; no playback or fidelity verdict"
    let mode: String, referenceSHA256: String, binarySHA256: String
    let referenceFrames = 220500, canonicalIntegerSamplesChecked = 441000
    let referencePrefixSilenceFrames = 0, intendedZeroPostrollFrames = 441000
    let explicitDevice = "BlackHole 2ch at existing 44100 Hz"
    let defaultRouteChanged = false, deviceRateChanged = false, tapCreated = false, dacAcquired = false
    let queueStartCalls = 0, queuePrimeCalls = 0, separateRendererCreated = false
    let independentlyRenderedSourceFrames: Int? = nil
    let enqueueIsNotRenderingEvidence = true, returnedBuffersAreNotPlaybackCompletion = true
    let registrationAttribution = "Observational readiness only; HAL inspection can itself establish a client connection. Reference parsing uses no AVAudioFile or audio APIs."
    let calls: [Call], discovery: [Discovery]
    let referenceFramesEnqueued: Int, zeroFramesEnqueued: Int
    let returnedBuffersBeforeDispose: Int, returnedFramesBeforeDispose: Int
    let queueRunningBeforeDiscovery: Bool?, queueRunningAfterDiscovery: Bool?
    let preparationSucceeded: Bool, prestartHALProcessRegistered: Bool
    let cleanupErrors: [String], failure: String?
    let probeSucceeded: Bool
}
func runProbe(_ options: Options, samples: [Float]) throws -> Bool {
    let receiptURL = options.receipt!
    let descriptor = open(receiptURL.path, O_CREAT | O_EXCL | O_WRONLY, mode_t(0o600))
    guard descriptor >= 0 else { throw Failure("Receipt must be new with an existing writable parent (errno \(errno)).") }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? file.close() }
    let signals = Signals(), retained = Unmanaged.passRetained(Context()), context = retained.takeUnretainedValue()
    var queue: AudioQueueRef?, calls: [Call] = [], discoveries: [Discovery] = []
    var cleanup: [String] = [], failure: String?, prepared = false, registered = false
    var referenceQueued = 0, zeroQueued = 0, beforeRunning: Bool?, afterRunning: Bool?
    var uidForSanitization: String?
    func record(_ label: String, _ status: OSStatus, value: Float? = nil, matches: Bool? = nil) {
        calls.append(Call(operation: label, status: status, monotonicSeconds: ProcessInfo.processInfo.systemUptime,
                          value: status == noErr ? value : nil, selectedDeviceMatches: matches))
    }
    func check(_ label: String, _ status: OSStatus) throws { record(label, status); guard status == noErr else { throw Failure("\(label) failed (\(status)).") } }
    func parameters(_ stage: String, _ queue: AudioQueueRef) {
        for (label, parameter) in [("volume", kAudioQueueParam_Volume), ("rampSeconds", kAudioQueueParam_VolumeRampTime)] {
            var value: AudioQueueParameterValue = 0
            let status = AudioQueueGetParameter(queue, parameter, &value)
            record(stage + "." + label, status, value: value.isFinite ? value : nil)
        }
    }
    func running(_ stage: String, _ queue: AudioQueueRef) -> Bool? {
        var value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioQueueGetProperty(queue, kAudioQueueProperty_IsRunning, &value, &size)
        record(stage + ".isRunning", status, value: status == noErr ? Float(value) : nil)
        return status == noErr && size == 4 ? value != 0 : nil
    }
    do {
        discoveries.append(observeProcess(stage: "beforeDeviceInspectionAndNewOutput", elapsed: 0))
        let (_, uid) = try blackHole(); uidForSanitization = uid
        var format = AudioStreamBasicDescription(mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
            mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        let create = AudioQueueNewOutput(&format, { opaque, _, buffer in
            guard let opaque else { return }
            let context = Unmanaged<Context>.fromOpaque(opaque).takeUnretainedValue()
            context.returnedBuffers += 1; context.returnedFrames += Int(buffer.pointee.mAudioDataByteSize) / 8
        }, retained.toOpaque(), CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue, 0, &queue)
        try check("newOutput", create)
        discoveries.append(observeProcess(stage: "afterNewOutput", elapsed: 0))
        guard let queue else { throw Failure("AudioQueue returned no queue.") }
        var deviceUID = uid as CFString
        let selected = withUnsafePointer(to: &deviceUID) { AudioQueueSetProperty(queue, kAudioQueueProperty_CurrentDevice, $0, UInt32(MemoryLayout<CFString>.size)) }
        try check("setCurrentDeviceBlackHole", selected)
        var returned: Unmanaged<CFString>?, stringSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let deviceRead = AudioQueueGetProperty(queue, kAudioQueueProperty_CurrentDevice, &returned, &stringSize)
        let matches = deviceRead == noErr && returned?.takeUnretainedValue() as String? == uid
        record("getCurrentDeviceBlackHole", deviceRead, matches: matches)
        guard matches else { throw Failure("Explicit BlackHole selection readback failed (\(deviceRead)).") }
        discoveries.append(observeProcess(stage: "afterExplicitDeviceBinding", elapsed: 0))
        parameters("beforeOptionalUnity", queue)
        if options.mode == "explicit-unity" { try check("setVolumeUnityOnce", AudioQueueSetParameter(queue, kAudioQueueParam_Volume, 1)) }
        parameters("afterOptionalUnity", queue)
        for (label, frames) in [("reference", 220500), ("postrollZeros", 441000)] {
            var buffer: AudioQueueBufferRef?
            try check("allocate." + label, AudioQueueAllocateBuffer(queue, UInt32(frames * 8), &buffer))
            guard let buffer else { throw Failure("Missing AudioQueue buffer.") }
            if label == "reference" { _ = samples.withUnsafeBytes { memcpy(buffer.pointee.mAudioData, $0.baseAddress!, $0.count) } }
            else { memset(buffer.pointee.mAudioData, 0, frames * 8) }
            buffer.pointee.mAudioDataByteSize = UInt32(frames * 8)
            try check("enqueue." + label, AudioQueueEnqueueBuffer(queue, buffer, 0, nil))
            if label == "reference" { referenceQueued = frames } else { zeroQueued = frames }
        }
        beforeRunning = running("beforeDiscovery", queue)
        guard beforeRunning == false else { throw Failure("Queue is unexpectedly running or its state is unavailable.") }
        prepared = true
        let began = ProcessInfo.processInfo.systemUptime
        repeat {
            if let number = signals.received { throw Failure("Interrupted by signal \(number).") }
            let observation = observeProcess(stage: "afterEnqueuePolling", elapsed: ProcessInfo.processInfo.systemUptime - began)
            discoveries.append(observation)
            registered = observation.nonzeroObject && observation.pidMatches == true
            if registered { break }
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.045)); Thread.sleep(forTimeInterval: 0.005)
        } while ProcessInfo.processInfo.systemUptime - began < 5
        afterRunning = running("afterDiscovery", queue); parameters("beforeDispose", queue)
        guard afterRunning == false, context.returnedBuffers == 0 else { throw Failure("Unexpected queue activity before any playback request.") }
        if !registered { failure = "PRESTART_REGISTRATION_UNAVAILABLE: no nonzero HAL process object with matching PID within five seconds; no audio warmup attempted." }
    } catch { failure = error.localizedDescription }
    let returnedBeforeDispose = context.returnedBuffers, framesBeforeDispose = context.returnedFrames
    if let active = queue {
        let status = AudioQueueDispose(active, true); record("disposeImmediate", status)
        if status == noErr { queue = nil }
        else { cleanup.append("AudioQueueDispose failed (\(status)); callback storage retained until process exit.") }
    }
    if queue == nil { retained.release() }
    func sanitize(_ text: String) -> String {
        var result = text.replacingOccurrences(of: options.reference.path, with: "<reference>").replacingOccurrences(of: receiptURL.path, with: "<receipt>").replacingOccurrences(of: NSHomeDirectory(), with: "<home>")
        if let uidForSanitization { result = result.replacingOccurrences(of: uidForSanitization, with: "<device>") }
        return result
    }
    let success = prepared && registered && failure == nil && cleanup.isEmpty
    let receipt = Receipt(mode: options.mode, referenceSHA256: expectedHash,
        binarySHA256: digest(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]))),
        calls: calls, discovery: discoveries, referenceFramesEnqueued: referenceQueued, zeroFramesEnqueued: zeroQueued,
        returnedBuffersBeforeDispose: returnedBeforeDispose, returnedFramesBeforeDispose: framesBeforeDispose,
        queueRunningBeforeDiscovery: beforeRunning, queueRunningAfterDiscovery: afterRunning,
        preparationSucceeded: prepared, prestartHALProcessRegistered: registered,
        cleanupErrors: cleanup.map(sanitize), failure: failure.map(sanitize), probeSucceeded: success)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(receipt); try file.write(contentsOf: data); try file.write(contentsOf: Data([10])); try file.synchronize()
    FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
    return success
}
if CommandLine.arguments.dropFirst().contains("--help") { print(help); exit(EXIT_SUCCESS) }
do {
    if Array(CommandLine.arguments.dropFirst()) == ["--signal-check"] {
        try signalLifecycleCheck(); exit(EXIT_SUCCESS)
    }
    let options = try Options(Array(CommandLine.arguments.dropFirst())), samples = try referenceSamples(options.reference)
    if options.offline { print("OFFLINE_OK: canonical SHA-256 and all \(samples.count) integer/Float32 samples verified; no audio APIs used.") }
    else if try !runProbe(options, samples: samples) { exit(EXIT_FAILURE) }
} catch {
    FileHandle.standardError.write(Data(("audioqueue-registration: \(error.localizedDescription)\n").utf8)); exit(EXIT_FAILURE)
}
