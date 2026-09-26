import Foundation
import CoreAudio

protocol PlaybackReading: AnyObject {
    var onState: ((PlayerState) -> Void)? { get set }
    func start(source: MusicSource, executable: URL) throws
    func request()
    func stop()
}
extension PlayerReader: PlaybackReading {}

protocol DecoderObserving: AnyObject {
    var onFormat: ((SourceFormat) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    func start() throws
    func stop()
}
extension DecoderMonitor: DecoderObserving {}

public enum ConnectionMode: String, CaseIterable, Identifiable, Codable {
    case format, relay, exclusive
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .format: return "Format matching"
        case .relay: return "Direct relay"
        case .exclusive: return "Exclusive preview"
        }
    }
}

/// Metadata arrival must not discard opening frames from an already armed fixed-rate path.
enum ExclusivePlaybackPolicy {
    static func hasExplicitRate(_ format: SourceFormat?) -> Bool {
        format?.evidence == .manual || format?.evidence == .spotifyPolicy
    }
    static func canArm(format: SourceFormat?, state: PlayerState, processesAvailable: Bool) -> Bool {
        guard format != nil, state.error == nil, processesAvailable else { return false }
        return hasExplicitRate(format) || (state.playing && state.trackID?.isEmpty == false)
    }
    static func requiresRearm(previous: PlayerState, current: PlayerState, format: SourceFormat?) -> Bool {
        if current.error != nil { return true }
        if hasExplicitRate(format) { return previous.playing && !current.playing }
        return previous.trackID != current.trackID || previous.playing != current.playing
    }
}

public struct ConnectionSnapshot {
    public var devices: [OutputDevice] = []
    public var connected = false
    public var busy = false
    public var title = "Ready when you are"
    public var detail = "Choose your music app and output, then connect."
    public var sourceFormat: SourceFormat?
    public var output: OutputDevice?
    public var virtualSource: OutputDevice?
    public var player = PlayerState()
    public var metrics: TransportMetrics?
    public var exclusiveMetrics: ExclusiveRelayMetrics?
    public var exclusiveOutputFormat: PCMFormat?
    public var exclusivePhysicalFormat: PCMFormat?
    public var clockPitch: Float?
    public var processingSummary: String?
    public var unverifiedControls: [String] = []
    public var segmentNote: String?
    public var tapFormat: PCMFormat?
    public var relayRunning = false
    public var needsAttention = false
    public var detectionError: String?
    public var unsupportedRate: Double?
    public var error: String?
    public init() {}
}

/// One serial queue owns all hardware changes and source events.
public final class ConnectionController {
    public let queue = DispatchQueue(label: "filo.connection", qos: .userInitiated)
    private let access: DeviceAccess
    private let lease: DeviceLease
    private let processList: () throws -> [AudioProcess]
    private let recoverExclusive: () -> [String]
    private let audio = AudioSession()
    private let exclusive = ExclusiveRelaySession()
    private var monitor: DecoderObserving!
    private var reader: PlaybackReading!
    private var timer: DispatchSourceTimer?
    private var clockTimer: DispatchSourceTimer?
    private var source: MusicSource = .appleMusic
    private var mode: ConnectionMode = .format
    private var selectedUID: String?
    private var manualRate: Double?
    private var policy = FormatPolicy()
    private var snapshot = ConnectionSnapshot()
    private var lastProcesses: [UInt32] = []
    private var relayStarted = Date.distantPast
    private var lastCallbackCount: UInt64 = 0
    private var lastCallbackProgress = Date.distantPast
    private var lastRate: Double?
    private var lastClockPublish: TimeInterval = 0
    public var onSnapshot: ((ConnectionSnapshot) -> Void)?

    public static func isExclusiveSourceDevice(_ device: OutputDevice) -> Bool {
        device.uid.hasPrefix("BlackHole") && device.name == "BlackHole 2ch"
        && device.formats.count == 1 && device.formats[0].channels == 2
    }

    public convenience init() {
        self.init(access: SystemDeviceAccess(), journalURL: DeviceLease.defaultJournalURL,
                  monitorFactory: { DecoderMonitor(queue: $0) }, readerFactory: { PlayerReader(queue: $0) },
                  processList: HAL.processes, recoverExclusive: { ExclusiveRecoveryJournal.recoverOrphaned() },
                  automaticallyPoll: true)
    }
    /// Dependency injection keeps controller transition tests away from the user's audio devices and players.
    init(access: DeviceAccess, journalURL: URL? = nil,
         monitorFactory: (DispatchQueue) -> DecoderObserving,
         readerFactory: (DispatchQueue) -> PlaybackReading,
         processList: @escaping () throws -> [AudioProcess] = { [] },
         recoverExclusive: @escaping () -> [String] = { [] }, automaticallyPoll: Bool = false) {
        self.access = access
        self.lease = DeviceLease(access: access, journalURL: journalURL)
        self.processList = processList
        self.recoverExclusive = recoverExclusive
        monitor = monitorFactory(queue)
        reader = readerFactory(queue)
        monitor.onFormat = { [weak self] format in self?.received(format) }
        monitor.onError = { [weak self] error in
            guard let self, self.snapshot.connected else { return }
            self.snapshot.detectionError = error
            self.policy.reset()
            if self.snapshot.sourceFormat?.evidence == .decoder {
                self.snapshot.sourceFormat = nil
                if self.mode == .exclusive {
                    do { try self.stopSegment("Source-format detection stopped. Reconnect to resume automatic detection.") }
                    catch { self.fail(error.localizedDescription); return }
                }
            }
            self.updateStatus(); self.publish()
        }
        reader.onState = { [weak self] state in self?.received(state) }
        if automaticallyPoll {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(150))
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer
            let clockTimer = DispatchSource.makeTimerSource(queue: queue)
            clockTimer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(10))
            clockTimer.setEventHandler { [weak self] in self?.clockTick() }
            self.clockTimer = clockTimer
            timer.resume(); clockTimer.resume()
        }
        queue.async { [weak self] in
            guard let self else { return }
            self.recoverOrphaned()
            self.publish()
        }
    }
    private func publish() {
        let value = snapshot
        DispatchQueue.main.async { [weak self] in self?.onSnapshot?(value) }
    }
    private func recoverOrphaned() {
        // A route must not return to a DAC whose non-mixable format is still leased.
        var errors = recoverExclusive()
        if errors.isEmpty { errors += lease.recoverOrphaned() }
        snapshot.error = errors.isEmpty ? nil : errors.joined(separator: " ")
        if !errors.isEmpty { snapshot.title = "Recovery needed" }
    }
    public func connect(source: MusicSource, outputUID: String, mode: ConnectionMode, manualRate: Double?, executable: URL) {
        queue.async {
            self.stopConnection()
            if self.snapshot.error != nil { self.snapshot.title = "Recovery needed"; self.publish(); return }
            self.recoverOrphaned()
            if self.snapshot.error != nil { self.publish(); return }
            self.source = source; self.selectedUID = outputUID; self.mode = mode; self.manualRate = manualRate
            self.snapshot.busy = true; self.snapshot.error = nil; self.snapshot.title = "Connecting"; self.publish()
            do {
                let devices = try self.access.devices()
                guard let output = devices.first(where: { $0.uid == outputUID }) else { throw AudioFailure("Connect your output device and try again.") }
                guard output.formats.count == 1, output.formats[0].channels == 2 else {
                    throw AudioFailure("filo currently supports outputs with one stereo stream.")
                }
                let route: OutputDevice
                if mode == .exclusive {
                    guard let virtual = devices.first(where: Self.isExclusiveSourceDevice) else {
                        throw AudioFailure("Exclusive preview needs BlackHole 2ch installed. Choose Format matching or install BlackHole, then reconnect.")
                    }
                    guard virtual.uid != output.uid else { throw AudioFailure("Choose your physical DAC as the output. BlackHole is the separate source route.") }
                    route = virtual
                    self.snapshot.virtualSource = virtual
                    self.snapshot.segmentNote = "A new relay segment begins when the source is ready. Capture of the first source sample and the DAC input remain unverified."
                } else { route = output }
                // Exclusive mode leases the virtual source route. The session separately owns the DAC.
                try self.lease.begin(output: route)
                self.snapshot.connected = true; self.snapshot.output = output
                self.policy.reset(); self.lastRate = route.rate
                if source == .appleMusic && manualRate == nil {
                    do { try self.monitor.start() }
                    catch { self.snapshot.detectionError = error.localizedDescription }
                }
                try self.reader.start(source: source, executable: executable)
                if let manualRate { try self.apply(SourceFormat(rate: manualRate, evidence: .manual)) }
                else if source == .spotify { try self.apply(SourceFormat(rate: 44100, evidence: .spotifyPolicy)) }
                self.snapshot.busy = false
                self.snapshot.title = "Waiting for music"; self.snapshot.detail = "Play a track in \(source.name)."
                self.poll()
            } catch { self.fail(error.localizedDescription) }
        }
    }
    public func disconnect() { queue.async { self.stopConnection(); self.poll(requestPlayback: false) } }
    public func sourceDidChange() { queue.async { if self.snapshot.connected { self.reader.request() } } }
    public func sleep() { queue.async { self.stopConnection(); self.snapshot.detail = "Disconnected for sleep. Reconnect when you are ready."; self.publish() } }
    public func shutdown() {
        queue.sync { timer?.cancel(); timer = nil; clockTimer?.cancel(); clockTimer = nil; stopConnection() }
    }
    private func stopAudio() -> [String] {
        // Release the physical output and virtual clock before restoring the route/rate lease.
        exclusive.stop(); audio.stop()
        snapshot.relayRunning = false; lastProcesses = []
        snapshot.tapFormat = nil; snapshot.exclusiveOutputFormat = nil; snapshot.exclusivePhysicalFormat = nil
        snapshot.clockPitch = nil
        return exclusive.cleanupErrors
    }
    private func stopSegment(_ reason: String) throws {
        // Freeze both callbacks before deciding whether an intentional rearm is safe.
        // A fault immediately before metadata arrival must not disappear with the old bridge.
        let finalMetrics = exclusive.running ? exclusive.finishMetrics() : snapshot.exclusiveMetrics
        let errors = stopAudio()
        snapshot.metrics = nil; snapshot.exclusiveMetrics = finalMetrics
        snapshot.segmentNote = reason
        guard errors.isEmpty else { throw AudioFailure(errors.joined(separator: " ")) }
        if let fault = finalMetrics?.fault, fault != 0 {
            throw AudioFailure(ExclusiveRelaySession.failureDescription(fault))
        }
        snapshot.exclusiveMetrics = nil
    }
    private func stopConnection() {
        var restorationErrors = stopAudio()
        monitor.stop(); reader.stop()
        if restorationErrors.isEmpty { restorationErrors += lease.restore() }
        snapshot.connected = false; snapshot.busy = false
        snapshot.sourceFormat = nil; snapshot.metrics = nil; snapshot.exclusiveMetrics = nil
        snapshot.virtualSource = nil; snapshot.player = PlayerState()
        snapshot.processingSummary = nil; snapshot.unverifiedControls = []; snapshot.segmentNote = nil
        snapshot.detectionError = nil; snapshot.needsAttention = false; snapshot.unsupportedRate = nil
        snapshot.title = "Ready when you are"; snapshot.detail = "Choose your music app and output, then connect."
        snapshot.error = restorationErrors.isEmpty ? nil : restorationErrors.joined(separator: " ")
        if !restorationErrors.isEmpty { snapshot.title = "Recovery needed" }
        policy.reset(); lastRate = nil; lastCallbackCount = 0
    }
    private func fail(_ message: String) {
        let lastExclusiveMetrics = exclusive.running ? exclusive.metrics : snapshot.exclusiveMetrics
        let processingSummary = snapshot.processingSummary, segmentNote = snapshot.segmentNote
        let unverifiedControls = snapshot.unverifiedControls
        stopConnection()
        let restoration = snapshot.error
        snapshot.error = message + (restoration.map { " Restoration: \($0)" } ?? "")
        snapshot.title = "Connection stopped"; snapshot.detail = "Resolve the issue below, then reconnect."
        snapshot.exclusiveMetrics = lastExclusiveMetrics
        snapshot.processingSummary = processingSummary; snapshot.unverifiedControls = unverifiedControls
        snapshot.segmentNote = segmentNote
        publish()
    }
    private func received(_ state: PlayerState) {
        guard snapshot.connected else { return }
        let previous = snapshot.player
        snapshot.player = state
        do {
            if mode == .exclusive {
                let assessment = SourceProcessingAssessment(state: state, source: source)
                snapshot.processingSummary = assessment.summary
                snapshot.unverifiedControls = assessment.unverifiedControls
                if exclusive.running, ExclusivePlaybackPolicy.requiresRearm(previous: previous, current: state, format: snapshot.sourceFormat) {
                    let note: String
                    if state.error != nil { note = "Playback information was lost. This segment ended without verified track continuity." }
                    else if !state.playing { note = "Playback paused. The relay was rearmed for a new segment; continuity across the pause is unverified." }
                    else { note = "A new playback segment started. Track boundaries and source processing are unverified." }
                    try stopSegment(note)
                }
                if let reason = assessment.blockingReason { fail(reason); return }
            }
            if let error = state.error {
                if source == .appleMusic, manualRate == nil {
                    policy.trackChanged(id: nil, playing: false); snapshot.sourceFormat = nil
                }
                snapshot.title = "Playback access needed"; snapshot.detail = error; publish(); return
            }
            policy.trackChanged(id: state.trackID, playing: state.playing, observedAt: state.primaryObservedAt)
            if source == .appleMusic, manualRate == nil {
                if let detected = policy.current, detected.evidence != .decoder || snapshot.detectionError == nil {
                    try apply(detected)
                }
                else { snapshot.sourceFormat = nil }
                if let rate = state.localRate, state.playing {
                    let format = SourceFormat(rate: rate, evidence: .localFile)
                    policy.useLocal(format); try apply(format)
                }
            }
            poll(requestPlayback: false)
        } catch { fail(error.localizedDescription) }
    }
    private func received(_ format: SourceFormat) {
        guard snapshot.connected, source == .appleMusic, manualRate == nil, snapshot.player.localRate == nil,
              snapshot.detectionError == nil else { return }
        guard let accepted = policy.observe(format) else {
            if policy.current == nil {
                snapshot.sourceFormat = nil
                if mode == .exclusive {
                    do { try stopSegment("Source-format evidence became ambiguous. No track boundary is verified.") }
                    catch { fail(error.localizedDescription); return }
                }
            }
            updateStatus(); publish(); return
        }
        do { try apply(accepted); poll(requestPlayback: false) } catch { fail(error.localizedDescription) }
    }
    private func apply(_ format: SourceFormat) throws {
        guard snapshot.connected, let routeUID = lease.outputUID else { return }
        guard let route = try access.devices().first(where: { $0.uid == routeUID }) else { throw AudioFailure("The source route was disconnected.") }
        let changingRate = abs(route.rate - format.rate) > 0.01
        let changingDepth = snapshot.sourceFormat?.bits != format.bits
        if mode == .exclusive {
            guard snapshot.output?.supportedRates.contains(format.rate) == true, route.supportedRates.contains(format.rate) else {
                throw AudioFailure("The selected source rate is not supported by both BlackHole and your DAC.")
            }
            if let bits = format.bits, bits > 24 {
                throw AudioFailure("This source exceeds 24-bit precision. A Float32 process tap cannot verify all of its original sample values.")
            }
            if (changingRate || changingDepth), exclusive.running {
                try stopSegment("The source format changed. The relay was rearmed; the transition and opening samples are unverified.")
            }
        }
        if changingRate {
            snapshot.title = "Matching output"; snapshot.busy = true; publish()
            if mode != .exclusive { _ = stopAudio() }
        }
        // Even a no-op match must validate route/rate ownership before reporting success.
        do { try lease.apply(rate: format.rate) }
        catch let error as UnsupportedSampleRate where mode == .format {
            // Use the device's actual rate ranges, not the menu's conventional-rate shortlist.
            // Ordinary playback continues unchanged; a later supported track can resume matching.
            snapshot.sourceFormat = format; snapshot.unsupportedRate = error.rate; snapshot.busy = false
            return
        }
        lastRate = format.rate
        snapshot.unsupportedRate = nil
        snapshot.sourceFormat = format; snapshot.busy = false
    }
    private func refreshExclusiveSnapshot() {
        snapshot.exclusiveMetrics = exclusive.metrics
        snapshot.tapFormat = exclusive.inputFormat
        snapshot.exclusiveOutputFormat = exclusive.outputFormat
        snapshot.exclusivePhysicalFormat = exclusive.physicalFormat
        snapshot.clockPitch = exclusive.clockPitch
        snapshot.relayRunning = exclusive.running
    }
    private func clockTick() {
        guard snapshot.connected, mode == .exclusive, exclusive.running else { return }
        do {
            let assessment = SourceProcessingAssessment(state: snapshot.player, source: source)
            snapshot.processingSummary = assessment.summary
            snapshot.unverifiedControls = assessment.unverifiedControls
            if let reason = assessment.blockingReason { fail(reason); return }
            try exclusive.tick()
            refreshExclusiveSnapshot()
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastClockPublish >= 0.5 {
                lastClockPublish = now; updateStatus(); publish()
            }
        } catch { fail(error.localizedDescription) }
    }
    func poll(requestPlayback: Bool = true) {
        do {
            snapshot.devices = try access.devices()
            guard snapshot.connected else { publish(); return }
            guard let output = snapshot.devices.first(where: { $0.uid == selectedUID }) else {
                fail("The output was disconnected. Reconnect the device, then connect filo again."); return
            }
            snapshot.output = output
            guard let route = snapshot.devices.first(where: { $0.uid == lease.outputUID }) else {
                fail("The music source route was disconnected. Reconnect filo after the device returns."); return
            }
            if mode == .exclusive { snapshot.virtualSource = route }
            guard route.isDefault else { fail("The system output changed outside filo. Your new selection has been preserved."); return }
            if let lastRate, abs(route.rate - lastRate) > 0.01 {
                fail("The source route's rate changed outside filo. Your new rate has been preserved."); return
            }
            if requestPlayback { reader.request() }
            // Muting a tapped process can change its audible-output flag.
            let processes = mode == .format ? [] : try processList()
                .filter { $0.bundleID == source.bundleID && kill($0.pid, 0) == 0 }.map(\.id).sorted()
            if mode == .exclusive {
                let assessment = SourceProcessingAssessment(state: snapshot.player, source: source)
                snapshot.processingSummary = assessment.summary
                snapshot.unverifiedControls = assessment.unverifiedControls
                if let reason = assessment.blockingReason { fail(reason); return }
                let ready = ExclusivePlaybackPolicy.canArm(format: snapshot.sourceFormat, state: snapshot.player,
                                                           processesAvailable: !processes.isEmpty)
                if !ready {
                    if exclusive.running { try stopSegment("The source is not ready. This playback segment is unverified.") }
                } else if !exclusive.running || processes != lastProcesses {
                    if exclusive.running { try stopSegment("The source process changed. A new unverified playback segment starts here.") }
                    let depth = snapshot.sourceFormat?.bits
                    // 20-bit values are exactly representable on the 24-bit grid.
                    let bits: UInt32 = depth == 16 ? 16 : (depth == 20 || depth == 24 ? 24 : 0)
                    try exclusive.start(processIDs: processes, source: route, output: output, sourceBits: bits, captureFrames: 0)
                    lastProcesses = processes
                    refreshExclusiveSnapshot()
                } else { refreshExclusiveSnapshot() }
            } else if mode == .relay {
                if processes.isEmpty { _ = stopAudio() }
                else if !audio.running || processes != lastProcesses {
                    audio.stop()
                    try audio.startCapture(processIDs: processes, output: output, relay: true)
                    relayStarted = Date(); lastProcesses = processes
                    lastCallbackCount = 0; lastCallbackProgress = relayStarted
                    snapshot.relayRunning = true
                }
                if audio.running {
                    let metrics = audio.metrics; snapshot.metrics = metrics; snapshot.tapFormat = audio.inputFormat
                    if metrics.callbacks != lastCallbackCount { lastCallbackCount = metrics.callbacks; lastCallbackProgress = Date() }
                    if metrics.invalidBuffers > 0 { fail("The audio buffer layout changed. The relay stopped to avoid altering samples."); return }
                    if metrics.callbacks == 0 && Date().timeIntervalSince(relayStarted) > 3 {
                        fail("No audio callbacks arrived. Check System Audio Recording permission, then reconnect."); return
                    }
                    if Date().timeIntervalSince(lastCallbackProgress) > 3 {
                        fail("The audio device stopped delivering callbacks. The relay was released; reconnect to try again."); return
                    }
                }
            }
            updateStatus(); publish()
        } catch { if snapshot.connected { fail(error.localizedDescription) } else { snapshot.error = error.localizedDescription; publish() } }
    }
    private func updateStatus() {
        snapshot.needsAttention = snapshot.player.error != nil
        if let error = snapshot.player.error { snapshot.title = "Playback access needed"; snapshot.detail = error }
        else if mode == .exclusive, exclusive.running, !snapshot.player.playing,
                let format = snapshot.sourceFormat, ExclusivePlaybackPolicy.hasExplicitRate(format) {
            snapshot.title = "Armed at the selected rate"
            snapshot.detail = "Listening at \(format.rate / 1000) kHz. Play a track when ready; source identity and the DAC input remain unverified."
        }
        else if snapshot.sourceFormat == nil, let error = snapshot.detectionError {
            snapshot.needsAttention = true
            snapshot.title = "Automatic detection unavailable"; snapshot.detail = error
        }
        else if !snapshot.player.playing {
            snapshot.title = "Waiting for music"; snapshot.detail = "Play a track in \(source.name)."
        } else if snapshot.sourceFormat == nil {
            snapshot.needsAttention = true
            snapshot.title = snapshot.detectionError == nil ? "Source format unknown" : "Automatic detection unavailable"
            snapshot.detail = snapshot.detectionError ?? (mode == .exclusive
                ? "Automatic format evidence can arrive after playback starts. Choose a known track rate manually and connect before Play to arm early."
                : "The output rate is unchanged. Waiting for a fresh format observation; disconnect to select a known rate manually.")
        } else if mode == .exclusive {
            if snapshot.exclusiveMetrics?.started == true {
                snapshot.title = "Exclusive preview active"
                snapshot.detail = "Integer output is exclusive. Source processing and the DAC's received bytes remain unverified."
            } else {
                snapshot.title = "Waiting for source audio"
                snapshot.detail = "The exclusive path is preparing. Check recording permission if captured frames do not arrive."
            }
        } else if let format = snapshot.sourceFormat {
            if mode == .format, snapshot.unsupportedRate == format.rate, let output = snapshot.output {
                snapshot.needsAttention = true
                snapshot.title = "Source rate not supported"
                snapshot.detail = "Your output does not support \(format.rate / 1000) kHz. Playback continues at \(output.rate / 1000) kHz; automatic matching will resume with a supported track."
                return
            }
            snapshot.title = format.evidence == .spotifyPolicy ? "Spotify profile active" : (format.evidence == .manual ? "Your rate is set" : "Format matched")
            snapshot.detail = mode == .format
                ? (format.evidence == .spotifyPolicy ? "Output follows the fixed 44.1 kHz profile. This is not per-track format detection."
                   : format.evidence == .manual ? "Output follows your selected rate. Automatic format detection is off."
                   : "Output sample rate matches the observed source. Your player handles playback.")
                : "One music app. No gain, EQ, or resampling in filo."
        }
    }
}
