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
    @Published var page: PanelPage = .main
    @Published var panelVisible = false
    enum PanelPage { case main, details, settings, about }
    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "FiloReleaseLabel") as? String
        ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    }
    var selectedOutput: OutputDevice? { snapshot.devices.first { $0.uid == outputUID } }
    var displayedOutput: OutputDevice? { snapshot.connected ? snapshot.output : selectedOutput }
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
    func select(source: MusicSource) {
        guard self.source != source, !snapshot.busy else { return }
        self.source = source; rate = 0
        UserDefaults.standard.set(source.rawValue, forKey: "source")
        reconnectIfNeeded()
    }
    func select(outputUID: String) {
        guard self.outputUID != outputUID, !snapshot.busy else { return }
        self.outputUID = outputUID
        if rate != 0, !availableRates.contains(rate) { rate = 0 }
        UserDefaults.standard.set(outputUID, forKey: "outputUID")
        reconnectIfNeeded()
    }
    private func reconnectIfNeeded() {
        guard snapshot.connected, let executable = Bundle.main.executableURL else { return }
        connect(ConnectionIntent(source: source, outputUID: outputUID, mode: mode, rate: rate, executable: executable))
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
                    detail: "Respond to the macOS microphone prompt, then turn the connection on again to use BlackHole's virtual input.")
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
                    detail: "The permission request is still pending. Respond to the macOS prompt, then turn the connection on again.")
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
                            detail: "The connection options or available devices changed. Choose your output and turn the connection on again.")
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
                detail: "macOS could not confirm microphone permission for BlackHole. Check System Settings > Privacy & Security > Microphone, then turn the connection on again.")
        }
    }
    private func showPermissionUnavailable() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .restricted {
            permissionMessage(title: "Microphone access restricted",
                detail: "macOS restricts microphone access. Ask your administrator to allow filo to use BlackHole's virtual input, or choose Format matching.")
        } else {
            permissionMessage(title: "Microphone permission needed",
                detail: "Enable filo in System Settings > Privacy & Security > Microphone, then turn the connection on again to use BlackHole's virtual input.")
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
        Output physical format: \(describe(output?.formats.first))
        Observed source depth: \(snapshot.sourceFormat?.bits.map(String.init) ?? "Unknown") bits
        Output depth limited: \(snapshot.depthLimited)
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

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let model = AppModel()
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private var observers: [NSObjectProtocol] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let icon = NSImage(systemSymbolName: "link", accessibilityDescription: "filo")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        icon?.isTemplate = true
        item.button?.image = icon
        item.button?.imagePosition = .imageLeading
        item.button?.font = .menuBarFont(ofSize: 0)
        item.button?.toolTip = "filo · Automatic format matching"
        item.button?.setAccessibilityLabel("filo")
        item.button?.target = self; item.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentSize = NSSize(width: FiloView.width, height: FiloView.height)
        let content = NSHostingController(rootView: FiloView(model: model))
        content.sizingOptions = []
        popover.contentViewController = content
        model.onUpdate = { [weak self] in
            guard let self else { return }
            let rate = self.model.snapshot.output?.rate ?? 0
            let title = self.model.snapshot.connected && rate > 0 ? " \(rateLabel(rate))" : ""
            if self.item.button?.title != title { self.item.button?.title = title }
            self.item.button?.toolTip = "filo · \(self.model.snapshot.title)"
        }
        for name in ["com.apple.Music.playerInfo", "com.apple.iTunes.playerInfo", "com.spotify.client.PlaybackStateChanged"] {
            observers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in self?.model.controller.sourceDidChange() })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.model.sleep() })
        if !UserDefaults.standard.bool(forKey: "hasOpenedPanel") { showPopover() }
    }
    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil) } else { showPopover() }
    }
    private func showPopover() {
        guard let button = item.button else { return }
        guard !popover.isShown else {
            popover.contentViewController?.view.window?.makeKey()
            return
        }
        model.page = .main
        model.panelVisible = true
        model.controller.refreshDevices()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        UserDefaults.standard.set(true, forKey: "hasOpenedPanel")
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showPopover(); return true }
    func popoverDidClose(_ notification: Notification) { model.panelVisible = false }
    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
        popover.close()
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
