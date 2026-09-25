import AudioToolbox
import CoreAudio
import CryptoKit
import Darwin
import FiloCore
import FiloPCM
import Foundation

let help = """
Usage: audioqueue-first-start --reference ORIGINAL.wav --output DAC_NAME --mode default|explicit-unity --receipt NEW.json
       audioqueue-first-start --offline-check --reference ORIGINAL.wav
       audioqueue-first-start --signal-check
Experimental scratch FiloCore uses TapAutoStart=false, unlike production main.
One unstarted child AudioQueue binds BlackHole and enqueues the original reference
once followed by ten seconds of zeros. Parent arms exclusive raw output capture
before one GO. No AudioQueuePrime, source prerender, or separate silent renderer.
Only the exact canonical five-second 44.1 kHz 24-bit stereo fixture is accepted.
--help, --offline-check and --signal-check do not access audio hardware.
"""
struct Failure: LocalizedError {
    let text: String
    var errorDescription: String? { text }
    init(_ text: String) { self.text = text }
}
struct Options {
    let reference: URL, receipt: URL?
    let mode: String, output: String?
    let offline: Bool, child: Bool
    init(_ arguments: [String]) throws {
        var values: [String: String] = [:], flags: Set<String> = [], index = 0
        while index < arguments.count {
            let key = arguments[index]
            if ["--offline-check", "--child"].contains(key), !flags.contains(key) { flags.insert(key); index += 1; continue }
            guard ["--reference", "--receipt", "--mode", "--output"].contains(key), values[key] == nil,
                  index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else { throw Failure(help) }
            values[key] = arguments[index + 1]; index += 2
        }
        guard let path = values["--reference"], flags.count <= 1 else { throw Failure(help) }
        let offline = flags.contains("--offline-check"), child = flags.contains("--child")
        if offline { guard values.count == 1 else { throw Failure(help) } }
        else {
            guard ["default", "explicit-unity"].contains(values["--mode"] ?? "") else { throw Failure(help) }
            if child { guard values["--receipt"] == nil, values["--output"] == nil else { throw Failure(help) } }
            else { guard values["--receipt"] != nil, values["--output"] != nil else { throw Failure(help) } }
        }
        reference = URL(fileURLWithPath: path).standardizedFileURL
        receipt = values["--receipt"].map { URL(fileURLWithPath: $0).standardizedFileURL }
        mode = values["--mode"] ?? "offline"; output = values["--output"]
        self.offline = offline; self.child = child
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
func progress(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
func pump() { _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02)); Thread.sleep(forTimeInterval: 0.005) }
struct QueueMetrics: Codable {
    var referenceFramesEnqueued = 0, zeroFramesEnqueued = 0, referenceEnqueueCount = 0
    var referenceBuffersReturnedForReuse = 0, zeroBuffersReturnedForReuse = 0, framesReturnedForReuse = 0
    var startCalls = 0, startSucceeded = false
    var lastRunningReadStatus: Int32?, lastRunningReadValue: Bool?
    var framesReturnedBeforeStop: Int?, referenceBuffersReturnedBeforeStop: Int?
}
struct ChildEvent: Codable {
    let event: String
    var monotonicSeconds = ProcessInfo.processInfo.systemUptime
    var referenceSHA256: String?
    var metrics: QueueMetrics?
    var calls: [Call]?
    var cleanupErrors: [String]?
    var error: String?
}
func send(_ event: ChildEvent) throws {
    try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(event)); try FileHandle.standardOutput.write(contentsOf: Data([10]))
}
final class QueueState {
    var queue: AudioQueueRef?, metrics = QueueMetrics(), calls: [Call] = [], cleaned = false
    func record(_ label: String, _ status: OSStatus, value: Float? = nil, matches: Bool? = nil) {
        calls.append(Call(operation: label, status: status, monotonicSeconds: ProcessInfo.processInfo.systemUptime,
                          value: status == noErr ? value : nil, selectedDeviceMatches: matches))
    }
    func check(_ label: String, _ status: OSStatus) throws {
        record(label, status); guard status == noErr else { throw Failure("\(label) failed (\(status)).") }
    }
    func parameters(_ stage: String) {
        guard let queue else { return }
        for (label, parameter) in [("volume", kAudioQueueParam_Volume), ("rampSeconds", kAudioQueueParam_VolumeRampTime)] {
            var value: AudioQueueParameterValue = 0
            let status = AudioQueueGetParameter(queue, parameter, &value)
            record(stage + "." + label, status, value: value.isFinite ? value : nil)
        }
    }
    func observeRunning() {
        guard let queue else { return }
        var value: UInt32 = 0, size: UInt32 = 4
        let status = AudioQueueGetProperty(queue, kAudioQueueProperty_IsRunning, &value, &size)
        metrics.lastRunningReadStatus = status; metrics.lastRunningReadValue = status == noErr && size == 4 ? value != 0 : nil
    }
    func finish() -> ChildEvent {
        var errors: [String] = []
        parameters("beforeStop"); observeRunning()
        metrics.framesReturnedBeforeStop = metrics.framesReturnedForReuse
        metrics.referenceBuffersReturnedBeforeStop = metrics.referenceBuffersReturnedForReuse
        if let queue {
            if metrics.startSucceeded {
                let status = AudioQueueStop(queue, true); record("stopImmediate", status)
                if status != noErr { errors.append("AudioQueueStop failed (\(status)).") }
            }
            let status = AudioQueueDispose(queue, true); record("disposeImmediate", status)
            if status == noErr { self.queue = nil }
            else { errors.append("AudioQueueDispose failed (\(status)); callback state retained until child exit.") }
        }
        cleaned = true
        return ChildEvent(event: "stopped", metrics: metrics, calls: calls, cleanupErrors: errors)
    }
}
func childMain(_ options: Options, samples: [Float]) throws {
    let signals = Signals(), (_, uid) = try blackHole()
    let retained = Unmanaged.passRetained(QueueState()), state = retained.takeUnretainedValue()
    defer { if !state.cleaned { try? send(state.finish()) }; if state.queue == nil { retained.release() } }
    var format = AudioStreamBasicDescription(mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
        mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    // The supplied main run loop serializes callback metrics with command handling.
    let create = AudioQueueNewOutput(&format, { opaque, _, buffer in
        guard let opaque else { return }
        let state = Unmanaged<QueueState>.fromOpaque(opaque).takeUnretainedValue()
        if buffer.pointee.mUserData == UnsafeMutableRawPointer(bitPattern: 1) { state.metrics.referenceBuffersReturnedForReuse += 1 }
        else { state.metrics.zeroBuffersReturnedForReuse += 1 }
        state.metrics.framesReturnedForReuse += Int(buffer.pointee.mAudioDataByteSize) / 8
    }, retained.toOpaque(), CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue, 0, &state.queue)
    try state.check("newOutput", create)
    guard let queue = state.queue else { throw Failure("No AudioQueue returned.") }
    var deviceUID = uid as CFString
    let select = withUnsafePointer(to: &deviceUID) { AudioQueueSetProperty(queue, kAudioQueueProperty_CurrentDevice, $0, UInt32(MemoryLayout<CFString>.size)) }
    try state.check("setCurrentDeviceBlackHole", select)
    var returned: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let read = AudioQueueGetProperty(queue, kAudioQueueProperty_CurrentDevice, &returned, &size)
    let matches = read == noErr && returned?.takeUnretainedValue() as String? == uid
    state.record("getCurrentDeviceBlackHole", read, matches: matches)
    guard matches else { throw Failure("BlackHole selection was not confirmed (\(read)).") }
    state.parameters("beforeOptionalUnity")
    if options.mode == "explicit-unity" { try state.check("setVolumeUnityOnce", AudioQueueSetParameter(queue, kAudioQueueParam_Volume, 1)) }
    state.parameters("afterOptionalUnity")
    for (tag, frames) in [(1, 220500), (2, 441000)] {
        var buffer: AudioQueueBufferRef?
        try state.check("allocateBuffer\(tag)", AudioQueueAllocateBuffer(queue, UInt32(frames * 8), &buffer))
        guard let buffer else { throw Failure("No AudioQueue buffer returned.") }
        if tag == 1 { _ = samples.withUnsafeBytes { memcpy(buffer.pointee.mAudioData, $0.baseAddress!, $0.count) } }
        else { memset(buffer.pointee.mAudioData, 0, frames * 8) }
        buffer.pointee.mAudioDataByteSize = UInt32(frames * 8); buffer.pointee.mUserData = UnsafeMutableRawPointer(bitPattern: tag)
        try state.check("enqueueBuffer\(tag)", AudioQueueEnqueueBuffer(queue, buffer, 0, nil))
        if tag == 1 { state.metrics.referenceFramesEnqueued = frames; state.metrics.referenceEnqueueCount += 1 }
        else { state.metrics.zeroFramesEnqueued = frames }
    }
    state.observeRunning()
    guard state.metrics.lastRunningReadValue == false, state.metrics.framesReturnedForReuse == 0 else { throw Failure("Queue activity appeared before GO.") }
    try send(ChildEvent(event: "ready", referenceSHA256: expectedHash, metrics: state.metrics, calls: state.calls))
    let descriptor = FileHandle.standardInput.fileDescriptor, flags = fcntl(FileHandle.standardInput.fileDescriptor, F_GETFL)
    guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw Failure("Child stdin setup failed.") }
    var input = Data(); let deadline = ProcessInfo.processInfo.systemUptime + 45
    while ProcessInfo.processInfo.systemUptime < deadline {
        if let number = signals.received { throw Failure("Child interrupted by signal \(number).") }
        pump()
        var bytes = [UInt8](repeating: 0, count: 256)
        let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
        if count == 0 { try send(state.finish()); return }
        if count > 0 { input.append(contentsOf: bytes.prefix(count)) }
        else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { throw Failure("Child command read failed.") }
        guard input.count <= 1024 else { throw Failure("Child command capacity exceeded.") }
        while let end = input.firstIndex(of: 10) {
            let command = String(decoding: input[..<end], as: UTF8.self); input.removeSubrange(...end)
            switch command {
            case "GO":
                guard state.metrics.startCalls == 0 else { throw Failure("Repeated GO rejected.") }
                state.parameters("immediatelyBeforeFirstStart"); state.metrics.startCalls += 1
                let status = AudioQueueStart(queue, nil); state.record("firstStartAfterGO", status)
                state.metrics.startSucceeded = status == noErr; state.parameters("afterFirstStart")
                try send(ChildEvent(event: "goAccepted", metrics: state.metrics, calls: state.calls))
                guard status == noErr else { throw Failure("AudioQueueStart failed (\(status)).") }
            case "STATUS": state.observeRunning(); try send(ChildEvent(event: "status", metrics: state.metrics))
            case "STOP": try send(state.finish()); return
            default: throw Failure("Unknown child command.")
            }
        }
    }
    throw Failure("Child lifetime exceeded 45 seconds.")
}
final class ChildProcess {
    let process = Process(), input = Pipe(), output = Pipe()
    var buffer = Data(), events: [ChildEvent] = [], launched = false, readable = false
    func start(_ options: Options) throws {
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        process.arguments = ["--child", "--reference", options.reference.path, "--mode", options.mode]
        process.standardInput = input; process.standardOutput = output
        try process.run(); launched = true
        try input.fileHandleForReading.close(); try output.fileHandleForWriting.close()
        let descriptor = output.fileHandleForReading.fileDescriptor, flags = fcntl(output.fileHandleForReading.fileDescriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw Failure("Parent handshake setup failed.") }
        readable = true
    }
    func command(_ text: String) throws { try input.fileHandleForWriting.write(contentsOf: Data((text + "\n").utf8)) }
    func poll() throws {
        guard readable else { return }
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(output.fileHandleForReading.fileDescriptor, $0.baseAddress, $0.count) }
            if count > 0 { buffer.append(contentsOf: bytes.prefix(count)) }
            else if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK { break }
            else if errno != EINTR { throw Failure("Parent handshake read failed.") }
        }
        guard buffer.count <= 131072, events.count < 256 else { throw Failure("Parent handshake capacity exceeded.") }
        while let end = buffer.firstIndex(of: 10) {
            let event = try JSONDecoder().decode(ChildEvent.self, from: Data(buffer[..<end])); buffer.removeSubrange(...end); events.append(event)
            if let error = event.error { throw Failure(error) }
        }
    }
    func stop() -> [String] {
        guard launched else { return [] }
        var errors: [String] = []
        if process.isRunning { do { try command("STOP") } catch { errors.append(error.localizedDescription) } }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
            do { try poll() } catch { errors.append(error.localizedDescription) }; pump()
        }
        if process.isRunning {
            process.terminate()
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline { pump() }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            errors.append("Task-owned child required forced teardown; run cannot pass.")
        }
        process.waitUntilExit()
        do { try poll() } catch { errors.append(error.localizedDescription) }
        if let stopped = events.last(where: { $0.event == "stopped" }) { errors += stopped.cleanupErrors ?? [] }
        else { errors.append("Child did not confirm AudioQueue disposal.") }
        if process.terminationStatus != 0 { errors.append("Child exited unsuccessfully.") }
        try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
        return errors
    }
}
struct Receipt: Encodable {
    let mode: String, referenceSHA256: String, binarySHA256: String
    let measurementBoundary = "Whole canonical source through child AudioQueue to actual physical-device callback bytes; USB receiver unmeasured"
    let experimentalTapAutoStart = false
    let experimentalDifference = "Scratch FiloCore changes only aggregate TapAutoStart from production true to false"
    let audioQueuePrimeCalls = 0, separateSilentRenderers = 0, sourcePrefixFramesEnqueued = 0
    let sourceSampleHandling = "Canonical Float32 frames are enqueued once from frame zero, followed by 441000 zero frames; enqueue and returned-for-reuse counters are not rendering evidence"
    let sourceName: String, outputName: String
    let childProcessObjectsBeforeGO: Int, childProcessRunningBeforeGO: Bool?
    let relayStartRequestedAt: Double?, relayStartReturnedAt: Double?, goSentAt: Double?
    let preGOMetrics: ExclusiveRelayMetrics?, metrics: ExclusiveRelayMetrics?
    let outputFormat: PCMFormat?, physicalFormat: PCMFormat?
    let comparison: OutputByteComparison?, rejectionSnapshot: InputRejectionSnapshot?
    let childEvents: [ChildEvent], cleanupErrors: [String], failure: String?
    let passed: Bool
}
func parentMain(_ options: Options, canonicalSamples: [Float]) throws -> Bool {
    let receiptURL = options.receipt!
    let descriptor = open(receiptURL.path, O_CREAT | O_EXCL | O_WRONLY, mode_t(0o600))
    guard descriptor >= 0 else { throw Failure("Receipt must be new with a writable existing parent (errno \(errno)).") }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? file.close() }
    let reference = try ReferencePCM.load(from: options.reference)
    guard reference.fileSHA256 == expectedHash, reference.samples == canonicalSamples else { throw Failure("Reference decoder differs from independently decoded canonical samples.") }
    let signals = Signals(), child = ChildProcess(), session = ExclusiveRelaySession(), route = DeviceLease(journalURL: DeviceLease.defaultJournalURL)
    var devices: [OutputDevice] = [], outputName = options.output!, processCount = 0, processRunning: Bool?
    var failure: String?, cleanup: [String] = [], format: AudioStreamBasicDescription?
    var outputFormat: PCMFormat?, physicalFormat: PCMFormat?, metrics: ExclusiveRelayMetrics?, preGO: ExclusiveRelayMetrics?
    var comparison: OutputByteComparison?, rejection: InputRejectionSnapshot?
    var requestedAt: Double?, returnedAt: Double?, goAt: Double?
    func step() throws {
        pump(); if let number = signals.received { throw Failure("Parent interrupted by signal \(number).") }
        try child.poll(); guard child.process.isRunning else { throw Failure("Child exited before measurement completed.") }
    }
    do {
        devices = try HAL.outputDevices()
        let sources = devices.filter { $0.name == "BlackHole 2ch" && ConnectionController.isExclusiveSourceDevice($0) }
        let outputs = devices.filter { $0.name == options.output }
        guard sources.count == 1, outputs.count == 1, let initialSource = sources.first, let output = outputs.first,
              initialSource.uid != output.uid else { throw Failure("Select one physical output and a separate BlackHole 2ch source.") }
        outputName = output.name
        let endpointRecovery = ExclusiveRecoveryJournal.recoverOrphaned()
        guard endpointRecovery.isEmpty else { throw Failure(endpointRecovery.joined(separator: " ")) }
        let routeRecovery = route.recoverOrphaned()
        guard routeRecovery.isEmpty else { throw Failure(routeRecovery.joined(separator: " ")) }
        try route.begin(output: initialSource); try route.apply(rate: 44100)
        guard let source = try HAL.outputDevices().first(where: { $0.uid == initialSource.uid }) else { throw Failure("BlackHole disconnected.") }
        try child.start(options)
        let readyDeadline = ProcessInfo.processInfo.systemUptime + 10
        while !child.events.contains(where: { $0.event == "ready" }) {
            guard ProcessInfo.processInfo.systemUptime < readyDeadline else { throw Failure("Unstarted child queue did not prepare within 10 seconds.") }; try step()
        }
        guard let ready = child.events.first(where: { $0.event == "ready" }), ready.referenceSHA256 == expectedHash,
              ready.metrics?.startCalls == 0, ready.metrics?.lastRunningReadValue == false,
              ready.metrics?.framesReturnedForReuse == 0, ready.metrics?.referenceEnqueueCount == 1,
              ready.metrics?.referenceFramesEnqueued == 220500, ready.metrics?.zeroFramesEnqueued == 441000 else { throw Failure("Unstarted child handshake is inconsistent.") }
        var processes: [AudioProcess] = []
        let processDeadline = ProcessInfo.processInfo.systemUptime + 5
        repeat {
            processes = try HAL.processes().filter { $0.pid == child.process.processIdentifier && $0.id != kAudioObjectUnknown }
            if !processes.isEmpty { break }; try step()
        } while ProcessInfo.processInfo.systemUptime < processDeadline
        processCount = processes.count; processRunning = processes.isEmpty ? nil : processes.contains { $0.running }
        guard !processes.isEmpty else { throw Failure("No verified nonzero child HAL process before GO; no warmup substitute attempted.") }
        requestedAt = ProcessInfo.processInfo.systemUptime
        progress("ARM_REQUESTED: experimental TapAutoStart=false; child AudioQueue remains unstarted.")
        try session.start(processIDs: processes.map(\.id), source: source, output: output, sourceBits: 24,
                          captureFrames: 44100 * 20, rejectionCaptureFrames: 8192)
        returnedAt = ProcessInfo.processInfo.systemUptime
        format = session.outputASBD; outputFormat = session.outputFormat; physicalFormat = session.physicalFormat
        guard let format, format.mBitsPerChannel == 32, format.mBytesPerFrame == 8,
              format.mFormatFlags == kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonMixable,
              outputFormat == physicalFormat else { throw Failure("Matching interleaved nonmixable signed32 physical/callback formats required.") }
        // Observe once, without requiring input frames, output callbacks, or priming.
        preGO = session.metrics
        progress("ARM_RETURNED: sending GO immediately; no source-preroll condition.")
        goAt = ProcessInfo.processInfo.systemUptime; try child.command("GO")
        let deadline = ProcessInfo.processInfo.systemUptime + 11
        let acknowledgementDeadline = ProcessInfo.processInfo.systemUptime + 3
        var nextStatus: TimeInterval = 0
        while ProcessInfo.processInfo.systemUptime < deadline {
            if ProcessInfo.processInfo.systemUptime >= nextStatus { try child.command("STATUS"); nextStatus = ProcessInfo.processInfo.systemUptime + 0.5 }
            try step(); try session.tick()
            if let accepted = child.events.first(where: { $0.event == "goAccepted" }) {
                guard accepted.metrics?.startSucceeded == true else { throw Failure("AudioQueue first Start failed.") }
            } else if ProcessInfo.processInfo.systemUptime > acknowledgementDeadline { throw Failure("AudioQueue did not acknowledge GO within 3 seconds.") }
            guard session.metrics.renderedCaptureFrames < 44100 * 20 else { throw Failure("Raw output capture capacity exhausted.") }
        }
    } catch { failure = error.localizedDescription }
    if let format {
        let raw = session.finishRawCapture(); metrics = session.metrics; rejection = session.finishInputRejection()
        comparison = OutputByteVerification.compare(capture: raw, format: format, reference: reference)
    } else if session.running { metrics = session.finishMetrics() }
    // Release relay callbacks before stopping the source or restoring clock/routing.
    cleanup += child.stop(); session.stop(); cleanup += session.cleanupErrors
    if session.cleanupErrors.isEmpty { cleanup += route.restore() }
    else { cleanup.append("Route restoration deferred because exclusive teardown failed.") }
    let emitter = child.events.last(where: { $0.event == "stopped" })?.metrics
    let passed = failure == nil && cleanup.isEmpty && comparison?.passed == true && rejection == nil
        && metrics?.fault == 0 && metrics?.invalidBuffers == 0 && metrics?.overflows == 0 && metrics?.underflows == 0
        && metrics?.inputTimestampMissing == 0 && metrics?.outputTimestampMissing == 0
        && metrics?.inputTimestampDiscontinuities == 0 && metrics?.outputTimestampDiscontinuities == 0
        && metrics?.renderedCaptureFrames == metrics?.deliveredFrames
        && emitter?.referenceEnqueueCount == 1 && emitter?.startCalls == 1 && emitter?.startSucceeded == true
        && (comparison?.sampleComparison?.trailingCaptureFrames ?? 0) >= 88200
    func sanitize(_ text: String) -> String {
        var text = text.replacingOccurrences(of: options.reference.path, with: "<reference>").replacingOccurrences(of: receiptURL.path, with: "<receipt>").replacingOccurrences(of: NSHomeDirectory(), with: "<home>")
        for device in devices { text = text.replacingOccurrences(of: device.uid, with: "<device>") }; return text
    }
    let sanitizedEvents = child.events.map { event -> ChildEvent in
        var event = event; event.error = event.error.map(sanitize); event.cleanupErrors = event.cleanupErrors?.map(sanitize); return event
    }
    let receipt = Receipt(mode: options.mode, referenceSHA256: expectedHash,
        binarySHA256: digest(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]))),
        sourceName: "BlackHole 2ch", outputName: outputName, childProcessObjectsBeforeGO: processCount,
        childProcessRunningBeforeGO: processRunning, relayStartRequestedAt: requestedAt, relayStartReturnedAt: returnedAt,
        goSentAt: goAt, preGOMetrics: preGO, metrics: metrics, outputFormat: outputFormat, physicalFormat: physicalFormat,
        comparison: comparison, rejectionSnapshot: rejection, childEvents: sanitizedEvents,
        cleanupErrors: cleanup.map(sanitize), failure: failure.map(sanitize), passed: passed)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(receipt); try file.write(contentsOf: data); try file.write(contentsOf: Data([10])); try file.synchronize()
    try FileHandle.standardOutput.write(contentsOf: data); try FileHandle.standardOutput.write(contentsOf: Data([10]))
    return passed
}
if CommandLine.arguments.dropFirst().contains("--help") { print(help); exit(EXIT_SUCCESS) }
signal(SIGPIPE, SIG_IGN)
do {
    if Array(CommandLine.arguments.dropFirst()) == ["--signal-check"] { try signalLifecycleCheck(); exit(EXIT_SUCCESS) }
    let options = try Options(Array(CommandLine.arguments.dropFirst())), samples = try referenceSamples(options.reference)
    if options.offline { print("OFFLINE_OK: canonical SHA-256 and all \(samples.count) integer/Float32 samples verified; no audio APIs used.") }
    else if options.child { try childMain(options, samples: samples) }
    else if try !parentMain(options, canonicalSamples: samples) { exit(EXIT_FAILURE) }
} catch {
    if CommandLine.arguments.dropFirst().contains("--child") { try? send(ChildEvent(event: "error", error: error.localizedDescription)) }
    else { progress("audioqueue-first-start: \(error.localizedDescription)") }
    exit(EXIT_FAILURE)
}
