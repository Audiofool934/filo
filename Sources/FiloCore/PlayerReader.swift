import AppKit
import AVFAudio
import Darwin

/// Observations of the controls exposed by a player's scripting dictionary.
/// Nil means unreadable or unsupported, never an inferred safe setting.
public struct SourceProcessingState: Codable, Equatable {
    public var volume: Int?
    public var muted: Bool?
    public var equalizerEnabled: Bool?
    public var observedAt: Date?
    public var trackID: String?
    public var trackVolumeAdjustment: Int?
    public var trackEqualizerPreset: String?
    public var trackObservedAt: Date?

    public init(volume: Int? = nil, muted: Bool? = nil, equalizerEnabled: Bool? = nil,
                observedAt: Date? = nil, trackID: String? = nil,
                trackVolumeAdjustment: Int? = nil, trackEqualizerPreset: String? = nil,
                trackObservedAt: Date? = nil) {
        self.volume = volume; self.muted = muted; self.equalizerEnabled = equalizerEnabled
        self.observedAt = observedAt; self.trackID = trackID
        self.trackVolumeAdjustment = trackVolumeAdjustment; self.trackEqualizerPreset = trackEqualizerPreset
        self.trackObservedAt = trackObservedAt
    }

    /// Cached track controls must never be attributed to the next track.
    func matching(trackID: String?) -> SourceProcessingState {
        var result = self
        if trackID == nil || self.trackID != trackID {
            result.trackID = nil; result.trackVolumeAdjustment = nil
            result.trackEqualizerPreset = nil; result.trackObservedAt = nil
        }
        return result
    }

    static func integer(_ value: String?, in range: ClosedRange<Int>) -> Int? {
        guard let value, let number = Int(value), range.contains(number) else { return nil }
        return number
    }

    static func boolean(_ value: String?) -> Bool? {
        switch value {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }
}

public struct PlayerState: Codable {
    public var playing: Bool
    public var trackID: String?
    public var title: String?
    public var volume: Int?
    /// Start of the successful essential observation, never refreshed by optional reads.
    public var primaryObservedAt: Date?
    public var localRate: Double?
    public var processing: SourceProcessingState?
    public var error: String?
    public init(playing: Bool = false, trackID: String? = nil, title: String? = nil,
                volume: Int? = nil, localRate: Double? = nil,
                processing: SourceProcessingState? = nil, error: String? = nil,
                primaryObservedAt: Date? = nil) {
        self.playing = playing; self.trackID = trackID; self.title = title
        self.volume = volume; self.localRate = localRate; self.processing = processing; self.error = error
        self.primaryObservedAt = primaryObservedAt
    }

    func mergingSupplemental(_ supplemental: PlayerState?) -> PlayerState {
        guard error == nil else { return self }
        var result = self
        result.processing = supplemental?.processing?.matching(trackID: trackID)
        result.processing?.volume = volume
        if let trackID, supplemental?.trackID == trackID {
            result.localRate = supplemental?.localRate
        }
        return result
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
                if not running then return {"stopped", "", "", 0, "", ""}
                set s to player state as text
                set v to ""
                try
                    set v to sound volume as text
                end try
                if s is "stopped" then return {s, "", "", 0, v, ""}
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
                return {s, trackIdentifier, name of t, 0, v, ""}
            end tell
        end timeout
        """
        let spotify = """
        with timeout of 2 seconds
            tell application id "com.spotify.client"
                if not running then return {"stopped", "", "", 0, "", ""}
                set s to player state as text
                set v to ""
                try
                    set v to sound volume as text
                end try
                if s is "stopped" then return {s, "", "", 0, v, ""}
                return {s, id of current track, name of current track, 0, v, ""}
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
        // A separately scheduled helper handles these optional, potentially slow reads.
        // The dictionary does not expose Spotify mute or either app's full DSP chain.
        let processingScript = source == .appleMusic ? NSAppleScript(source: """
        with timeout of 1 second
            tell application id "com.apple.Music"
                if not running then return {"", ""}
                try
                    set controls to get {mute, EQ enabled}
                    return {(item 1 of controls) as text, (item 2 of controls) as text}
                on error
                    return {"", ""}
                end try
            end tell
        end timeout
        """) : nil
        let trackProcessingScript = source == .appleMusic ? NSAppleScript(source: """
        with timeout of 1 second
            tell application id "com.apple.Music"
                if not running then return {"", "", missing value}
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
                    set adjustment to ""
                    set preset to missing value
                    try
                        set adjustment to volume adjustment of t as text
                    end try
                    try
                        set preset to EQ of t
                    end try
                    return {trackIdentifier, adjustment, preset}
                on error
                    return {"", "", missing value}
                end try
            end tell
        end timeout
        """) : nil
        var inspectedTrack: String?
        var cachedLocalRate: Double?
        var processing = SourceProcessingState()
        var trackControlsReadAt = Date.distantPast
        while let request = readLine() {
            var state: PlayerState = autoreleasepool {
                let observationStartedAt = Date()
                guard !NSRunningApplication.runningApplications(withBundleIdentifier: source.bundleID).isEmpty else {
                    return PlayerState(primaryObservedAt: observationStartedAt)
                }
                var error: NSDictionary?
                guard let descriptor = script?.executeAndReturnError(&error), error == nil else {
                    let code = error?[NSAppleScript.errorNumber] as? Int
                    return PlayerState(error: code == -1743 ? "Allow filo to read \(source.name) in System Settings > Privacy & Security > Automation." : "\(source.name) did not provide playback information (\(code ?? 0)). Try playing a track.")
                }
                let playing = descriptor.atIndex(1)?.stringValue == "playing"
                let id = descriptor.atIndex(2)?.stringValue ?? ""
                let title = descriptor.atIndex(3)?.stringValue
                return PlayerState(playing: playing, trackID: id.isEmpty ? nil : id, title: title,
                                   volume: SourceProcessingState.integer(descriptor.atIndex(5)?.stringValue, in: 0...100),
                                   primaryObservedAt: observationStartedAt)
            }
            guard request == "processing" else {
                if source == .spotify, state.error == nil {
                    state.processing = SourceProcessingState(volume: state.volume, observedAt: Date())
                }
                send(state)
                continue
            }
            guard state.error == nil,
                  !NSRunningApplication.runningApplications(withBundleIdentifier: source.bundleID).isEmpty else {
                processing = SourceProcessingState()
                inspectedTrack = nil; cachedLocalRate = nil
                send(state)
                continue
            }
            if source == .appleMusic {
                processing.muted = nil; processing.equalizerEnabled = nil; processing.observedAt = nil
                var error: NSDictionary?
                if let descriptor = processingScript?.executeAndReturnError(&error), error == nil {
                    processing.muted = SourceProcessingState.boolean(descriptor.atIndex(1)?.stringValue)
                    processing.equalizerEnabled = SourceProcessingState.boolean(descriptor.atIndex(2)?.stringValue)
                    if processing.muted != nil || processing.equalizerEnabled != nil { processing.observedAt = Date() }
                }
            }
            // Retry optional track controls at a bounded cadence so a user edit
            // does not remain hidden for an entire track. Failed reads stay unknown.
            let changedTrack = state.trackID != inspectedTrack
            if source == .appleMusic, let track = state.trackID,
               changedTrack || Date().timeIntervalSince(trackControlsReadAt) >= 5 {
                trackControlsReadAt = Date()
                processing.trackID = nil; processing.trackVolumeAdjustment = nil
                processing.trackEqualizerPreset = nil; processing.trackObservedAt = nil
                var processingError: NSDictionary?
                if let descriptor = trackProcessingScript?.executeAndReturnError(&processingError), processingError == nil,
                   descriptor.atIndex(1)?.stringValue == track {
                    processing.trackID = track
                    processing.trackVolumeAdjustment = SourceProcessingState.integer(descriptor.atIndex(2)?.stringValue, in: -100...100)
                    // AppleScript missing value is a type descriptor, not an empty
                    // text preset. Preserve that distinction when an item is unreadable.
                    if let preset = descriptor.atIndex(3), preset.descriptorType == typeUnicodeText || preset.descriptorType == typeUTF8Text || preset.descriptorType == typeChar {
                        processing.trackEqualizerPreset = preset.stringValue
                    }
                    processing.trackObservedAt = Date()
                }
            }
            // File-location requests can time out for cloud tracks. This separate
            // helper tries once per track and cannot hold up essential state reads.
            if source == .appleMusic, let track = state.trackID, changedTrack {
                inspectedTrack = track; cachedLocalRate = nil
                var error: NSDictionary?
                if let descriptor = fileScript?.executeAndReturnError(&error), error == nil,
                   descriptor.atIndex(1)?.stringValue == track,
                   let path = descriptor.atIndex(2)?.stringValue, !path.isEmpty,
                   let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) {
                    cachedLocalRate = file.fileFormat.sampleRate
                }
            }
            if state.trackID == inspectedTrack { state.localRate = cachedLocalRate }
            state.processing = processing.matching(trackID: state.trackID)
            state.processing?.volume = state.volume
            send(state)
        }
    }
    private static func send(_ state: PlayerState) {
        if let data = try? JSONEncoder().encode(state) {
            FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
        }
    }

}

public final class PlayerReader {
    private let queue: DispatchQueue
    private let supplemental: Bool
    private let responseTimeout: TimeInterval
    private var supplementalReader: PlayerReader?
    private var latestState: PlayerState?
    private var latestSupplemental: PlayerState?
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var buffer = Data()
    private var pending = false
    private var requestSequence: UInt64 = 0
    private var responseDeadline: DispatchWorkItem?
    private var generation: UInt64 = 0
    public var onState: ((PlayerState) -> Void)?
    public convenience init(queue: DispatchQueue) { self.init(queue: queue, supplemental: false, responseTimeout: 3) }
    /// An internal deadline override keeps fake-helper tests short without operating a player.
    convenience init(queue: DispatchQueue, responseTimeout: TimeInterval) {
        self.init(queue: queue, supplemental: false, responseTimeout: responseTimeout)
    }
    private init(queue: DispatchQueue, supplemental: Bool, responseTimeout: TimeInterval) {
        precondition(responseTimeout.isFinite && responseTimeout > 0)
        self.queue = queue; self.supplemental = supplemental; self.responseTimeout = responseTimeout
    }
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
                if self.buffer.count > 65536 {
                    self.fail("Playback reader returned too much data. Reconnect filo.")
                    return
                }
                while let newline = self.buffer.firstIndex(of: 10) {
                    let line = Data(self.buffer[..<newline])
                    self.buffer.removeSubrange(...newline)
                    guard self.pending else { continue }
                    guard let state = try? JSONDecoder().decode(PlayerState.self, from: line) else {
                        self.fail("Playback reader returned invalid information. Reconnect filo.")
                        return
                    }
                    self.finishRequest()
                    self.latestState = state
                    self.publish()
                }
            }
        }
        process.terminationHandler = { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self, self.generation == generation else { return }
                self.fail("Playback reader stopped. Reconnect filo.")
            }
        }
        self.process = process; self.input = input; self.output = output
        do { try process.run() } catch { stop(); throw error }
        if !supplemental, source == .appleMusic {
            let reader = PlayerReader(queue: queue, supplemental: true, responseTimeout: 10)
            reader.onState = { [weak self] state in
                guard let self, self.generation == generation else { return }
                self.latestSupplemental = state.error == nil ? state : nil
                self.publish()
            }
            // Optional evidence must not prevent the main metadata reader starting.
            do {
                try reader.start(source: source, executable: executable)
                supplementalReader = reader
            } catch { reader.stop() }
        }
        request()
    }
    private func publish() {
        guard let latestState else { return }
        onState?(supplementalReader == nil ? latestState : latestState.mergingSupplemental(latestSupplemental))
    }
    public func request() {
        supplementalReader?.request()
        guard process?.isRunning == true, !pending else { return }
        pending = true
        requestSequence &+= 1
        let generation = generation, sequence = requestSequence
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, self.generation == generation,
                  self.pending, self.requestSequence == sequence else { return }
            self.fail("Playback reader timed out. Reconnect filo.")
        }
        responseDeadline = deadline
        queue.asyncAfter(deadline: .now() + responseTimeout, execute: deadline)
        guard let input else { fail("Playback reader is unavailable."); return }
        do { try input.fileHandleForWriting.write(contentsOf: supplemental ? Data("processing\n".utf8) : Data([10])) }
        catch {
            fail("Playback reader is unavailable.")
        }
    }
    private func finishRequest() {
        pending = false
        responseDeadline?.cancel(); responseDeadline = nil
    }
    private func fail(_ message: String) {
        // A failed primary reader also stops optional publishing, so old playback
        // or track identity cannot be resurrected by an optional reply.
        stop()
        latestState = PlayerState(error: message)
        publish()
    }
    public func stop() {
        generation &+= 1
        finishRequest()
        supplementalReader?.stop(); supplementalReader = nil
        latestState = nil; latestSupplemental = nil
        output?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        if let process {
            process.terminationHandler = nil
            if process.isRunning {
                process.terminate()
                // A helper stuck inside an Apple event must not block this queue forever.
                let forceExit = DispatchWorkItem {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25, execute: forceExit)
                process.waitUntilExit()
                forceExit.cancel()
            }
        }
        try? output?.fileHandleForReading.close()
        process = nil; input = nil; output = nil; buffer.removeAll(); pending = false
    }
}
