import AppKit
import AVFoundation
import SwiftUI
import FiloCore

final class AppModel: ObservableObject {
    let controller = ConnectionController()
    @Published var snapshot = ConnectionSnapshot()
    @Published var source: MusicSource = MusicSource(rawValue: UserDefaults.standard.string(forKey: "source") ?? "") ?? .appleMusic
    @Published var outputUID = UserDefaults.standard.string(forKey: "outputUID") ?? ""
    @Published var mode: ConnectionMode = .format {
        didSet {
            if mode != oldValue { cancelPermissionPreflight(); publishSnapshot() }
        }
    }
    @Published var rate: Double = 0
    private struct ConnectionIntent: Equatable {
        let source: MusicSource
        let outputUID: String
        let mode: ConnectionMode
        let rate: Double
        let executable: URL
    }
    private struct PermissionPresentation {
        let title: String
        let detail: String
        let busy: Bool
        let error: String?
    }
    private var controllerSnapshot = ConnectionSnapshot()
    private var permissionPresentation: PermissionPresentation?
    private var permissionToken: UUID?
    private var permissionRequestInFlight = false
    private var permissionTimeout: DispatchWorkItem?
    private var terminating = false
    var onUpdate: (() -> Void)?
    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "FiloReleaseLabel") as? String
        ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    }
    var selectedOutput: OutputDevice? { snapshot.devices.first { $0.uid == outputUID } }
    var exclusiveSource: OutputDevice? { snapshot.devices.first(where: ConnectionController.isExclusiveSourceDevice) }
    var outputChoices: [OutputDevice] {
        snapshot.devices.filter { mode != .exclusive || !ConnectionController.isExclusiveSourceDevice($0) }
    }
    var availableRates: [Double] {
        let rates = selectedOutput?.supportedRates ?? []
        guard mode == .exclusive else { return rates }
        return rates.filter { exclusiveSource?.supportedRates.contains($0) == true }
    }
    var connectionRequirement: String? {
        guard mode == .exclusive else { return nil }
        guard let exclusiveSource else { return "Install BlackHole 2ch to use exclusive preview." }
        guard let selectedOutput else { return "Choose your physical DAC as the output." }
        guard selectedOutput.uid != exclusiveSource.uid else { return "Choose your physical DAC as the output." }
        guard !availableRates.isEmpty else { return "BlackHole and this output have no matching sample rates." }
        return nil
    }
    init() {
        controller.onSnapshot = { [weak self] value in
            guard let self, !self.terminating else { return }
            self.controllerSnapshot = value
            if value.error != nil || value.connected { self.cancelPermissionPreflight() }
            if self.outputUID.isEmpty { self.outputUID = value.devices.first(where: \.isDefault)?.uid ?? value.devices.first?.uid ?? "" }
            self.publishSnapshot()
        }
    }
    func toggleConnection() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !terminating else { return }
        if permissionToken != nil {
            cancelPermissionPreflight(); publishSnapshot(); return
        }
        if snapshot.connected { controller.disconnect(); return }
        guard !snapshot.busy, connectionRequirement == nil, let executable = Bundle.main.executableURL else { return }
        let intent = ConnectionIntent(source: source, outputUID: outputUID, mode: mode, rate: rate, executable: executable)
        if mode == .exclusive { preflightExclusivePermission(intent) }
        else { connect(intent) }
    }
    private func publishSnapshot() {
        var value = controllerSnapshot
        if let permissionPresentation {
            value.busy = permissionPresentation.busy
            value.title = permissionPresentation.title
            value.detail = permissionPresentation.detail
            value.error = permissionPresentation.error
        }
        snapshot = value
        onUpdate?()
    }
    private func permissionMessage(title: String, detail: String, waiting: Bool = false) {
        permissionPresentation = PermissionPresentation(title: title, detail: detail, busy: waiting, error: waiting ? nil : detail)
        publishSnapshot()
    }
    private func cancelPermissionPreflight() {
        permissionToken = nil
        permissionTimeout?.cancel(); permissionTimeout = nil
        permissionPresentation = nil
        // AVFoundation cannot dismiss a system prompt. Its eventual callback must not revive this intent.
    }
    private func connect(_ intent: ConnectionIntent) {
        cancelPermissionPreflight()
        UserDefaults.standard.set(intent.source.rawValue, forKey: "source")
        UserDefaults.standard.set(intent.outputUID, forKey: "outputUID")
        publishSnapshot()
        controller.connect(source: intent.source, outputUID: intent.outputUID, mode: intent.mode,
                           manualRate: intent.rate == 0 ? nil : intent.rate, executable: intent.executable)
    }
    private func preflightExclusivePermission(_ intent: ConnectionIntent) {
        // This entire gate runs on the main queue, before ConnectionController can change any route or lease the DAC.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            connect(intent)
        case .notDetermined:
            guard !permissionRequestInFlight else {
                permissionMessage(title: "Microphone permission pending",
                    detail: "Respond to the macOS microphone prompt, then click Connect again to use BlackHole's virtual input.")
                return
            }
            let token = UUID()
            permissionToken = token; permissionRequestInFlight = true
            permissionMessage(title: "Waiting for microphone permission",
                detail: "Allow filo in the macOS prompt to use BlackHole's virtual audio input. Connection will start after permission is granted.", waiting: true)
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.permissionToken == token, !self.terminating else { return }
                self.cancelPermissionPreflight()
                self.permissionMessage(title: "Connection not started",
                    detail: "The permission request is still pending. Respond to the macOS prompt, then click Connect again.")
            }
            permissionTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: timeout)
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.permissionRequestInFlight = false
                    guard !self.terminating, self.permissionToken == token else { return }
                    self.cancelPermissionPreflight()
                    guard self.source == intent.source, self.outputUID == intent.outputUID,
                          self.mode == intent.mode, self.rate == intent.rate, self.connectionRequirement == nil else {
                        self.permissionMessage(title: "Connection not started",
                            detail: "The connection options or available devices changed. Choose your output and click Connect again.")
                        return
                    }
                    if granted, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                        self.connect(intent)
                    } else {
                        self.showPermissionUnavailable()
                    }
                }
            }
        case .denied, .restricted:
            showPermissionUnavailable()
        @unknown default:
            permissionMessage(title: "Microphone permission unavailable",
                detail: "macOS could not confirm microphone permission for BlackHole. Check System Settings > Privacy & Security > Microphone, then click Connect again.")
        }
    }
    private func showPermissionUnavailable() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .restricted {
            permissionMessage(title: "Microphone access restricted",
                detail: "macOS restricts microphone access. Ask your administrator to allow filo to use BlackHole's virtual input, or choose Format matching.")
        } else {
            permissionMessage(title: "Microphone permission needed",
                detail: "Enable filo in System Settings > Privacy & Security > Microphone, then click Connect again to use BlackHole's virtual input.")
        }
    }
    func sleep() {
        cancelPermissionPreflight(); publishSnapshot()
        controller.sleep()
    }
    func shutdown() {
        terminating = true
        cancelPermissionPreflight()
        controller.shutdown()
    }
    func openSource() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
    func copyDiagnostics() {
        let output = selectedOutput
        let exclusiveMetrics = snapshot.exclusiveMetrics
        func describe(_ format: PCMFormat?) -> String {
            guard let format else { return "Not active" }
            return "\(format.rate) Hz, \(format.channels) channels, \(format.bits) bits, flags \(format.flags)"
        }
        let text = """
        filo \(appVersion)
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Source: \(source.name)
        Mode: \(mode.name)
        State: \(snapshot.title)
        Output: \(output?.name ?? "Unavailable")
        Output rate: \(output?.rate.description ?? "Unknown") Hz
        Selected target rate: \(snapshot.sourceFormat?.rate.description ?? "Unknown") Hz
        Evidence: \(snapshot.sourceFormat?.evidence.rawValue ?? "None")
        Automatic detection error: \(snapshot.detectionError ?? "None")
        Unsupported source rate: \(snapshot.unsupportedRate?.description ?? "None") Hz
        Capture rate: \(snapshot.tapFormat?.rate.description ?? "Not active") Hz
        Relay callbacks: \(snapshot.metrics?.callbacks ?? 0)
        Invalid buffers: \(snapshot.metrics?.invalidBuffers ?? 0)
        Virtual route: \(snapshot.virtualSource?.name ?? "Not active")
        Virtual route rate: \(snapshot.virtualSource?.rate.description ?? "Unknown") Hz
        Exclusive output callback format: \(describe(snapshot.exclusiveOutputFormat))
        Exclusive physical stream format: \(describe(snapshot.exclusivePhysicalFormat))
        Exclusive path running: \(snapshot.relayRunning && mode == .exclusive)
        Exclusive payload started: \(exclusiveMetrics?.started ?? false)
        Input/output callbacks: \(exclusiveMetrics?.inputCallbacks ?? 0) / \(exclusiveMetrics?.outputCallbacks ?? 0)
        Captured/delivered/queued frames: \(exclusiveMetrics?.capturedFrames ?? 0) / \(exclusiveMetrics?.deliveredFrames ?? 0) / \(exclusiveMetrics?.queuedFrames ?? 0)
        Startup silence/initial reserve frames: \(exclusiveMetrics?.startupSilenceFrames ?? 0) / \(exclusiveMetrics?.initialQueuedFrames ?? 0)
        Underflows/overflows: \(exclusiveMetrics?.underflows ?? 0) / \(exclusiveMetrics?.overflows ?? 0)
        Invalid buffers/representation failures: \(exclusiveMetrics?.invalidBuffers ?? 0) / \(exclusiveMetrics?.representationFailures ?? 0)
        Missing input/output timestamp evidence: \(exclusiveMetrics?.inputTimestampMissing ?? 0) / \(exclusiveMetrics?.outputTimestampMissing ?? 0)
        Input/output timestamp discontinuities: \(exclusiveMetrics?.inputTimestampDiscontinuities ?? 0) / \(exclusiveMetrics?.outputTimestampDiscontinuities ?? 0)
        Latched bridge fault: \(exclusiveMetrics?.fault ?? 0)
        Virtual clock pitch (0.5 = nominal): \(snapshot.clockPitch?.description ?? "Not active")
        Processing: \(snapshot.processingSummary ?? "Not assessed")
        Unverified controls: \(snapshot.unverifiedControls.joined(separator: ", "))
        Playback segment: \(snapshot.segmentNote ?? "Not assessed")
        Software boundary: process-tap PCM to final output callback, no production audio recording
        Player source identity and physical DAC input: not verified
        End-to-end bit-perfect: not verified
        """
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var item: NSStatusItem!
    private var window: NSWindow!
    private var observers: [NSObjectProtocol] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "ƒ"
        item.button?.font = .systemFont(ofSize: 18, weight: .medium)
        item.button?.toolTip = "filo - Your music. A direct connection."
        item.button?.target = self; item.button?.action = #selector(showWindow)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 650),
                          styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "filo"
        window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: FiloView(model: model))
        window.center()
        model.onUpdate = { [weak self] in
            guard let self else { return }
            let rate = self.model.snapshot.output?.rate ?? 0
            self.item.button?.title = self.model.snapshot.connected && rate > 0 ? "ƒ \(rateLabel(rate))" : "ƒ"
            self.item.button?.toolTip = "filo · \(self.model.snapshot.title)"
        }
        for name in ["com.apple.Music.playerInfo", "com.apple.iTunes.playerInfo", "com.spotify.client.PlaybackStateChanged"] {
            observers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in self?.model.controller.sourceDidChange() })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.model.sleep() })
        showWindow()
    }
    @objc func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
        for observer in observers {
            DistributedNotificationCenter.default().removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        NSStatusBar.system.removeStatusItem(item)
    }
}

func rateLabel(_ value: Double) -> String {
    value.truncatingRemainder(dividingBy: 1000) == 0 ? String(Int(value / 1000)) : String(format: "%.1f", value / 1000)
}
