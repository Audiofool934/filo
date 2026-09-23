import CoreAudio
import Darwin
import FiloCore
import FiloPCM
import Foundation

// Optional known-fixture laboratory executable. This is not a product player.
let usage = """
Usage: finite-reference --reference FIXTURE.wav --receipt RESULT.json --output DEVICE_NAME
Only the original five-second 44.1 kHz stereo 24-bit generated fixture is accepted.
Requires BlackHole 2ch and matching exclusive signed32 DAC formats.
The receipt is never overwritten. No user music is recorded.
Use --help to print this text without accessing audio hardware.
"""
struct Options {
    let child: Bool
    let reference: URL
    let receipt: URL?
    let output: String?
    init(_ arguments: [String]) throws {
        var values: [String: String] = [:], child = false, index = 0
        while index < arguments.count {
            let option = arguments[index]
            if option == "--child", !child { child = true; index += 1; continue }
            guard ["--reference", "--receipt", "--output"].contains(option),
                  values[option] == nil, index + 1 < arguments.count, !arguments[index + 1].isEmpty else {
                throw AudioFailure(usage)
            }
            values[option] = arguments[index + 1]; index += 2
        }
        guard let reference = values["--reference"],
              child ? values["--receipt"] == nil && values["--output"] == nil
                    : values["--receipt"] != nil && values["--output"] != nil else { throw AudioFailure(usage) }
        self.child = child
        self.reference = URL(fileURLWithPath: reference).standardizedFileURL
        receipt = values["--receipt"].map { URL(fileURLWithPath: $0).standardizedFileURL }
        output = values["--output"]
    }
}
var options: Options!
var referenceURL: URL { options.reference }
var receiptURL: URL { options.receipt! }

func progress(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
func sendEvent(_ value: ChildEvent) throws {
    FileHandle.standardOutput.write(try JSONEncoder().encode(value))
    FileHandle.standardOutput.write(Data([10]))
}
func knownReference() throws -> ReferencePCM {
    let reference = try ReferencePCM.load(from: referenceURL)
    guard reference.sampleRate == 44100, reference.bits == 24, reference.frameCount == 220500 else {
        throw AudioFailure("The fixed reference must be the original five-second 44.1 kHz stereo 24-bit fixture.")
    }
    for index in reference.samples.indices {
        guard reference.samples[index] == filo_test_sample(UInt64(index / 2), UInt32(index % 2), 24) else {
            throw AudioFailure("The fixed WAV is not the original generated fixture.")
        }
    }
    return reference
}
struct EmitterMetrics: Codable {
    let callbacks, outputFrames, emittedFrames, firstFixtureOutputFrame: UInt64
    let timestampMissing, timestampDiscontinuities: UInt64
    let started, completed, fault: Bool
    init(_ m: FiniteReferenceMetrics) {
        callbacks = m.callbacks; outputFrames = m.outputFrames; emittedFrames = m.emittedFrames
        firstFixtureOutputFrame = m.firstFixtureOutputFrame
        timestampMissing = m.timestampMissing; timestampDiscontinuities = m.timestampDiscontinuities
        started = m.started; completed = m.completed; fault = m.fault
    }
}
struct ChildEvent: Codable {
    let event: String
    var referenceSHA256: String?
    var frames: Int?
    var metrics: EmitterMetrics?
    var cleanupErrors: [String]?
    var error: String?
}

func childMain() throws {
    let reference = try knownReference()
    guard let device = try HAL.outputDevices().first(where: ConnectionController.isExclusiveSourceDevice) else {
        throw AudioFailure("BlackHole 2ch is unavailable.")
    }
    let asbd = try HAL.streamFormat(device.id, scope: kAudioObjectPropertyScopeOutput)
    guard PCMFormat(asbd).isFloatStereo, asbd.mSampleRate == reference.sampleRate,
          asbd.mFormatFlags == kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
          asbd.mFramesPerPacket == 1, asbd.mBytesPerFrame == 8, asbd.mBytesPerPacket == 8 else {
        throw AudioFailure("The finite emitter requires one interleaved stereo Float32 stream at the reference rate.")
    }
    guard let state = reference.samples.withUnsafeBufferPointer({ buffer in
        finite_reference_create(buffer.baseAddress!, UInt64(reference.frameCount))
    }) else { throw AudioFailure("Could not preallocate the finite fixture.") }
    var proc: AudioDeviceIOProcID?
    var cleaned = false
    func finish() -> ChildEvent {
        var errors: [String] = []
        if let activeProc = proc {
            let stop = AudioDeviceStop(device.id, activeProc)
            if stop != noErr { errors.append("Emitter stop failed (\(stop)).") }
            let destroy = AudioDeviceDestroyIOProcID(device.id, activeProc)
            if destroy == noErr { proc = nil }
            else { errors.append("Emitter callback release failed (\(destroy)); storage retained until process exit.") }
        }
        let metrics = EmitterMetrics(finite_reference_metrics(state))
        if proc == nil { finite_reference_destroy(state) }
        cleaned = true
        return ChildEvent(event: "stopped", metrics: metrics, cleanupErrors: errors)
    }
    defer { if !cleaned { try? sendEvent(finish()) } }
    try HAL.check(AudioDeviceCreateIOProcID(device.id, finite_reference_io, UnsafeMutableRawPointer(state), &proc), "Create finite emitter callback")
    guard let createdProc = proc else { throw AudioFailure("No finite emitter callback was created.") }
    try HAL.check(AudioDeviceStart(device.id, createdProc), "Start silent finite emitter")
    try sendEvent(ChildEvent(event: "ready", referenceSHA256: reference.fileSHA256, frames: reference.frameCount))
    while let command = readLine() {
        switch command {
        case "GO":
            guard finite_reference_go(state) else { throw AudioFailure("GO was repeated or the emitter had already faulted.") }
            try sendEvent(ChildEvent(event: "goAccepted"))
        case "STATUS": try sendEvent(ChildEvent(event: "status", metrics: EmitterMetrics(finite_reference_metrics(state))))
        case "STOP": try sendEvent(finish()); return
        default: throw AudioFailure("Invalid finite-emitter command.")
        }
    }
    try sendEvent(finish())
}

final class ChildProcess {
    let process = Process(), input = Pipe(), output = Pipe()
    var buffer = Data()
    var events: [ChildEvent] = []
    var launched = false, readable = false
    func start() throws {
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        process.arguments = ["--child", "--reference", referenceURL.path]
        process.standardInput = input; process.standardOutput = output
        try process.run()
        launched = true
        try input.fileHandleForReading.close(); try output.fileHandleForWriting.close()
        let descriptor = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw AudioFailure("Could not make the child handshake nonblocking.")
        }
        readable = true
    }
    func command(_ command: String) throws { try input.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8)) }
    func poll() throws {
        guard launched, readable else { throw AudioFailure("The child handshake is not readable.") }
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(output.fileHandleForReading.fileDescriptor, $0.baseAddress, $0.count) }
            if count > 0 { buffer.append(contentsOf: bytes.prefix(count)) }
            else if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK { break }
            else if errno == EINTR { continue }
            else { throw AudioFailure("Could not read the child handshake.") }
        }
        guard buffer.count <= 65536 else { throw AudioFailure("Child handshake exceeded its bound.") }
        while let end = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
            let event = try JSONDecoder().decode(ChildEvent.self, from: line)
            if let error = event.error { throw AudioFailure(error) }
            events.append(event)
        }
    }
    func stop() -> ([String], EmitterMetrics?) {
        guard launched else { return ([], nil) }
        var errors: [String] = []
        if process.isRunning { do { try command("STOP") } catch { errors.append(error.localizedDescription) } }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
            do { try poll() } catch { errors.append(error.localizedDescription); break }
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        if process.isRunning {
            process.terminate()
            let terminateDeadline = ProcessInfo.processInfo.systemUptime + 1
            while process.isRunning, ProcessInfo.processInfo.systemUptime < terminateDeadline { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            errors.append("The child required forced cleanup; verification fails.")
        }
        if process.processIdentifier > 0 { process.waitUntilExit() }
        do { try poll() } catch { errors.append(error.localizedDescription) }
        if let stopped = events.last(where: { $0.event == "stopped" }) { errors += stopped.cleanupErrors ?? [] }
        else if process.processIdentifier > 0 { errors.append("The child did not confirm callback teardown.") }
        if process.processIdentifier > 0, process.terminationStatus != 0 { errors.append("The child exited unsuccessfully.") }
        try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
        return (errors, events.last(where: { $0.metrics != nil })?.metrics)
    }
}

struct Receipt: Encodable {
    let boundary: String
    let referenceFile, referenceSHA256, outputName: String
    let referenceFrames, referenceBits: Int
    let sampleRate: Double
    let handshake: String
    let outputFormat, physicalFormat: PCMFormat?
    let metrics: ExclusiveRelayMetrics?
    let emitterMetrics: EmitterMetrics?
    let comparison: OutputByteComparison?
    let cleanupErrors: [String]
    let failure: String?
    let passed: Bool
}

func parentMain() throws -> Bool {
    guard !FileManager.default.fileExists(atPath: receiptURL.path) else {
        throw AudioFailure("The requested receipt already exists; choose a new destination.")
    }
    guard FileManager.default.isWritableFile(atPath: receiptURL.deletingLastPathComponent().path) else {
        throw AudioFailure("The receipt directory must exist and be writable before starting audio.")
    }
    let reference = try knownReference()
    let devices = try HAL.outputDevices()
    let outputs = devices.filter { $0.name == options.output }
    guard outputs.count == 1, let output = outputs.first,
          let initialSource = devices.first(where: ConnectionController.isExclusiveSourceDevice), output.uid != initialSource.uid else {
        throw AudioFailure("Choose one unambiguous physical output name with BlackHole 2ch installed separately.")
    }
    let child = ChildProcess(), session = ExclusiveRelaySession()
    let route = DeviceLease(journalURL: DeviceLease.defaultJournalURL)
    var metrics: ExclusiveRelayMetrics?, emitterMetrics: EmitterMetrics?, comparison: OutputByteComparison?
    var outputFormat: PCMFormat?, physicalFormat: PCMFormat?
    var cleanupErrors: [String] = [], failure: String?
    var interrupted: Int32?
    let signalNumbers = [SIGINT, SIGTERM, SIGHUP]
    let oldSignals = signalNumbers.map { signal($0, SIG_IGN) }
    let signalSources = signalNumbers.map { number in
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler { interrupted = number }; source.resume(); return source
    }
    defer {
        signalSources.forEach { $0.cancel() }
        for (number, old) in zip(signalNumbers, oldSignals) { signal(number, old) }
    }
    func briefWait() throws {
        let end = ProcessInfo.processInfo.systemUptime + 0.1
        repeat {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
            Thread.sleep(forTimeInterval: 0.005)
        } while ProcessInfo.processInfo.systemUptime < end
        if let interrupted { throw AudioFailure("Interrupted by signal \(interrupted).") }
        try child.poll()
        guard child.process.isRunning else { throw AudioFailure("The finite emitter exited before measurement completed.") }
    }
    do {
        let endpointRecovery = ExclusiveRecoveryJournal.recoverOrphaned()
        guard endpointRecovery.isEmpty else { throw AudioFailure(endpointRecovery.joined(separator: " ")) }
        let recovery = route.recoverOrphaned()
        guard recovery.isEmpty else { throw AudioFailure(recovery.joined(separator: " ")) }
        try route.begin(output: initialSource); try route.apply(rate: reference.sampleRate)
        guard let source = try HAL.outputDevices().first(where: { $0.uid == initialSource.uid }) else { throw AudioFailure("BlackHole disconnected.") }
        try child.start()
        let readyDeadline = ProcessInfo.processInfo.systemUptime + 10
        while !child.events.contains(where: { $0.event == "ready" }) {
            guard ProcessInfo.processInfo.systemUptime < readyDeadline else { throw AudioFailure("The silent child did not become ready.") }
            try briefWait()
        }
        guard let ready = child.events.first(where: { $0.event == "ready" }), ready.referenceSHA256 == reference.fileSHA256,
              ready.frames == reference.frameCount else { throw AudioFailure("Parent and child references disagree.") }
        let processIDs = try HAL.processes().filter { $0.pid == child.process.processIdentifier }.map(\.id)
        let captureCapacity = UInt64(reference.sampleRate * 20)
        try session.start(processIDs: processIDs, source: source, output: output, sourceBits: 24, captureFrames: captureCapacity)
        let format = session.outputASBD
        outputFormat = session.outputFormat; physicalFormat = session.physicalFormat
        guard format.mBitsPerChannel == 32, format.mBytesPerFrame == 8,
              format.mFormatFlags == kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonMixable,
              outputFormat == physicalFormat else { throw AudioFailure("This run requires matching interleaved signed32 nonmixable callback and physical formats.") }
        let primeDeadline = ProcessInfo.processInfo.systemUptime + 5
        var primedAt: TimeInterval?
        while primedAt == nil || ProcessInfo.processInfo.systemUptime - primedAt! < 0.5 {
            guard ProcessInfo.processInfo.systemUptime < primeDeadline else { throw AudioFailure("The silent relay did not prime before GO.") }
            try briefWait(); try session.tick()
            let m = session.metrics
            guard m.inputTimestampMissing == 0, m.outputTimestampMissing == 0 else { throw AudioFailure("Timestamp evidence was missing during preroll.") }
            if m.started, m.deliveredFrames > 0, primedAt == nil { primedAt = ProcessInfo.processInfo.systemUptime }
        }
        progress("READY_ARMED: silent source and exclusive signed32 output are running; sending GO once.")
        try child.command("GO")
        let finishDeadline = ProcessInfo.processInfo.systemUptime + 12
        var nextStatus: TimeInterval = 0, completedAt: TimeInterval?
        while completedAt == nil || ProcessInfo.processInfo.systemUptime - completedAt! < 3 {
            let now = ProcessInfo.processInfo.systemUptime
            guard now < finishDeadline else { throw AudioFailure("The complete fixture and postroll exceeded their deadline.") }
            if now >= nextStatus { try child.command("STATUS"); nextStatus = now + 0.25 }
            try briefWait(); try session.tick()
            if let m = child.events.last(where: { $0.metrics != nil })?.metrics {
                guard !m.fault, m.timestampMissing == 0, m.timestampDiscontinuities == 0 else { throw AudioFailure("The finite emitter failed its continuity checks.") }
                if m.completed, completedAt == nil {
                    guard m.emittedFrames == UInt64(reference.frameCount) else { throw AudioFailure("The child did not emit exactly one complete fixture.") }
                    completedAt = ProcessInfo.processInfo.systemUptime
                    progress("SOURCE_COMPLETE: preserving three seconds of silent postroll.")
                }
            }
            guard session.metrics.renderedCaptureFrames < captureCapacity else { throw AudioFailure("The bounded raw-output capture filled before measurement completed.") }
        }
        let raw = session.finishRawCapture()
        metrics = session.metrics
        comparison = OutputByteVerification.compare(capture: raw, format: format, reference: reference)
    } catch { failure = error.localizedDescription }
    // Stop relay callbacks before stopping the zero-emitting child or restoring its clock.
    if session.running { metrics = session.finishMetrics() }
    let childCleanup = child.stop(); cleanupErrors += childCleanup.0; emitterMetrics = childCleanup.1
    session.stop(); cleanupErrors += session.cleanupErrors
    if session.cleanupErrors.isEmpty { cleanupErrors += route.restore() }
    else { cleanupErrors.append("Route restoration deferred until exclusive callback/configuration recovery succeeds.") }
    let m = metrics, e = emitterMetrics, sample = comparison?.sampleComparison
    let passed = failure == nil && cleanupErrors.isEmpty && comparison?.passed == true
        && m?.fault == 0 && m?.inputTimestampMissing == 0 && m?.outputTimestampMissing == 0
        && m?.inputTimestampDiscontinuities == 0 && m?.outputTimestampDiscontinuities == 0
        && m?.renderedCaptureFrames == m?.deliveredFrames
        && e?.completed == true && e?.emittedFrames == UInt64(reference.frameCount) && e?.fault == false
        && e?.timestampMissing == 0 && e?.timestampDiscontinuities == 0
        && (sample?.leadingCaptureFrames ?? 0) >= 512 && (sample?.trailingCaptureFrames ?? 0) >= 88200
    func sanitize(_ text: String) -> String {
        var result = text.replacingOccurrences(of: referenceURL.path, with: "<reference>")
            .replacingOccurrences(of: receiptURL.path, with: "<receipt>")
            .replacingOccurrences(of: FileManager.default.currentDirectoryPath, with: "<working-directory>")
            .replacingOccurrences(of: NSHomeDirectory(), with: "<home>")
        for device in devices { result = result.replacingOccurrences(of: device.uid, with: "<device>") }
        return result
    }
    let receipt = Receipt(boundary: "Complete original fixture through actual physical-device signed32 output callback; USB receiver and player decoding unmeasured",
        referenceFile: referenceURL.lastPathComponent, referenceSHA256: reference.fileSHA256, outputName: output.name,
        referenceFrames: reference.frameCount, referenceBits: reference.bits, sampleRate: reference.sampleRate,
        handshake: "Child continuously emits zero, parent primes and captures, one GO emits the fixture once, then three seconds of postroll",
        outputFormat: outputFormat, physicalFormat: physicalFormat, metrics: metrics, emitterMetrics: emitterMetrics,
        comparison: comparison, cleanupErrors: cleanupErrors.map(sanitize), failure: failure.map(sanitize), passed: passed)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(receipt)
    try data.write(to: receiptURL, options: .withoutOverwriting)
    FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
    return passed
}

if CommandLine.arguments.dropFirst().contains("--help") { print(usage); exit(EXIT_SUCCESS) }
signal(SIGPIPE, SIG_IGN)
do {
    options = try Options(Array(CommandLine.arguments.dropFirst()))
    if options.child { try childMain() }
    else if try !parentMain() { exit(EXIT_FAILURE) }
} catch {
    if CommandLine.arguments.dropFirst().contains("--child") { try? sendEvent(ChildEvent(event: "error", error: error.localizedDescription)) }
    else { progress("finite-reference: \(error.localizedDescription)") }
    exit(EXIT_FAILURE)
}
