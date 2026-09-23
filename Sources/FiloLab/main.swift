import Foundation
import FiloCore
import FiloPCM

func json<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
    fflush(stdout)
}

let args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else { return nil }
    return args[index + 1]
}
func bitDepth() throws -> UInt32 {
    let raw = option("--bits") ?? "24"
    guard let value = UInt32(raw), [16, 24].contains(value) else { throw AudioFailure("Use --bits 16 or 24.") }
    return value
}
func duration(default fallback: Double, maximum: Double = 120) throws -> Double {
    guard let value = Double(option("--seconds") ?? String(fallback)), value.isFinite, value >= 1, value <= maximum else {
        throw AudioFailure("Duration must be 1...\(Int(maximum)) seconds.")
    }
    return value
}
let help = """
filo-lab devices
filo-lab recover
filo-lab processes
filo-lab rate --device NAME --hz RATE
filo-lab emit --device NAME [--bits 16|24] [--seconds 8]
filo-lab capture --device NAME --pid PID [--relay] [--seconds 5]
filo-lab verify --device NAME [--bits 16|24] [--relay] [--loopback] [--seconds 2]

--loopback reads a stereo Float32 virtual-device input and requires --relay.
filo-lab formats --device NAME
filo-lab clock --device 'BlackHole 2ch'
filo-lab exclusive-probe --device NAME [--hz RATE]
filo-lab fixture --file REFERENCE.wav --hz RATE [--bits 16|24] [--seconds 5]
filo-lab verify-exclusive --device NAME --source 'BlackHole 2ch' [--bits 16|24] [--seconds 5]
filo-lab verify-reference --device NAME --source 'BlackHole 2ch' --reference FILE [--player com.apple.Music] [--seconds 45]

The reference command captures in memory for comparison with a known local test file.
Use only a reference you own; never use it to record subscription audio.
--fixed-clock disables virtual-clock following for short diagnostic experiments.
The older --exclusive flag belongs to the unsupported same-device aggregate experiment.
Use BlackHole 2ch for silent synthetic tests. Other outputs may be audible.
"""
func selectedDevice() throws -> OutputDevice {
    let devices = try HAL.outputDevices()
    if let query = option("--device"), let device = devices.first(where: { $0.uid == query || $0.name == query || String($0.id) == query }) { return device }
    throw AudioFailure("Specify an available output with --device NAME or UID. Use devices to list outputs.")
}
func wait(_ seconds: Double) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}
do {
    let command = args.first ?? "help"
    let valueOptions = ["--device", "--source", "--hz", "--bits", "--seconds", "--pid", "--file", "--reference", "--player"]
    let flags = ["--relay", "--exclusive", "--loopback", "--fixed-clock"]
    var cursor = 1
    while cursor < args.count {
        let argument = args[cursor]
        if valueOptions.contains(argument) {
            guard args.indices.contains(cursor + 1), !args[cursor + 1].hasPrefix("--") else { throw AudioFailure("Missing value for \(argument).") }
            cursor += 2
        } else if flags.contains(argument) { cursor += 1 }
        else { throw AudioFailure("Unknown option: \(argument).") }
    }
    switch command {
    case "recover":
        var errors = ExclusiveRecoveryJournal.recoverOrphaned()
        if errors.isEmpty { errors += DeviceLease(journalURL: DeviceLease.defaultJournalURL).recoverOrphaned() }
        try json(["errors": errors])
        if !errors.isEmpty { throw AudioFailure("Some audio settings still need recovery.") }
    case "devices": try json(HAL.outputDevices())
    case "processes": try json(HAL.processes())
    case "formats": try json(DeviceInspection.outputStreams(selectedDevice()))
    case "clock": try json(VirtualClock.inspect(selectedDevice()))
    case "exclusive-probe":
        let recovery = ExclusiveRecoveryJournal.recoverOrphaned()
        guard recovery.isEmpty else { throw AudioFailure(recovery.joined(separator: " ")) }
        let output = try selectedDevice(), lease = ExclusiveDevice()
        defer { let errors = lease.restore(); if !errors.isEmpty { fputs(errors.joined(separator: " ") + "\n", stderr) } }
        try lease.acquire(output: output, rate: option("--hz").flatMap(Double.init) ?? output.rate)
        try json(["virtual": PCMFormat(lease.virtualFormat), "physical": PCMFormat(lease.physicalFormat)])
        try lease.validate()
    case "fixture":
        guard let path = option("--file"), let rate = option("--hz").flatMap(Double.init) else { throw AudioFailure("Specify --file and --hz for a quiet reference WAV.") }
        let reference = try ReferencePCM.generateFixture(at: URL(fileURLWithPath: path), sampleRate: rate, bits: Int(try bitDepth()), duration: duration(default: 5))
        struct Fixture: Encodable { let rate: Double; let bits: Int; let frames: Int; let sha256: String }
        try json(Fixture(rate: reference.sampleRate, bits: reference.bits, frames: reference.frameCount, sha256: reference.fileSHA256))
    case "verify-exclusive":
        let recovery = ExclusiveRecoveryJournal.recoverOrphaned()
        guard recovery.isEmpty else { throw AudioFailure(recovery.joined(separator: " ")) }
        let output = try selectedDevice(), session = ExclusiveRelaySession(), emitter = Process(), pipe = Pipe()
        let bits = try bitDepth(), seconds = try duration(default: 5)
        guard let sourceName = option("--source"), let source = try HAL.outputDevices().first(where: { $0.uid == sourceName || $0.name == sourceName }) else {
            throw AudioFailure("Specify a separate virtual --source, such as BlackHole 2ch.")
        }
        emitter.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        emitter.arguments = ["emit", "--device", source.uid, "--bits", String(bits), "--seconds", String(seconds + 10)]
        emitter.standardOutput = pipe
        defer {
            session.stop()
            if emitter.isRunning { emitter.terminate(); emitter.waitUntilExit() }
            try? pipe.fileHandleForReading.close()
            if !session.cleanupErrors.isEmpty { fputs(session.cleanupErrors.joined(separator: " ") + "\n", stderr) }
        }
        try emitter.run()
        var ids: [UInt32] = []
        for _ in 0..<40 {
            ids = try HAL.processes().filter { $0.pid == emitter.processIdentifier && $0.running }.map(\.id)
            if !ids.isEmpty { break }
            wait(0.05)
        }
        try session.start(processIDs: ids, source: source, output: output, sourceBits: bits,
                          captureFrames: UInt64(source.rate * (seconds + 1)), followClock: !args.contains("--fixed-clock"))
        let deadline = Date().addingTimeInterval(seconds)
        var failure: String?
        while Date() < deadline {
            wait(0.1)
            do { try session.tick() } catch { failure = error.localizedDescription; break }
        }
        let capture = session.finishCapture()
        let comparison = PCMVerification.compare(capture, bits: bits, maximumSourceFrames: Int(source.rate * (seconds + 12)))
        let metrics = session.metrics
        session.stop()
        let cleanupErrors = session.cleanupErrors
        struct ExclusiveResult: Encodable {
            let rate: Double; let bits: UInt32; let input: PCMFormat?; let output: PCMFormat?; let physical: PCMFormat?
            let metrics: ExclusiveRelayMetrics; let comparison: PCMComparison; let cleanupErrors: [String]
            let measurementBoundary: String; let clockPitch: Float; let clockTargetFrames: UInt64; let failure: String?; let passed: Bool
        }
        let passed = cleanupErrors.isEmpty && failure == nil && comparison.exact && comparison.comparedFrames >= Int(source.rate) && metrics.fault == 0
            && metrics.inputTimestampMissing == 0 && metrics.outputTimestampMissing == 0
        try json(ExclusiveResult(rate: source.rate, bits: bits, input: session.inputFormat, output: session.outputFormat, physical: session.physicalFormat,
                                 metrics: metrics, comparison: comparison, cleanupErrors: cleanupErrors,
                                 measurementBoundary: "Actual integer words in the exclusive physical device IOProc, decoded for reference comparison; USB receiver unmeasured",
                                 clockPitch: session.clockPitch, clockTargetFrames: session.clockTargetFrames, failure: failure, passed: passed))
        if !passed { throw AudioFailure("Exclusive integer relay verification failed.") }
    case "verify-reference":
        let recovery = ExclusiveRecoveryJournal.recoverOrphaned()
        guard recovery.isEmpty else { throw AudioFailure(recovery.joined(separator: " ")) }
        guard let path = option("--reference") else { throw AudioFailure("Specify a local lossless --reference file.") }
        let reference = try ReferencePCM.load(from: URL(fileURLWithPath: path))
        let output = try selectedDevice(), session = ExclusiveRelaySession(), route = DeviceLease(journalURL: DeviceLease.defaultJournalURL)
        let seconds = try duration(default: 45)
        guard let sourceName = option("--source"), let initialSource = try HAL.outputDevices().first(where: { $0.uid == sourceName || $0.name == sourceName }) else {
            throw AudioFailure("Specify a separate BlackHole --source.")
        }
        guard ConnectionController.isExclusiveSourceDevice(initialSource), initialSource.uid != output.uid else {
            throw AudioFailure("The reference source must be BlackHole 2ch, separate from the physical output.")
        }
        let bundleID = option("--player") ?? "com.apple.Music"
        guard ["com.apple.Music", "com.spotify.client"].contains(bundleID) else { throw AudioFailure("Unsupported reference player.") }
        func stopReferenceSession() -> [String] {
            session.stop()
            var errors = session.cleanupErrors
            // Keep the virtual route and its journal while callbacks or exclusive
            // settings are still owned. Recovery can retry after process exit.
            if errors.isEmpty { errors += route.restore() }
            return errors
        }
        defer {
            let errors = stopReferenceSession()
            if !errors.isEmpty { fputs(errors.joined(separator: " ") + "\n", stderr) }
        }
        try route.begin(output: initialSource)
        try route.apply(rate: reference.sampleRate)
        guard let source = try HAL.outputDevices().first(where: { $0.uid == initialSource.uid }) else { throw AudioFailure("The virtual source disconnected.") }
        var ids: [UInt32] = []
        fputs("Source route and rate prepared. Launch the reference player now if it is closed.\n", stderr)
        fflush(stderr)
        for _ in 0..<600 {
            ids = try HAL.processes().filter { $0.bundleID == bundleID }.map(\.id)
            if !ids.isEmpty { break }
            wait(0.05)
        }
        try session.start(processIDs: ids, source: source, output: output, sourceBits: reference.bits <= 16 ? 16 : 24,
                          captureFrames: UInt64(reference.sampleRate * (seconds + 1)), followClock: !args.contains("--fixed-clock"))
        fputs("Reference capture armed. Play the known reference from its beginning within this capture window.\n", stderr)
        fflush(stderr)
        let deadline = Date().addingTimeInterval(seconds)
        var failure: String?
        while Date() < deadline {
            wait(0.1)
            do {
                guard try HAL.defaultOutput() == source.id else { throw AudioFailure("The reference player's output route changed.") }
                try session.tick()
            } catch { failure = error.localizedDescription; break }
        }
        let capture = session.finishRawCapture()
        let comparison = OutputByteVerification.compare(capture: capture, format: session.outputASBD, reference: reference)
        let metrics = session.metrics
        let cleanupErrors = stopReferenceSession()
        struct ReferenceResult: Encodable {
            let referenceSHA256: String; let input: PCMFormat?; let output: PCMFormat?; let physical: PCMFormat?
            let metrics: ExclusiveRelayMetrics; let comparison: OutputByteComparison; let cleanupErrors: [String]
            let measurementBoundary: String; let clockPitch: Float; let clockTargetFrames: UInt64; let failure: String?; let passed: Bool
        }
        let passed = cleanupErrors.isEmpty && failure == nil && comparison.passed && metrics.fault == 0
            && metrics.inputTimestampMissing == 0 && metrics.outputTimestampMissing == 0
        try json(ReferenceResult(referenceSHA256: reference.fileSHA256, input: session.inputFormat, output: session.outputFormat,
                                 physical: session.physicalFormat, metrics: metrics, comparison: comparison, cleanupErrors: cleanupErrors,
                                 measurementBoundary: "Whole known lossless reference through the named player to actual physical-device IOProc bytes; USB receiver unmeasured",
                                 clockPitch: session.clockPitch, clockTargetFrames: session.clockTargetFrames, failure: failure, passed: passed))
        if !passed { throw AudioFailure("Whole-reference verification failed. See coverage and byte comparison.") }
    case "rate":
        let device = try selectedDevice()
        guard let rate = option("--hz").flatMap(Double.init) else { throw AudioFailure("Specify --hz.") }
        try HAL.setRate(device.id, to: rate)
        try json(["actualRate": HAL.rate(device.id)])
    case "emit":
        let device = try selectedDevice(), session = AudioSession()
        defer { session.stop() }
        let seconds = try duration(default: 8, maximum: 130)
        try session.startEmitter(device: device, bits: try bitDepth())
        try json(["pid": Int(getpid()), "rate": Int(device.rate)])
        wait(seconds)
        try json(session.metrics)
    case "capture":
        let device = try selectedDevice(), session = AudioSession()
        defer { session.stop() }
        guard let pid = option("--pid").flatMap(Int32.init), pid > 0 else { throw AudioFailure("Specify --pid.") }
        let seconds = try duration(default: 5)
        let ids = try HAL.processes().filter { $0.pid == pid }.map(\.id)
        try session.startCapture(processIDs: ids, output: device, relay: args.contains("--relay"), exclusive: args.contains("--exclusive"))
        try json(["input": session.inputFormat, "output": session.outputFormat])
        wait(seconds)
        try json(session.metrics)
    case "verify":
        let device = try selectedDevice(), session = AudioSession(), loopback = AudioSession(), emitter = Process()
        let bits = try bitDepth(), seconds = try duration(default: 2)
        guard !args.contains("--loopback") || args.contains("--relay") else { throw AudioFailure("Use --relay with --loopback to test the rendered output.") }
        let pipe = Pipe()
        emitter.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        emitter.arguments = ["emit", "--device", device.uid, "--bits", String(bits), "--seconds", String(seconds + 10)]
        emitter.standardOutput = pipe
        defer {
            loopback.stop()
            session.stop()
            if emitter.isRunning { emitter.terminate(); emitter.waitUntilExit() }
            try? pipe.fileHandleForReading.close()
        }
        try emitter.run()
        var ids: [UInt32] = []
        for _ in 0..<40 {
            ids = try HAL.processes().filter { $0.pid == emitter.processIdentifier && $0.running }.map(\.id)
            if !ids.isEmpty { break }
            wait(0.05)
        }
        try session.startCapture(processIDs: ids, output: device, relay: args.contains("--relay"),
                                 exclusive: args.contains("--exclusive"), captureFrames: UInt64(device.rate * (seconds + 1)))
        if args.contains("--loopback") {
            guard args.contains("--relay") else { throw AudioFailure("Use --relay with --loopback to test the rendered output.") }
            try loopback.startLoopback(device: device, captureFrames: UInt64(device.rate * (seconds + 1)))
        }
        wait(seconds)
        let measured = args.contains("--loopback") ? loopback.finishCapture() : session.finishCapture()
        if args.contains("--loopback") { _ = session.finishCapture() }
        let comparison = PCMVerification.compare(measured, bits: bits, maximumSourceFrames: Int(device.rate * (seconds + 12)))
        struct Result: Encodable {
            let rate: Double; let bits: UInt32; let input: PCMFormat?; let output: PCMFormat?
            let metrics: TransportMetrics; let loopbackMetrics: TransportMetrics?
            let measurementBoundary: String; let comparison: PCMComparison; let passed: Bool
        }
        let passed = comparison.exact && comparison.comparedFrames >= Int(device.rate) && session.metrics.invalidBuffers == 0 && loopback.metrics.invalidBuffers == 0
        try json(Result(rate: device.rate, bits: bits, input: session.inputFormat, output: session.outputFormat,
                        metrics: session.metrics, loopbackMetrics: args.contains("--loopback") ? loopback.metrics : nil,
                        measurementBoundary: args.contains("--loopback") ? "Rendered digital loopback input" : "Process tap input",
                        comparison: comparison, passed: passed))
        if !passed { throw AudioFailure("Synthetic PCM verification failed. See the measured comparison.") }
    case "help", "--help", "-h": print(help)
    default: throw AudioFailure("Unknown command: \(command). Run filo-lab help.")
    }
} catch {
    fputs("filo: \(error.localizedDescription)\n", stderr)
    exit(1)
}
