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
filo-lab processes
filo-lab rate --device NAME --hz RATE
filo-lab emit --device NAME [--bits 16|24] [--seconds 8]
filo-lab capture --device NAME --pid PID [--relay] [--seconds 5]
filo-lab verify --device NAME [--bits 16|24] [--relay] [--loopback] [--seconds 2]

--loopback reads a stereo Float32 virtual-device input and requires --relay.
--exclusive is an unsupported relay experiment; tested devices produce no callbacks.
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
    let valueOptions = ["--device", "--hz", "--bits", "--seconds", "--pid"]
    let flags = ["--relay", "--exclusive", "--loopback"]
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
    case "devices": try json(HAL.outputDevices())
    case "processes": try json(HAL.processes())
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
