import AppKit
import AVFAudio

public struct PlayerState: Codable {
    public var playing: Bool
    public var trackID: String?
    public var title: String?
    public var volume: Int?
    public var localRate: Double?
    public var error: String?
    public init(playing: Bool = false, trackID: String? = nil, title: String? = nil,
                volume: Int? = nil, localRate: Double? = nil, error: String? = nil) {
        self.playing = playing; self.trackID = trackID; self.title = title
        self.volume = volume; self.localRate = localRate; self.error = error
    }
}

/// Entry point for a persistent helper running NSAppleScript on its own main thread.
/// The GUI remains responsive even while macOS asks for Automation permission.
public enum PlayerHelper {
    public static func run(source: MusicSource) {
        precondition(Thread.isMainThread)
        let music = """
        with timeout of 2 seconds
            tell application id "com.apple.Music"
                if not running then return {"stopped", "", "", 0, 0, ""}
                set s to player state as text
                if s is "stopped" then return {s, "", "", 0, sound volume, ""}
                set t to current track
                set trackIdentifier to ""
                try
                    set trackIdentifier to persistent ID of t
                on error
                    set trackIdentifier to (name of t) & "|" & (artist of t)
                end try
                if trackIdentifier is "" or trackIdentifier is "0000000000000000" then
                    set trackIdentifier to (name of t) & "|" & (artist of t) & "|" & (album of t)
                end if
                return {s, trackIdentifier, name of t, 0, sound volume, ""}
            end tell
        end timeout
        """
        let spotify = """
        with timeout of 2 seconds
            tell application id "com.spotify.client"
                if not running then return {"stopped", "", "", 0, 0, ""}
                set s to player state as text
                if s is "stopped" then return {s, "", "", 0, sound volume, ""}
                return {s, id of current track, name of current track, 0, sound volume, ""}
            end tell
        end timeout
        """
        let script = NSAppleScript(source: source == .appleMusic ? music : spotify)
        let fileScript = NSAppleScript(source: """
        with timeout of 2 seconds
            tell application id "com.apple.Music"
                try
                    set t to current track
                    set trackIdentifier to ""
                    try
                        set trackIdentifier to persistent ID of t
                    on error
                        set trackIdentifier to (name of t) & "|" & (artist of t)
                    end try
                    if trackIdentifier is "" or trackIdentifier is "0000000000000000" then
                        set trackIdentifier to (name of t) & "|" & (artist of t) & "|" & (album of t)
                    end if
                    return {trackIdentifier, POSIX path of (location of t)}
                on error
                    return {"", ""}
                end try
            end tell
        end timeout
        """)
        var inspectedTrack: String?
        var cachedLocalRate: Double?
        while readLine() != nil {
            var state: PlayerState = autoreleasepool {
                guard !NSRunningApplication.runningApplications(withBundleIdentifier: source.bundleID).isEmpty else { return PlayerState() }
                var error: NSDictionary?
                guard let descriptor = script?.executeAndReturnError(&error), error == nil else {
                    let code = error?[NSAppleScript.errorNumber] as? Int
                    return PlayerState(error: code == -1743 ? "Allow filo to read \(source.name) in System Settings > Privacy & Security > Automation." : "\(source.name) did not provide playback information (\(code ?? 0)). Try playing a track.")
                }
                let playing = descriptor.atIndex(1)?.stringValue == "playing"
                let id = descriptor.atIndex(2)?.stringValue ?? ""
                let title = descriptor.atIndex(3)?.stringValue
                return PlayerState(playing: playing, trackID: id.isEmpty ? nil : id, title: title,
                                   volume: Int(descriptor.atIndex(5)?.int32Value ?? 0))
            }
            if state.trackID == inspectedTrack { state.localRate = cachedLocalRate }
            if let data = try? JSONEncoder().encode(state) {
                FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
            }
            // A cloud track's file-location lookup can time out in Music.
            // Never put it on the critical playback-state path or repeat it every poll.
            if source == .appleMusic, let track = state.trackID, track != inspectedTrack {
                inspectedTrack = track; cachedLocalRate = nil
                var error: NSDictionary?
                if let descriptor = fileScript?.executeAndReturnError(&error), error == nil,
                   descriptor.atIndex(1)?.stringValue == track,
                   let path = descriptor.atIndex(2)?.stringValue, !path.isEmpty,
                   let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) {
                    cachedLocalRate = file.fileFormat.sampleRate
                }
            }
        }
    }
}

public final class PlayerReader {
    private let queue: DispatchQueue
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var buffer = Data()
    private var pending = false
    private var generation: UInt64 = 0
    public var onState: ((PlayerState) -> Void)?
    public init(queue: DispatchQueue) { self.queue = queue }
    deinit { stop() }
    public func start(source: MusicSource, executable: URL) throws {
        stop()
        let process = Process(), input = Pipe(), output = Pipe(), generation = generation
        process.executableURL = executable
        process.arguments = ["--player-helper", source.rawValue]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { [weak self] in
                guard let self, self.generation == generation else { return }
                self.buffer.append(data)
                if self.buffer.count > 65536 { self.buffer.removeAll(); self.pending = false; return }
                while let newline = self.buffer.firstIndex(of: 10) {
                    let line = Data(self.buffer[..<newline])
                    self.buffer.removeSubrange(...newline)
                    self.pending = false
                    if let state = try? JSONDecoder().decode(PlayerState.self, from: line) { self.onState?(state) }
                }
            }
        }
        process.terminationHandler = { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self, self.generation == generation else { return }
                self.onState?(PlayerState(error: "Playback reader stopped. Reconnect filo."))
            }
        }
        self.process = process; self.input = input; self.output = output
        do { try process.run() } catch { stop(); throw error }
        request()
    }
    public func request() {
        guard process?.isRunning == true, !pending else { return }
        pending = true
        do { try input?.fileHandleForWriting.write(contentsOf: Data([10])) }
        catch { pending = false; onState?(PlayerState(error: "Playback reader is unavailable.")) }
    }
    public func stop() {
        generation &+= 1
        output?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        if let process {
            process.terminationHandler = nil
            if process.isRunning { process.terminate(); process.waitUntilExit() }
        }
        try? output?.fileHandleForReading.close()
        process = nil; input = nil; output = nil; buffer.removeAll(); pending = false
    }
}
