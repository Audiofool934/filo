import CoreAudio
import Darwin
import FiloCore
import Foundation

// Temporary route-only experiment. This executable never creates an audio callback.
struct HoldContext: Codable {
    let sourceUID: String
    let originalUID: String
    let originalName: String
    let originalOutput: RecoveryOutputState
}

final class StopRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func request(_ reason: String) { lock.lock(); defer { lock.unlock() }; if value == nil { value = reason } }
    func read() -> String? { lock.lock(); defer { lock.unlock() }; return value }
}

func originalIsSafe(_ context: HoldContext) throws {
    let access = SystemExclusiveRecoveryAccess()
    guard let device = try HAL.outputDevices().first(where: { $0.uid == context.originalUID }),
          try HAL.value(device.id, kAudioDevicePropertyHogMode, default: Int32(-1)) == -1,
          try access.read(ExclusiveRecoveryResource(kind: .output, uid: context.originalUID)) == .output(context.originalOutput) else {
        throw AudioFailure("The original output is missing, still exclusive, or no longer has its original rate/physical/virtual format; outer route recovery is deferred.")
    }
}

final class GuardedAccess: DeviceAccess {
    let context: HoldContext
    let system = SystemDeviceAccess()
    init(_ context: HoldContext) { self.context = context }
    func devices() throws -> [OutputDevice] { try system.devices() }
    func defaultOutput() throws -> UInt32 { try system.defaultOutput() }
    func rate(_ id: UInt32) throws -> Double { try system.rate(id) }
    func setDefaultOutput(_ id: UInt32) throws {
        guard let target = try devices().first(where: { $0.id == id }) else { throw AudioFailure("Route target disappeared.") }
        if target.uid == context.originalUID { try originalIsSafe(context) }
        else if target.uid != context.sourceUID { throw AudioFailure("Refusing an unrelated route target.") }
        try system.setDefaultOutput(id)
    }
    func setRate(_ id: UInt32, _ rate: Double) throws {
        guard let target = try devices().first(where: { $0.id == id }), target.uid == context.sourceUID,
              abs(rate - 44100) < 0.01 else { throw AudioFailure("This helper only manages the selected BlackHole rate at 44100 Hz.") }
        try system.setRate(id, rate)
    }
}

func checkInnerRecovery() throws {
    var errors = ExclusiveRecoveryJournal.recoverOrphaned()
    if errors.isEmpty { errors += DeviceLease(journalURL: DeviceLease.defaultJournalURL).recoverOrphaned() }
    guard errors.isEmpty else { throw AudioFailure(errors.joined(separator: " ")) }
}

func emit(_ event: String, _ fields: [String: Any] = [:]) {
    var message = fields; message["event"] = event; message["pid"] = getpid()
    if let data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]),
       let line = String(data: data, encoding: .utf8) { print(line); fflush(stdout) }
}

@main struct HeldRoute {
    static func main() {
        do { exit(try run()) }
        catch { emit("error", ["message": error.localizedDescription]); exit(1) }
    }

    static func run() throws -> Int32 {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args == ["--recover-only"] || (args.count == 2 && args[0] == "--seconds") else {
            print("Usage: spotify-held-route --seconds 1...600 | --recover-only")
            return 1
        }
        let recovering = args == ["--recover-only"]
        let seconds = recovering ? 0 : Double(args[1]) ?? -1
        guard recovering || (seconds.isFinite && seconds >= 1 && seconds <= 600) else { throw AudioFailure("Duration must be 1...600 seconds.") }
        let work = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let journal = work.appendingPathComponent("spotify-held-route.json")
        let contextURL = work.appendingPathComponent("spotify-held-route-context.json")
        let lockURL = work.appendingPathComponent("spotify-held-route.lock")
        umask(0o077)
        let lock = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw AudioFailure("Could not open the outer route lock.") }
        defer { flock(lock, LOCK_UN); close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw AudioFailure("An outer route helper is already active.") }
        try checkInnerRecovery()
        if recovering {
            guard FileManager.default.fileExists(atPath: journal.path) || FileManager.default.fileExists(atPath: contextURL.path) else {
                emit("recovered", ["message": "No outer route record exists."]); return 0
            }
            let context = try JSONDecoder().decode(HoldContext.self, from: Data(contentsOf: contextURL))
            try originalIsSafe(context)
            let lease = DeviceLease(access: GuardedAccess(context), journalURL: journal)
            let errors = lease.recoverOrphaned()
            if errors.isEmpty {
                try FileManager.default.removeItem(at: contextURL)
                emit("recovered"); return 0
            }
            emit("recovery-deferred", ["errors": errors]); return 2
        }
        guard !FileManager.default.fileExists(atPath: journal.path), !FileManager.default.fileExists(atPath: contextURL.path) else {
            throw AudioFailure("An earlier outer route record exists; use --recover-only first.")
        }
        let devices = try HAL.outputDevices(), defaultID = try HAL.defaultOutput()
        let sources = devices.filter { $0.name == "BlackHole 2ch" }
        guard sources.count == 1, let source = sources.first, abs(source.rate - 44100) < 0.01,
              let original = devices.first(where: { $0.id == defaultID }), original.name == "WALKMAN",
              original.uid != source.uid else { throw AudioFailure("Expected WALKMAN default and a separate BlackHole 2ch already at 44100 Hz.") }
        guard case .output(let state)? = try SystemExclusiveRecoveryAccess().read(ExclusiveRecoveryResource(kind: .output, uid: original.uid)) else {
            throw AudioFailure("Could not read the original output format tuple.")
        }
        let context = HoldContext(sourceUID: source.uid, originalUID: original.uid, originalName: original.name, originalOutput: state)
        try originalIsSafe(context)
        try JSONEncoder().encode(context).write(to: contextURL, options: .withoutOverwriting)
        let lease = DeviceLease(access: GuardedAccess(context), journalURL: journal)
        var cleaned = false
        func cleanup() -> [String] {
            guard !cleaned else { return [] }; cleaned = true
            do {
                try checkInnerRecovery()
                try originalIsSafe(context)
                let errors = lease.restore()
                if errors.isEmpty { try FileManager.default.removeItem(at: contextURL) }
                return errors
            } catch { return [error.localizedDescription] }
        }
        defer { if !cleaned { let errors = cleanup(); emit("cleanup", ["errors": errors]) } }
        try lease.begin(output: source)
        try lease.apply(rate: 44100)
        guard try HAL.defaultOutput() == source.id, abs(try HAL.rate(source.id) - 44100) < 0.01 else {
            throw AudioFailure("BlackHole route/rate readback failed.")
        }
        let stop = StopRequest()
        signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        interrupt.setEventHandler { stop.request("SIGINT") }; terminate.setEventHandler { stop.request("SIGTERM") }
        interrupt.resume(); terminate.resume()
        defer { interrupt.cancel(); terminate.cancel() }
        DispatchQueue.global().async {
            while let line = readLine() { if line.trimmingCharacters(in: .whitespacesAndNewlines) == "quit" { stop.request("stdin quit"); return } }
            stop.request("stdin EOF")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        emit("ready", ["source": source.name, "rate": 44100, "originalDefault": original.name,
                       "originalRate": state.rate, "maximumSeconds": seconds, "journal": journal.lastPathComponent])
        while stop.read() == nil && ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        let errors = cleanup()
        emit(errors.isEmpty ? "restored" : "recovery-deferred", ["reason": stop.read() ?? "deadline", "errors": errors])
        return errors.isEmpty ? 0 : 2
    }
}
