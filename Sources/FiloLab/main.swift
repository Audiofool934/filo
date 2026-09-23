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
func selectedDevice() throws -> OutputDevice {
    let devices = try HAL.outputDevices()
    if let query = option("--device"), let device = devices.first(where: { $0.uid == query || $0.name == query || String($0.id) == query }) { return device }
    throw AudioFailure("Specify an available output with --device NAME or UID. Use devices to list outputs.")
}
func wait(_ seconds: Double) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}
do {
    switch args.first ?? "help" {
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
        try session.startEmitter(device: device, bits: UInt32(option("--bits") ?? "24") ?? 24)
        try json(["pid": Int(getpid()), "rate": Int(device.rate)])
        wait(Double(option("--seconds") ?? "8") ?? 8)
        try json(session.metrics)
    case "capture":
        let device = try selectedDevice(), session = AudioSession()
        defer { session.stop() }
        guard let pid = option("--pid").flatMap(Int32.init) else { throw AudioFailure("Specify --pid.") }
        let ids = try HAL.processes().filter { $0.pid == pid }.map(\.id)
        try session.startCapture(processIDs: ids, output: device, relay: args.contains("--relay"), exclusive: args.contains("--exclusive"))
        try json(["input": session.inputFormat, "output": session.outputFormat])
        wait(Double(option("--seconds") ?? "5") ?? 5)
        try json(session.metrics)
    case "verify":
        let device = try selectedDevice(), session = AudioSession(), emitter = Process()
        let bits = UInt32(option("--bits") ?? "24") ?? 24
        let seconds = Double(option("--seconds") ?? "2") ?? 2
        guard seconds >= 1, seconds <= 120 else { throw AudioFailure("Verification duration must be 1...120 seconds.") }
        let pipe = Pipe()
        emitter.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        emitter.arguments = ["emit", "--device", device.uid, "--bits", String(bits), "--seconds", String(seconds + 10)]
        emitter.standardOutput = pipe
        defer {
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
        wait(seconds)
        let capture = session.finishCapture()
        let comparison = PCMVerification.compare(capture, bits: bits, maximumSourceFrames: Int(device.rate * (seconds + 12)))
        struct Result: Encodable {
            let rate: Double; let bits: UInt32; let input: PCMFormat?; let output: PCMFormat?
            let metrics: TransportMetrics; let comparison: PCMComparison; let passed: Bool
        }
        let passed = comparison.exact && comparison.comparedFrames >= Int(device.rate) && session.metrics.invalidBuffers == 0
        try json(Result(rate: device.rate, bits: bits, input: session.inputFormat, output: session.outputFormat,
                        metrics: session.metrics, comparison: comparison, passed: passed))
        if !passed { throw AudioFailure("Synthetic PCM verification failed. See the measured comparison.") }
    default:
        print("filo-lab devices | processes | rate --device NAME --hz RATE | emit --device NAME [--bits 16|24] [--seconds 8] | capture --device NAME --pid PID [--relay] [--exclusive] [--seconds 5] | verify --device NAME [--bits 16|24] [--relay] [--exclusive]")
    }
} catch {
    fputs("filo: \(error.localizedDescription)\n", stderr)
    exit(1)
}
