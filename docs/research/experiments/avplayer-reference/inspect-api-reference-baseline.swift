import CoreAudio
import CryptoKit
import Darwin
import FiloCore
import FiloPCM
import Foundation

let work = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
let mode = CommandLine.arguments.count == 2 ? CommandLine.arguments[1] : ""
guard ["alac", "wav"].contains(mode) else {
    fputs("Usage: inspect-api-reference alac|wav; original generated fixture only.\n", stderr); exit(2)
}
let referenceURL = mode == "alac" ? work.appendingPathComponent("reference-server/filo-reference-44100-24.m4a")
    : work.appendingPathComponent("filo-reference-44100-24.wav")
let outputBase = work.appendingPathComponent("avplayer-\(mode)-tap")
let captureURL = outputBase.appendingPathExtension("f32"), reportURL = outputBase.appendingPathExtension("json")

final class Child {
    let process = Process(), input = Pipe(), output = Pipe()
    var pending = Data(), events: [[String: Any]] = []
    func start() throws {
        process.executableURL = work.appendingPathComponent("av-reference-player")
        process.arguments = ["--mode", mode]
        process.currentDirectoryURL = work.deletingLastPathComponent()
        process.standardInput = input; process.standardOutput = output
        try process.run()
        try input.fileHandleForReading.close(); try output.fileHandleForWriting.close()
        let fd = output.fileHandleForReading.fileDescriptor
        guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { throw AudioFailure("Nonblocking handshake failed.") }
    }
    func command(_ value: String) throws { try input.fileHandleForWriting.write(contentsOf: Data((value + "\n").utf8)) }
    func poll() throws {
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(output.fileHandleForReading.fileDescriptor, $0.baseAddress, $0.count) }
            if count > 0 { pending.append(contentsOf: bytes.prefix(count)) }
            else if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK { break }
            else if errno != EINTR { throw AudioFailure("Child handshake failed.") }
        }
        guard pending.count < 65536 else { throw AudioFailure("Oversized child handshake.") }
        while let index = pending.firstIndex(of: 10) {
            let line = Data(pending[..<index]); pending.removeSubrange(...index)
            guard let event = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw AudioFailure("Invalid child event.") }
            if let error = event["error"] as? String { throw AudioFailure(error) }
            events.append(event)
        }
    }
    func stop() -> [String] {
        guard process.processIdentifier > 0 else { return [] }
        var errors: [String] = []
        if process.isRunning { try? command("STOP") }
        let end = Date(timeIntervalSinceNow: 3)
        while process.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.terminate()
            let killAt = Date(timeIntervalSinceNow: 1)
            while process.isRunning && Date() < killAt { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            errors.append("The child needed forced cleanup.")
        }
        process.waitUntilExit()
        do { try poll() } catch { errors.append(error.localizedDescription) }
        if process.terminationStatus != 0 { errors.append("The child exited unsuccessfully.") }
        try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
        return errors
    }
}

struct Report: Encodable {
    let boundary, sourceAPI, mode, referenceSHA256: String
    let inputFormat: PCMFormat?
    let metrics: TransportMetrics
    let comparison: ReferencePCMComparison
    let firstNonzeroFrame: Int?, activeSpanFrames, nonFiniteSamples, off24BitGridSamples: Int
    let cleanupErrors: [String]
}

func main() throws {
    guard !FileManager.default.fileExists(atPath: captureURL.path), !FileManager.default.fileExists(atPath: reportURL.path) else {
        throw AudioFailure("Capture outputs already exist; preserve them before another run.")
    }
    let reference = try ReferencePCM.load(from: referenceURL)
    guard reference.sampleRate == 44100, reference.bits == 24, reference.frameCount == 220500 else { throw AudioFailure("Wrong fixture format.") }
    for index in reference.samples.indices {
        guard reference.samples[index] == filo_test_sample(UInt64(index / 2), UInt32(index % 2), 24) else { throw AudioFailure("Only the known synthetic fixture is allowed.") }
    }
    let child = Child(), capture = AudioSession(), lease = DeviceLease(journalURL: DeviceLease.defaultJournalURL)
    var restored = false
    defer {
        capture.stop()
        if !restored {
            let errors = child.stop() + lease.restore()
            if !errors.isEmpty { fputs(errors.joined(separator: " ") + "\n", stderr) }
        }
    }
    let exclusiveRecovery = ExclusiveRecoveryJournal.recoverOrphaned()
    guard exclusiveRecovery.isEmpty else { throw AudioFailure(exclusiveRecovery.joined(separator: " ")) }
    let routeRecovery = lease.recoverOrphaned()
    guard routeRecovery.isEmpty else { throw AudioFailure(routeRecovery.joined(separator: " ")) }
    guard let original = try HAL.outputDevices().first(where: ConnectionController.isExclusiveSourceDevice) else { throw AudioFailure("BlackHole is unavailable.") }
    try lease.begin(output: original); try lease.apply(rate: 44100)
    guard let source = try HAL.outputDevices().first(where: { $0.uid == original.uid }) else { throw AudioFailure("Source disappeared.") }
    try child.start()
    func advance() throws {
        _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        Thread.sleep(forTimeInterval: 0.02)
        try child.poll()
        guard child.process.isRunning else { throw AudioFailure("Child exited early.") }
        guard try HAL.defaultOutput() == source.id, try HAL.rate(source.id) == 44100 else { throw AudioFailure("Source routing changed.") }
    }
    var ids: [AudioObjectID] = []
    let deadline = Date(timeIntervalSinceNow: 8)
    while ids.isEmpty || !child.events.contains(where: { $0["event"] as? String == "ready" }) {
        guard Date() < deadline else { throw AudioFailure("Player did not become ready.") }
        try advance()
        ids = try HAL.processes().filter { $0.pid == child.process.processIdentifier }.map(\.id)
    }
    guard child.events.first(where: { $0["event"] as? String == "ready" })?["referenceSHA256"] as? String == reference.fileSHA256 else {
        throw AudioFailure("The child reference hash differs.")
    }
    try capture.startCapture(processIDs: ids, output: source, relay: false, captureFrames: 44100 * 15)
    let preroll = Date(timeIntervalSinceNow: 0.6)
    while Date() < preroll { try advance() }
    guard capture.metrics.callbacks > 0 else { throw AudioFailure("Capture did not prime.") }
    try child.command("GO")
    fputs("GO: capturing AVAudioPlayer \(mode) reference without a physical output.\n", stderr)
    let finishDeadline = Date(timeIntervalSinceNow: 10)
    var completedAt: Date?, nextStatus = Date.distantPast
    while completedAt == nil || Date().timeIntervalSince(completedAt!) < 2 {
        guard Date() < finishDeadline else { throw AudioFailure("Reference did not finish within its capture bound.") }
        if Date() >= nextStatus { try child.command("STATUS"); nextStatus = Date(timeIntervalSinceNow: 0.2) }
        try advance()
        if child.events.contains(where: { $0["completed"] as? Bool == true && $0["completionSucceeded"] as? Bool == true }) && completedAt == nil { completedAt = Date() }
        guard capture.metrics.invalidBuffers == 0 else { throw AudioFailure("Invalid capture layout.") }
    }
    let samples = capture.finishCapture(), metrics = capture.metrics, format = capture.inputFormat
    capture.stop()
    let errors = child.stop() + lease.restore(); restored = true
    var data = Data(capacity: samples.count * 4), nonfinite = 0, offGrid = 0
    var first: Int?, last: Int?
    for (index, sample) in samples.enumerated() {
        var word = sample.bitPattern.littleEndian
        withUnsafeBytes(of: &word) { data.append(contentsOf: $0) }
        if sample != 0 { if first == nil { first = index / 2 }; last = index / 2 }
        if !sample.isFinite { nonfinite += 1 }
        else if (Double(sample) * 8388608).rounded(.towardZero) != Double(sample) * 8388608 { offGrid += 1 }
    }
    let report = Report(boundary: "Own AVAudioPlayer process tap on BlackHole; Music and physical DAC not observed",
        sourceAPI: "AVAudioPlayer plus continuously running same-format zero player", mode: mode, referenceSHA256: reference.fileSHA256,
        inputFormat: format, metrics: metrics, comparison: ReferencePCM.compare(capture: samples, reference: reference),
        firstNonzeroFrame: first, activeSpanFrames: first.map { last! - $0 + 1 } ?? 0,
        nonFiniteSamples: nonfinite, off24BitGridSamples: offGrid, cleanupErrors: errors)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try data.write(to: captureURL, options: .withoutOverwriting)
    var reportObject = try JSONSerialization.jsonObject(with: encoder.encode(report)) as! [String: Any]
    reportObject["playerReady"] = child.events.first(where: { $0["event"] as? String == "ready" })?.filter { $0.key != "pid" }
    reportObject["playerCompletion"] = child.events.last(where: { $0["completed"] as? Bool == true && $0["completionSucceeded"] as? Bool == true })?.filter { $0.key != "pid" }
    reportObject["captureSHA256"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    reportObject["sourceSHA256"] = try Dictionary(uniqueKeysWithValues: ["inspect-api-reference.swift", "av-reference-player.swift"].map { name in
        (name, SHA256.hash(data: try Data(contentsOf: work.appendingPathComponent(name))).map { String(format: "%02x", $0) }.joined())
    })
    reportObject["createdAt"] = ISO8601DateFormatter().string(from: Date())
    reportObject["systemVersion"] = ProcessInfo.processInfo.operatingSystemVersionString
    let reportData = try JSONSerialization.data(withJSONObject: reportObject, options: [.prettyPrinted, .sortedKeys])
    try reportData.write(to: reportURL, options: .withoutOverwriting)
    FileHandle.standardOutput.write(reportData); print("")
    guard errors.isEmpty else { throw AudioFailure("Cleanup was incomplete.") }
}
signal(SIGPIPE, SIG_IGN)
do { try main() }
catch { fputs("inspect-api-reference: \(error.localizedDescription)\n", stderr); exit(1) }
