import Foundation
import CoreAudio

public enum ConnectionMode: String, CaseIterable, Identifiable, Codable {
    case format, relay, exclusive
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .format: return "Format matching"
        case .relay: return "Direct relay"
        case .exclusive: return "Exclusive relay (experimental)"
        }
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
    public var player = PlayerState()
    public var metrics: TransportMetrics?
    public var relayRunning = false
    public var error: String?
    public init() {}
}

/// One serial queue owns all hardware changes and source events.
public final class ConnectionController {
    public let queue = DispatchQueue(label: "filo.connection", qos: .userInitiated)
    private let lease = DeviceLease()
    private let audio = AudioSession()
    private var monitor: DecoderMonitor!
    private var reader: PlayerReader!
    private var timer: DispatchSourceTimer?
    private var source: MusicSource = .appleMusic
    private var mode: ConnectionMode = .format
    private var selectedUID: String?
    private var manualRate: Double?
    private var policy = FormatPolicy()
    private var snapshot = ConnectionSnapshot()
    private var lastProcesses: [UInt32] = []
    private var relayStarted = Date.distantPast
    private var relayAttempts = 0
    private var lastRate: Double?
    public var onSnapshot: ((ConnectionSnapshot) -> Void)?

    public init() {
        monitor = DecoderMonitor(queue: queue)
        reader = PlayerReader(queue: queue)
        monitor.onFormat = { [weak self] format in self?.received(format) }
        monitor.onError = { [weak self] error in
            guard let self, self.snapshot.connected else { return }
            self.snapshot.detail = error; self.publish()
        }
        reader.onState = { [weak self] state in self?.received(state) }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(150))
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer; timer.resume()
    }
    private func publish() {
        let value = snapshot
        DispatchQueue.main.async { [weak self] in self?.onSnapshot?(value) }
    }
    public func connect(source: MusicSource, outputUID: String, mode: ConnectionMode, manualRate: Double?, executable: URL) {
        queue.async {
            self.stopConnection()
            self.source = source; self.selectedUID = outputUID; self.mode = mode; self.manualRate = manualRate
            self.snapshot.busy = true; self.snapshot.error = nil; self.snapshot.title = "Connecting"; self.publish()
            do {
                let devices = try HAL.outputDevices()
                guard let output = devices.first(where: { $0.uid == outputUID }) else { throw AudioFailure("Connect your output device and try again.") }
                guard output.formats.count == 1, output.formats[0].channels == 2 else {
                    throw AudioFailure("filo currently supports outputs with one stereo stream.")
                }
                try self.lease.begin(output: output)
                self.snapshot.connected = true
                self.snapshot.output = output
                self.policy.reset(); self.lastRate = output.rate; self.relayAttempts = 0
                if source == .appleMusic && manualRate == nil { try self.monitor.start() }
                try self.reader.start(source: source, executable: executable)
                if let manualRate {
                    try self.apply(SourceFormat(rate: manualRate, evidence: .manual))
                } else if source == .spotify {
                    try self.apply(SourceFormat(rate: 44100, evidence: .spotifyPolicy))
                }
                self.snapshot.busy = false
                self.snapshot.title = "Waiting for music"
                self.snapshot.detail = "Play a track in \(source.name)."
                self.poll()
            } catch { self.fail(error.localizedDescription) }
        }
    }
    public func disconnect() { queue.async { self.stopConnection(); self.publish() } }
    public func sourceDidChange() { queue.async { if self.snapshot.connected { self.reader.request() } } }
    public func sleep() { queue.async { self.stopConnection(); self.snapshot.detail = "Disconnected for sleep. Reconnect when you are ready."; self.publish() } }
    public func shutdown() {
        queue.sync { timer?.cancel(); timer = nil; stopConnection() }
    }
    private func stopConnection() {
        monitor.stop(); reader.stop(); audio.stop()
        let restorationErrors = lease.restore()
        snapshot.connected = false; snapshot.busy = false; snapshot.relayRunning = false
        snapshot.sourceFormat = nil; snapshot.metrics = nil; snapshot.player = PlayerState()
        snapshot.title = "Ready when you are"; snapshot.detail = "Choose your music app and output, then connect."
        snapshot.error = restorationErrors.isEmpty ? nil : restorationErrors.joined(separator: " ")
        policy.reset(); lastProcesses = []; lastRate = nil; relayAttempts = 0
    }
    private func fail(_ message: String) {
        stopConnection(); snapshot.error = message; snapshot.title = "Connection stopped"
        snapshot.detail = "Resolve the issue below, then reconnect."; publish()
    }
    private func received(_ state: PlayerState) {
        guard snapshot.connected else { return }
        snapshot.player = state
        if let error = state.error { snapshot.detail = error; publish(); return }
        policy.trackChanged(id: state.trackID, playing: state.playing)
        if source == .appleMusic, manualRate == nil {
            snapshot.sourceFormat = policy.current
            if let rate = state.localRate, state.playing {
                let format = SourceFormat(rate: rate, evidence: .localFile)
                policy.useLocal(format)
                do { try apply(format) } catch { fail(error.localizedDescription); return }
            }
        }
        poll(requestPlayback: false)
    }
    private func received(_ format: SourceFormat) {
        guard snapshot.connected, source == .appleMusic, manualRate == nil, snapshot.player.localRate == nil else { return }
        guard let accepted = policy.observe(format) else {
            if policy.current == nil { snapshot.sourceFormat = nil }
            publish(); return
        }
        do { try apply(accepted); poll(requestPlayback: false) } catch { fail(error.localizedDescription) }
    }
    private func apply(_ format: SourceFormat) throws {
        guard snapshot.connected else { return }
        if let output = snapshot.output, abs(try HAL.rate(output.id) - format.rate) > 0.01 {
            snapshot.title = "Matching output"; snapshot.busy = true; publish()
            audio.stop(); snapshot.relayRunning = false; lastProcesses = []; relayAttempts = 0
            try lease.apply(rate: format.rate)
            lastRate = format.rate
        }
        snapshot.sourceFormat = format; snapshot.busy = false
    }
    private func poll(requestPlayback: Bool = true) {
        do {
            snapshot.devices = try HAL.outputDevices()
            guard snapshot.connected else { publish(); return }
            guard let output = snapshot.devices.first(where: { $0.uid == selectedUID }) else {
                fail("The output was disconnected. Reconnect the device, then connect filo again."); return
            }
            snapshot.output = output
            guard output.isDefault else { fail("The system output changed outside filo. Your new selection has been preserved."); return }
            if let lastRate, abs(output.rate - lastRate) > 0.01 {
                fail("The output rate changed outside filo. Your new rate has been preserved."); return
            }
            if requestPlayback { reader.request() }
            let processes = try HAL.processes().filter { $0.bundleID == source.bundleID && $0.running }.map(\.id).sorted()
            if mode != .format {
                if processes.isEmpty {
                    audio.stop(); snapshot.relayRunning = false; lastProcesses = []; relayAttempts = 0
                } else if !audio.running || processes != lastProcesses {
                    audio.stop()
                    try audio.startCapture(processIDs: processes, output: output, relay: true, exclusive: mode == .exclusive)
                    relayStarted = Date(); lastProcesses = processes; relayAttempts += 1
                    snapshot.relayRunning = true
                }
                if audio.running {
                    let metrics = audio.metrics; snapshot.metrics = metrics
                    if metrics.invalidBuffers > 0 { fail("The audio buffer layout changed. The relay stopped to avoid altering samples."); return }
                    if metrics.callbacks == 0 && Date().timeIntervalSince(relayStarted) > 3 {
                        fail(mode == .exclusive ? "This output did not deliver audio in exclusive mode. Use Format matching or Direct relay." : "No audio callbacks arrived. Check System Audio Recording permission, then reconnect."); return
                    }
                }
            }
            if let error = snapshot.player.error { snapshot.title = "Playback access needed"; snapshot.detail = error }
            else if !snapshot.player.playing {
                snapshot.title = "Waiting for music"; snapshot.detail = "Play a track in \(source.name)."
            } else if let format = snapshot.sourceFormat {
                snapshot.title = format.evidence == .spotifyPolicy ? "Spotify profile active" : (format.evidence == .manual ? "Your rate is set" : "Format matched")
                snapshot.detail = mode == .format ? "Music plays through the selected output." : "One music app. No gain, EQ, or resampling in filo."
            } else {
                snapshot.title = "Source format unknown"
                snapshot.detail = "Waiting for a fresh Music decoder format. Try the next track, or choose a rate manually."
            }
            publish()
        } catch { if snapshot.connected { fail(error.localizedDescription) } else { snapshot.error = error.localizedDescription; publish() } }
    }
}
