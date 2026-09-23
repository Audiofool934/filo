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
    var selectedOutput: OutputDevice? { snapshot.devices.first { $0.uid == outputUID } }
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
        guard let executable = Bundle.main.executableURL else { return }
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
        let text = """
        filo 1.0.0
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Source: \(source.name)
        Mode: \(mode.name)
        State: \(snapshot.title)
        Output: \(output?.name ?? "Unavailable")
        Output rate: \(output?.rate.description ?? "Unknown") Hz
        Source rate: \(snapshot.sourceFormat?.rate.description ?? "Unknown") Hz
        Evidence: \(snapshot.sourceFormat?.evidence.rawValue ?? "None")
        Relay callbacks: \(snapshot.metrics?.callbacks ?? 0)
        Invalid buffers: \(snapshot.metrics?.invalidBuffers ?? 0)
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
