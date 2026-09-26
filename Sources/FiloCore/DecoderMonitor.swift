import Foundation

/// Reads the event's wall-clock timestamp instead of making delayed pipe delivery look fresh.
/// The log process also emits non-event records; malformed or undated records are ignored.
enum DecoderEventParser {
    private static let fractionalTimestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let wholeTimestamp = ISO8601DateFormatter()

    static func parse(_ data: Data) -> SourceFormat? {
        guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = event["eventMessage"] as? String,
              let timestamp = event["timestamp"] as? String else { return nil }
        // log stream uses a space separator and compact offset, e.g.
        // 2026-09-26 15:19:51.641979+0800. ISO8601 also accepts Z and colon offsets.
        let normalized = timestamp.replacingOccurrences(of: " ", with: "T")
        guard let date = fractionalTimestamp.date(from: normalized) ?? wholeTimestamp.date(from: normalized) else { return nil }
        return DecoderFormatParser.parse(message, at: date)
    }
}

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
            if let format = DecoderEventParser.parse(Data(line)) { onFormat?(format) }
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
