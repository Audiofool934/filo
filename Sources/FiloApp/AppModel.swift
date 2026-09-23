import AppKit
import SwiftUI
import FiloCore

final class AppModel: ObservableObject {
    let controller = ConnectionController()
    @Published var snapshot = ConnectionSnapshot()
    @Published var source: MusicSource = MusicSource(rawValue: UserDefaults.standard.string(forKey: "source") ?? "") ?? .appleMusic
    @Published var outputUID = UserDefaults.standard.string(forKey: "outputUID") ?? ""
    @Published var mode: ConnectionMode = .format
    @Published var rate: Double = 0
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
            guard let self else { return }
            self.snapshot = value
            if self.outputUID.isEmpty { self.outputUID = value.devices.first(where: \.isDefault)?.uid ?? value.devices.first?.uid ?? "" }
            self.onUpdate?()
        }
    }
    func toggleConnection() {
        if snapshot.connected { controller.disconnect(); return }
        guard connectionRequirement == nil, let executable = Bundle.main.executableURL else { return }
        UserDefaults.standard.set(source.rawValue, forKey: "source")
        UserDefaults.standard.set(outputUID, forKey: "outputUID")
        controller.connect(source: source, outputUID: outputUID, mode: mode, manualRate: rate == 0 ? nil : rate, executable: executable)
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
        Source rate: \(snapshot.sourceFormat?.rate.description ?? "Unknown") Hz
        Evidence: \(snapshot.sourceFormat?.evidence.rawValue ?? "None")
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
        }
        for name in ["com.apple.Music.playerInfo", "com.apple.iTunes.playerInfo", "com.spotify.client.PlaybackStateChanged"] {
            observers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in self?.model.controller.sourceDidChange() })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.model.controller.sleep() })
        showWindow()
    }
    @objc func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationWillTerminate(_ notification: Notification) {
        model.controller.shutdown()
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
