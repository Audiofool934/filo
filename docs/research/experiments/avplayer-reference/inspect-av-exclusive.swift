import CoreAudio
import CryptoKit
import Darwin
import FiloCore
import FiloPCM
import Foundation

// Task-only measurement of one complete, independently validated synthetic ALAC file.
let usage = """
Usage: work/inspect-av-exclusive
Plays only the original five-second 44100/24 stereo ALAC fixture through AVAudioPlayer.
Resolves WALKMAN by its current name and BlackHole using filo's source-device predicate.
Captures the actual exclusive signed32 DAC software output callback in memory.
Writes work/avplayer-exclusive-reference.json only if it does not already exist.
Measurement deadline: 20 seconds; bounded child teardown reserves up to 4 seconds.
Synchronous CoreAudio calls cannot be interrupted safely by this control-loop deadline.
Requires existing recording permission. No subscription audio or receiver capture is used.
Use --help to print this text without reading the fixture or accessing audio hardware.
"""
let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
let work = executableURL.deletingLastPathComponent()
let repository = work.deletingLastPathComponent()
let referenceURL = work.appendingPathComponent("reference-server/filo-reference-44100-24.m4a")
let receiptURL = work.appendingPathComponent("avplayer-exclusive-reference.json")
func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
func progress(_ value: String) { FileHandle.standardError.write(Data((value + "\n").utf8)) }
func digest(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}

struct PlayerProperties: Codable {
    let volume, pan, rate, sampleRate: Double
    let enableRate: Bool
    let numberOfLoops, channelCount: Int
    func isNeutral(loops: Int) -> Bool {
        volume == 1 && pan == 0 && !enableRate && rate == 1 && sampleRate == 44100
            && numberOfLoops == loops && channelCount == 2
    }
}
struct ChildEvent: Codable {
    let event: String
    var pid: Int32?
    var mode, referenceSHA256: String?
    var sampleRate: Double?
    var bits, frames: Int?
    var halOutputActive, silencePlaying: Bool?
    var referencePlayer, silencePlayer: PlayerProperties?
    var ready, started, completed, playing, completionSucceeded: Bool?
    var currentTime, duration, elapsed: Double?
    var reason, error: String?
    var sanitized: ChildEvent { var result = self; result.pid = nil; return result }
}

// The same newline JSON protocol used by inspect-api-reference, with bounded teardown.
final class Child {
    let process = Process(), input = Pipe(), output = Pipe()
    var pending = Data(), events: [ChildEvent] = []
    var launched = false, readable = false
    func start() throws {
        process.executableURL = work.appendingPathComponent("av-reference-player")
        process.arguments = ["--mode", "alac"]
        process.currentDirectoryURL = repository
        process.standardInput = input; process.standardOutput = output
        try process.run(); launched = true
        try input.fileHandleForReading.close(); try output.fileHandleForWriting.close()
        let fd = output.fileHandleForReading.fileDescriptor, flags = fcntl(output.fileHandleForReading.fileDescriptor, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw AudioFailure("Could not make the child handshake nonblocking.")
        }
        readable = true
    }
    func command(_ value: String) throws {
        try input.fileHandleForWriting.write(contentsOf: Data((value + "\n").utf8))
    }
    func poll() throws {
        guard launched, readable else { throw AudioFailure("The child handshake is unavailable.") }
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(output.fileHandleForReading.fileDescriptor, $0.baseAddress, $0.count) }
            if count > 0 { pending.append(contentsOf: bytes.prefix(count)) }
            else if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK { break }
            else if errno == EINTR { continue }
            else { throw AudioFailure("Could not read the child handshake.") }
            guard pending.count <= 65536 else { throw AudioFailure("The child handshake exceeded its bound.") }
        }
        while let end = pending.firstIndex(of: 10) {
            let line = Data(pending[..<end]); pending.removeSubrange(...end)
            let event = try JSONDecoder().decode(ChildEvent.self, from: line)
            if let error = event.error { throw AudioFailure(error) }
            if let pid = event.pid, pid != process.processIdentifier { throw AudioFailure("Unexpected child identity.") }
            events.append(event)
            guard events.count <= 512 else { throw AudioFailure("Too many child handshake events.") }
        }
    }
    func stop() -> [String] {
        guard launched else {
            try? input.fileHandleForReading.close(); try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
            return []
        }
        var errors: [String] = []
        if process.isRunning { do { try command("STOP") } catch { errors.append(error.localizedDescription) } }
        let deadline = uptime() + 3
        while process.isRunning, uptime() < deadline {
            if readable { do { try poll() } catch { errors.append(error.localizedDescription); break } }
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
            Thread.sleep(forTimeInterval: 0.005)
        }
        if process.isRunning {
            process.terminate()
            let deadline = uptime() + 1
            while process.isRunning, uptime() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            errors.append("The child required forced cleanup; verification fails.")
        }
        process.waitUntilExit()
        if readable { do { try poll() } catch { errors.append(error.localizedDescription) } }
        if !events.contains(where: { $0.event == "stopped" && $0.reason == "command" }) {
            errors.append("The child did not confirm the requested player shutdown.")
        }
        if process.terminationStatus != 0 { errors.append("The child exited unsuccessfully.") }
        try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
        return errors
    }
}

struct Timeline: Encodable {
    let deadlineSeconds = 20.0
    let postrollSeconds = 2.0
    var childLaunched, childReady, captureStarted, armed, goSent, goAccepted: Double?
    var sourceCompletionObserved, captureStopped, cleanupCompleted: Double?
}
struct Receipt: Encodable {
    let boundary, sourceAPI, sourceCallbackTimestampEvidence, createdAt, systemVersion: String
    let referenceFile, referenceSHA256, sourceFormat, outputName: String
    let referenceFrames, referenceBits: Int
    let sampleRate: Double
    let sourceSHA256, binarySHA256, linkedObjectSHA256: [String: String]
    let playerReady, playerCompletion: ChildEvent?
    let sourceCallbackTimestampsAvailable: Bool
    let timeline: Timeline
    let inputFormat, outputFormat, physicalFormat: PCMFormat?
    let clockPitch: Float
    let clockTargetFrames: UInt64
    let metrics: ExclusiveRelayMetrics?
    let comparison: OutputByteComparison?
    let checks: [String: Bool]
    let cleanupErrors: [String]
    let failure: String?
    let passed: Bool
}

func main() throws -> Bool {
    guard !FileManager.default.fileExists(atPath: receiptURL.path),
          FileManager.default.isWritableFile(atPath: work.path) else {
        throw AudioFailure("The fixed receipt already exists or its directory is not writable.")
    }
    let reference = try ReferencePCM.load(from: referenceURL, maximumFrames: 220500)
    guard reference.sourceFormat == "ALAC", reference.sampleRate == 44100,
          reference.bits == 24, reference.frameCount == 220500, reference.samples.count == 441000 else {
        throw AudioFailure("Only the original five-second 44100/24 stereo ALAC fixture is accepted.")
    }
    for index in reference.samples.indices {
        guard reference.samples[index] == filo_test_sample(UInt64(index / 2), UInt32(index % 2), 24) else {
            throw AudioFailure("The reference differs from the original synthetic sample sequence.")
        }
    }
    guard try digest(referenceURL) == reference.fileSHA256 else { throw AudioFailure("The reference changed during validation.") }
    let sourceNames = ["work/inspect-av-exclusive.swift", "work/av-reference-player.swift",
        "Sources/FiloCore/ReferencePCM.swift", "Sources/FiloCore/OutputByteVerification.swift",
        "Sources/FiloCore/ExclusiveRelaySession.swift", "Sources/FiloCore/ClockFollower.swift",
        "Sources/FiloPCM/Bridge.c", "Sources/FiloPCM/Transport.c"]
    let sourceHashes = try Dictionary(uniqueKeysWithValues: sourceNames.map { ($0, try digest(repository.appendingPathComponent($0))) })
    let binaryHashes = try ["inspect-av-exclusive": digest(executableURL),
                            "av-reference-player": digest(work.appendingPathComponent("av-reference-player"))]
    // Record object identities separately; source hashes alone do not prove how an object was built.
    var objectHashes: [String: String] = [:]
    for module in ["FiloCore.build", "FiloPCM.build"] {
        let directory = repository.appendingPathComponent(".build/arm64-apple-macosx/debug/\(module)")
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where file.lastPathComponent.hasSuffix(".swift.o") || file.lastPathComponent.hasSuffix(".c.o") {
            objectHashes["\(module)/\(file.lastPathComponent)"] = try digest(file)
        }
    }
    let child = Child(), session = ExclusiveRelaySession()
    let route = DeviceLease(journalURL: DeviceLease.defaultJournalURL)
    let startedAt = uptime(), deadline = startedAt + 20
    var timeline = Timeline(), devices: [OutputDevice] = [], outputName = "WALKMAN"
    var metrics: ExclusiveRelayMetrics?, comparison: OutputByteComparison?
    var inputFormat: PCMFormat?, outputFormat: PCMFormat?, physicalFormat: PCMFormat?
    var clockPitch: Float = 0.5, clockTargetFrames: UInt64 = 0
    var failure: String?, cleanupErrors: [String] = []
    var ready: ChildEvent?, completion: ChildEvent?, interrupted: Int32?
    let signalNumbers = [SIGINT, SIGTERM, SIGHUP]
    let oldSignals = signalNumbers.map { signal($0, SIG_IGN) }
    let signals = signalNumbers.map { number in
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler { interrupted = number }; source.resume(); return source
    }
    defer {
        signals.forEach { $0.cancel() }
        for (number, old) in zip(signalNumbers, oldSignals) { signal(number, old) }
    }
    func ensureDeadline() throws {
        if let interrupted { throw AudioFailure("Interrupted by signal \(interrupted).") }
        guard uptime() < deadline else { throw AudioFailure("The 20-second measurement deadline expired.") }
    }
    func advance(source: OutputDevice) throws {
        let end = uptime() + 0.05
        repeat {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
            Thread.sleep(forTimeInterval: 0.005)
        } while uptime() < end
        try ensureDeadline(); try child.poll()
        guard child.process.isRunning else { throw AudioFailure("The reference child exited before measurement completed.") }
        guard try HAL.defaultOutput() == source.id, try HAL.rate(source.id) == reference.sampleRate else {
            throw AudioFailure("The reference route or rate changed during measurement.")
        }
        if session.running {
            try session.tick()
            let m = session.metrics
            guard m.inputTimestampMissing == 0, m.outputTimestampMissing == 0,
                  m.inputTimestampDiscontinuities == 0, m.outputTimestampDiscontinuities == 0 else {
                throw AudioFailure("Capture or output timestamp continuity was not established.")
            }
        }
    }
    do {
        let exclusiveRecovery = ExclusiveRecoveryJournal.recoverOrphaned()
        guard exclusiveRecovery.isEmpty else { throw AudioFailure(exclusiveRecovery.joined(separator: " ")) }
        let routeRecovery = route.recoverOrphaned()
        guard routeRecovery.isEmpty else { throw AudioFailure(routeRecovery.joined(separator: " ")) }
        try ensureDeadline()
        devices = try HAL.outputDevices()
        let outputs = devices.filter { $0.name == "WALKMAN" }
        let sources = devices.filter(ConnectionController.isExclusiveSourceDevice)
        guard outputs.count == 1, let initialOutput = outputs.first,
              sources.count == 1, let initialSource = sources.first, initialOutput.uid != initialSource.uid else {
            throw AudioFailure("One unambiguous WALKMAN and one separate BlackHole source are required.")
        }
        outputName = initialOutput.name
        try route.begin(output: initialSource); try route.apply(rate: reference.sampleRate)
        let currentDevices = try HAL.outputDevices()
        guard let source = currentDevices.first(where: { $0.uid == initialSource.uid }),
              let output = currentDevices.first(where: { $0.uid == initialOutput.uid && $0.name == "WALKMAN" }) else {
            throw AudioFailure("A required output disconnected before measurement.")
        }
        try ensureDeadline(); try child.start(); timeline.childLaunched = uptime() - startedAt
        let readyDeadline = min(deadline, uptime() + 8)
        var processIDs: [AudioObjectID] = []
        while ready == nil || processIDs.isEmpty {
            guard uptime() < readyDeadline else { throw AudioFailure("The silent reference player did not become ready.") }
            try advance(source: source)
            ready = child.events.first(where: { $0.event == "ready" })
            processIDs = try HAL.processes().filter { $0.pid == child.process.processIdentifier && $0.running }.map(\.id)
        }
        guard let ready, ready.pid == child.process.processIdentifier, ready.mode == "alac",
              ready.referenceSHA256 == reference.fileSHA256, ready.sampleRate == reference.sampleRate,
              ready.bits == reference.bits, ready.frames == reference.frameCount,
              ready.halOutputActive == true, ready.silencePlaying == true,
              ready.referencePlayer?.isNeutral(loops: 0) == true,
              ready.silencePlayer?.isNeutral(loops: -1) == true else {
            throw AudioFailure("The child did not confirm the exact reference and neutral player properties.")
        }
        timeline.childReady = uptime() - startedAt
        let captureCapacity: UInt64 = 44100 * 18
        try session.start(processIDs: processIDs, source: source, output: output, sourceBits: 24, captureFrames: captureCapacity)
        timeline.captureStarted = uptime() - startedAt
        let format = session.outputASBD
        inputFormat = session.inputFormat; outputFormat = session.outputFormat; physicalFormat = session.physicalFormat
        guard format.mFormatID == kAudioFormatLinearPCM, format.mSampleRate == 44100,
              format.mChannelsPerFrame == 2, format.mBitsPerChannel == 32, format.mBytesPerFrame == 8,
              format.mFramesPerPacket == 1, format.mBytesPerPacket == 8, format.mReserved == 0,
              format.mFormatFlags == kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonMixable,
              outputFormat == physicalFormat, inputFormat?.rate == 44100, inputFormat?.isFloatStereo == true else {
            throw AudioFailure("The capture and physical output formats do not satisfy this exact signed32 experiment.")
        }
        let primeDeadline = min(deadline, uptime() + 4)
        var primedAt: TimeInterval?
        while primedAt == nil || uptime() - primedAt! < 0.5 {
            guard uptime() < primeDeadline else { throw AudioFailure("The exclusive relay did not prime before GO.") }
            try advance(source: source)
            let m = session.metrics
            if m.started, m.deliveredFrames > 0, primedAt == nil { primedAt = uptime() }
        }
        timeline.armed = uptime() - startedAt
        progress("READY_ARMED: neutral ALAC player and exclusive signed32 output are running; sending GO once.")
        try child.command("GO"); timeline.goSent = uptime() - startedAt
        var completedAt: TimeInterval?, nextStatus: TimeInterval = 0
        while completedAt == nil || uptime() - completedAt! < 2 {
            if uptime() >= nextStatus { try child.command("STATUS"); nextStatus = uptime() + 0.2 }
            try advance(source: source)
            if let accepted = child.events.first(where: { $0.event == "goAccepted" }), timeline.goAccepted == nil {
                guard accepted.mode == "alac", accepted.duration == 5 else { throw AudioFailure("Unexpected reference playback acknowledgement.") }
                timeline.goAccepted = uptime() - startedAt
            }
            if let status = child.events.last(where: { $0.event == "status" }) {
                guard status.silencePlaying == true else { throw AudioFailure("The readiness silence player stopped unexpectedly.") }
                if status.completed == true {
                    guard status.completionSucceeded == true, status.started == true, status.playing == false,
                          status.mode == "alac", status.duration == 5 else {
                        throw AudioFailure("The reference did not complete successfully exactly once.")
                    }
                    if completedAt == nil {
                        completedAt = uptime(); completion = status
                        timeline.sourceCompletionObserved = uptime() - startedAt
                        progress("SOURCE_COMPLETE: preserving two seconds of silent postroll.")
                    }
                }
            }
            guard session.metrics.renderedCaptureFrames < captureCapacity else { throw AudioFailure("The bounded raw output capture filled.") }
        }
        guard child.events.filter({ $0.event == "goAccepted" }).count == 1 else { throw AudioFailure("Exactly one GO acknowledgement is required.") }
        let raw = session.finishRawCapture()
        timeline.captureStopped = uptime() - startedAt
        metrics = session.metrics; clockPitch = session.clockPitch; clockTargetFrames = session.clockTargetFrames
        try ensureDeadline()
        comparison = OutputByteVerification.compare(capture: raw, format: format, reference: reference)
    } catch { failure = error.localizedDescription }

    // Match finite-reference: release relay IO before stopping source or restoring any route.
    if session.running {
        metrics = session.finishMetrics(); timeline.captureStopped = uptime() - startedAt
        clockPitch = session.clockPitch; clockTargetFrames = session.clockTargetFrames
    }
    cleanupErrors += child.stop()
    session.stop(); cleanupErrors += session.cleanupErrors
    if session.cleanupErrors.isEmpty { cleanupErrors += route.restore() }
    else { cleanupErrors.append("Route restoration deferred until exclusive callback/configuration recovery succeeds.") }
    timeline.cleanupCompleted = uptime() - startedAt
    if timeline.cleanupCompleted! >= 25 { cleanupErrors.append("The run exceeded its 25-second overall bound.") }

    let m = metrics, sample = comparison?.sampleComparison
    let checks: [String: Bool] = [
        "neutralPlayerProperties": ready?.referencePlayer?.isNeutral(loops: 0) == true && ready?.silencePlayer?.isNeutral(loops: -1) == true,
        "sameReferenceHash": ready?.referenceSHA256 == reference.fileSHA256,
        "oneGOAcknowledged": child.events.filter { $0.event == "goAccepted" }.count == 1,
        "sourceDelegateCompletedSuccessfully": completion?.completed == true && completion?.completionSucceeded == true,
        "captureAndOutputCallbacksObserved": (m?.inputCallbacks ?? 0) > 0 && (m?.outputCallbacks ?? 0) > 0,
        "captureAndOutputTimestampsContinuous": m?.inputTimestampMissing == 0 && m?.outputTimestampMissing == 0
            && m?.inputTimestampDiscontinuities == 0 && m?.outputTimestampDiscontinuities == 0,
        "relayWithoutFaultOrSampleLoss": m?.started == true && m?.fault == 0 && m?.underflows == 0 && m?.overflows == 0
            && m?.invalidBuffers == 0 && m?.representationFailures == 0,
        "allDeliveredFramesCaptured": m != nil && m?.renderedCaptureFrames == m?.deliveredFrames,
        "fullReferenceRawBytesExact": comparison?.passed == true && comparison?.comparedFrames == 220500,
        "silentPrefixPresent": (sample?.leadingCaptureFrames ?? 0) >= 512,
        "atLeastOneSecondSilentSuffix": (sample?.trailingCaptureFrames ?? 0) >= 44100,
        "cleanupSucceeded": cleanupErrors.isEmpty,
        "measurementSucceeded": failure == nil
    ]
    func sanitize(_ value: String) -> String {
        var result = value.replacingOccurrences(of: referenceURL.path, with: "<reference>")
            .replacingOccurrences(of: receiptURL.path, with: "<receipt>")
            .replacingOccurrences(of: repository.path, with: "<repository>")
            .replacingOccurrences(of: NSHomeDirectory(), with: "<home>")
        for device in devices where !device.uid.isEmpty { result = result.replacingOccurrences(of: device.uid, with: "<device>") }
        return result
    }
    let receipt = Receipt(
        boundary: "Complete original ALAC fixture decoded by AVAudioPlayer through the actual exclusive DAC software signed32 output callback; USB receiver, DAC hardware and analog output remain unmeasured",
        sourceAPI: "AVAudioPlayer with rate processing disabled, volume 1, pan 0, rate 1, plus a separate same-format looping zero player",
        sourceCallbackTimestampEvidence: "Unavailable: AVAudioPlayer exposes delegate completion but this helper has no decoder or source-output callback timestamps. Source first-to-last equality is established independently from actual output bytes.",
        createdAt: ISO8601DateFormatter().string(from: Date()), systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
        referenceFile: referenceURL.lastPathComponent, referenceSHA256: reference.fileSHA256, sourceFormat: reference.sourceFormat,
        outputName: outputName, referenceFrames: reference.frameCount, referenceBits: reference.bits, sampleRate: reference.sampleRate,
        sourceSHA256: sourceHashes, binarySHA256: binaryHashes, linkedObjectSHA256: objectHashes,
        playerReady: ready?.sanitized, playerCompletion: completion?.sanitized, sourceCallbackTimestampsAvailable: false,
        timeline: timeline, inputFormat: inputFormat, outputFormat: outputFormat, physicalFormat: physicalFormat,
        clockPitch: clockPitch, clockTargetFrames: clockTargetFrames, metrics: metrics, comparison: comparison,
        checks: checks, cleanupErrors: cleanupErrors.map(sanitize), failure: failure.map(sanitize), passed: checks.values.allSatisfy { $0 })
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(receipt)
    try data.write(to: receiptURL, options: .withoutOverwriting)
    FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
    return receipt.passed
}

if CommandLine.arguments.dropFirst().contains("--help") { print(usage); exit(EXIT_SUCCESS) }
guard CommandLine.arguments.count == 1 else { progress(usage); exit(2) }
signal(SIGPIPE, SIG_IGN)
do { if try !main() { exit(EXIT_FAILURE) } }
catch { progress("inspect-av-exclusive: \(error.localizedDescription)"); exit(EXIT_FAILURE) }
