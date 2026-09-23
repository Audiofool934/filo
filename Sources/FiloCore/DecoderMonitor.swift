import Foundation

/// Streams only Music decoder-input diagnostics; no audio, titles, URLs, or log history are saved.
/// Start/stop and callbacks run on the caller's serial queue.
public final class DecoderMonitor {
    private var process: Process?
    private var pipe: Pipe?
    private var errors: Pipe?
    private var buffer = Data()
    private var generation: UInt64 = 0
    private let queue: DispatchQueue
    public var onFormat: ((SourceFormat) -> Void)?
    public var onError: ((String) -> Void)?
    public init(queue: DispatchQueue) { self.queue = queue }
    deinit { stop() }

    public func start() throws {
        stop()
        let process = Process(), pipe = Pipe(), errors = Pipe(), generation = generation
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["stream", "--style", "ndjson", "--level", "debug", "--predicate",
                             "process == 'Music' AND eventMessage CONTAINS 'ACAppleLosslessDecoder' AND eventMessage CONTAINS 'Input format:'"]
        process.standardOutput = pipe; process.standardError = errors
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { [weak self] in
                guard let self, self.generation == generation else { return }
                self.receive(data)
            }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { [weak self] in
                guard let self, self.generation == generation else { return }
                self.onError?("Music format detection is unavailable. Check permissions or choose a rate manually.")
            }
        }
        process.terminationHandler = { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self, self.generation == generation else { return }
                self.onError?("Music format detection stopped. Disconnect and reconnect filo.")
            }
        }
        self.process = process; self.pipe = pipe; self.errors = errors
        do { try process.run() } catch { stop(); throw error }
    }
    private func receive(_ data: Data) {
        buffer.append(data)
        if buffer.count > 262144 { buffer.removeAll(); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer[..<newline]
            if let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
               let message = event["eventMessage"] as? String,
               let format = DecoderFormatParser.parse(message) { onFormat?(format) }
            buffer.removeSubrange(...newline)
        }
    }
    public func stop() {
        generation &+= 1
        pipe?.fileHandleForReading.readabilityHandler = nil
        errors?.fileHandleForReading.readabilityHandler = nil
        if let process {
            process.terminationHandler = nil
            if process.isRunning { process.terminate(); process.waitUntilExit() }
        }
        try? pipe?.fileHandleForReading.close(); try? errors?.fileHandleForReading.close()
        process = nil; pipe = nil; errors = nil; buffer.removeAll()
    }
}
