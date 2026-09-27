import SwiftUI
import AppKit
import CoreAudio
import ImageIO
import FiloCore

private let accent = Color(red: 0.12, green: 0.48, blue: 0.46)

/// Changes of source, artwork or page never resize the menu bar card.
struct FiloView: View {
    static let width: CGFloat = 340
    static let height: CGFloat = 300
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var state: ConnectionSnapshot { model.snapshot }
    private var format: SourceFormat? { state.connected ? state.sourceFormat : nil }
    private var shownRate: Double? { format?.rate ?? model.displayedOutput?.rate }

    var body: some View {
        ZStack {
            PanelMaterial()
            if model.page == .main, model.panelVisible, let artwork = SceneArtwork.image(rate: shownRate) {
                Image(nsImage: artwork).resizable().scaledToFill()
                    .frame(width: Self.width, height: Self.height).clipped()
                    .mask(LinearGradient(stops: [
                        .init(color: .black.opacity(0.12), location: 0),
                        .init(color: .black.opacity(0.7), location: 0.20),
                        .init(color: .black, location: 0.40),
                        .init(color: .black, location: 1)
                    ], startPoint: .top, endPoint: .bottom))
                    .opacity(reduceTransparency ? 0.35 : 0.82)
                    .overlay(Color.black.opacity(colorScheme == .dark ? 0.48 : 0))
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            Group {
                switch model.page {
                case .main: main
                case .details: details
                case .settings: settings
                case .about: about
                }
            }.padding(16)
        }
        .frame(width: Self.width, height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onChange(of: model.mode) { _, _ in
            if !model.outputChoices.contains(where: { $0.uid == model.outputUID }) {
                model.outputUID = model.outputChoices.first(where: \.isDefault)?.uid ?? model.outputChoices.first?.uid ?? ""
            }
            if model.rate != 0, !model.availableRates.contains(model.rate) { model.rate = 0 }
        }
    }
    private var main: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(connectionLabel)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Toggle("Connection", isOn: Binding(
                    get: { state.connected }, set: { _ in model.toggleConnection() }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(accent)
                    .disabled(state.busy || (!state.connected && (model.selectedOutput == nil || model.connectionRequirement != nil)))
                    .help(state.connected ? "Turn off format matching" : "Match your selected output to your music")
                moreMenu
            }.frame(height: 24)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    if let shownRate {
                        Text(rateLabel(shownRate)).font(.system(size: 44, weight: .regular)).tracking(-1.8)
                            .minimumScaleFactor(0.75)
                        Text("kHz").font(.system(size: 19, weight: .regular))
                    } else {
                        Text("Ready").font(.system(size: 34, weight: .regular)).tracking(-1)
                    }
                }.lineLimit(1)
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                    Text(statusLabel).font(.system(size: 11, weight: .medium))
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }.help(state.error ?? state.detail).accessibilityElement(children: .combine)
            }.frame(maxWidth: .infinity, minHeight: 130, alignment: .leading)
            Spacer(minLength: 0)
            connectionControls
        }
    }
    private var connectionLabel: String {
        guard model.mode == .format else { return model.mode.name }
        if model.rate != 0 { return "Manual rate" }
        return model.source == .appleMusic ? "Automatic" : "Spotify profile"
    }
    private var statusLabel: String {
        if state.busy { return state.title }
        if state.error != nil { return "Connection stopped" }
        if !state.connected { return model.selectedOutput == nil ? "Choose an output" : "Ready to match" }
        if state.unsupportedRate != nil { return "Rate not supported" }
        if state.depthLimited { return "Rate matched · depth limited" }
        if state.needsAttention { return format == nil ? "Source unknown" : "Check connection" }
        if !state.player.playing { return "Waiting for music" }
        guard let format else { return "Waiting for source" }
        let label: String
        switch format.evidence {
        case .manual: label = "Manual rate"
        case .spotifyPolicy: label = "Spotify profile"
        default: label = model.mode == .exclusive ? "Exclusive preview" : "Matched"
        }
        return label + (format.bits.map { " · \($0)-bit" } ?? "")
    }
    private var statusColor: Color {
        if state.error != nil || state.needsAttention { return .orange }
        return state.connected && format != nil ? accent : .secondary
    }
    private var moreMenu: some View {
        Menu {
            Button("Connection details") { model.page = .details }
            Button("Settings") { model.page = .settings }
            Divider()
            Button("Open \(model.source.name)", action: model.openSource)
            Button("About filo") { model.page = .about }
            Divider()
            Button("Quit filo") { NSApp.terminate(nil) }.keyboardShortcut("q")
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 13, weight: .medium))
                .frame(width: 24, height: 24).modifier(ControlGlass())
                .contentShape(Circle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("More options").help("More options")
    }
    private var connectionControls: some View {
        HStack(spacing: 7) {
            Menu {
                ForEach(MusicSource.allCases) { source in
                    Button { model.select(source: source) } label: {
                        if source == model.source { Label(source.name, systemImage: "checkmark") }
                        else { Text(source.name) }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    if let icon = SceneArtwork.appIcon(model.source) {
                        Image(nsImage: icon).resizable().frame(width: 17, height: 17)
                    }
                    Text(model.source == .appleMusic ? "Music" : "Spotify").lineLimit(1)
                    Spacer(minLength: 3)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .medium))
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8).frame(height: 30).modifier(ControlGlass())
                    .contentShape(Capsule())
                    .accessibilityElement(children: .ignore).accessibilityLabel("Music app: \(model.source.name)")
            }.frame(maxWidth: .infinity).accessibilityLabel("Music app: \(model.source.name)")
            Image(systemName: "arrow.right").font(.system(size: 12)).foregroundStyle(.secondary).accessibilityHidden(true)
            Menu {
                if model.outputChoices.isEmpty { Text("No outputs available") }
                if model.selectedOutput == nil, !model.outputUID.isEmpty { Text("Selected output is disconnected") }
                ForEach(model.outputChoices) { output in
                    Button { model.select(outputUID: output.uid) } label: {
                        if output.uid == model.outputUID { Label(output.name, systemImage: "checkmark") }
                        else { Text(output.name) }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "headphones").font(.system(size: 14))
                    Text(model.selectedOutput?.name ?? "Output").lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 3)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .medium))
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8).frame(height: 30).modifier(ControlGlass())
                    .contentShape(Capsule())
                    .accessibilityElement(children: .ignore).accessibilityLabel("Output: \(model.selectedOutput?.name ?? "Choose an output")")
            }.frame(maxWidth: .infinity).accessibilityLabel("Output: \(model.selectedOutput?.name ?? "Choose an output")")
                .help(model.selectedOutput?.name ?? "Choose your output device")
        }
        .font(.system(size: 12, weight: .medium)).menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .padding(.horizontal, 6).frame(maxWidth: .infinity).frame(height: 42).modifier(ControlGlass()).disabled(state.busy)
    }
    private func pageHeader(_ title: String) -> some View {
        HStack(spacing: 8) {
            Button { model.page = .main } label: {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .medium)).frame(width: 24, height: 24)
            }.buttonStyle(.plain).accessibilityLabel("Back")
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer()
        }.frame(height: 24)
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            pageHeader("Connection details")
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    detailRow("Source", value: format.map { describe($0) } ?? "Not observed")
                    detailRow("Output", value: outputDescription)
                    if let format { detailRow("Evidence", value: format.evidence.rawValue) }
                    Text(state.error ?? state.detail).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(state.error == nil ? Color.secondary : Color.orange)
                    if let requirement = model.connectionRequirement { Text(requirement).font(.system(size: 11)).foregroundStyle(.secondary) }
                    if model.source == .spotify {
                        Text("Spotify follows a 44.1 kHz music profile. Individual tracks, podcasts and ads are not detected.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Text("Format matching reports observed formats. It does not verify the samples received by your DAC.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Copy diagnostics", action: model.copyDiagnostics).controlSize(.small)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private func detailRow(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func describe(_ format: SourceFormat) -> String {
        "\(rateLabel(format.rate)) kHz" + (format.bits.map { " · \($0)-bit" } ?? " · depth unknown")
    }
    private var outputDescription: String {
        guard let output = model.displayedOutput else { return "Disconnected" }
        let pcm = state.exclusivePhysicalFormat ?? output.formats.first
        let details = pcm.map { " · \($0.bits)-bit \($0.flags & kAudioFormatFlagIsFloat != 0 ? "float" : "integer") · \($0.channels) ch" } ?? ""
        return "\(output.name)\n\(rateLabel(output.rate)) kHz\(details)"
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            pageHeader("Settings")
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Sample rate", selection: $model.rate) {
                        Text(model.source == .appleMusic ? "Automatic" : "Spotify · 44.1 kHz").tag(Double(0))
                        ForEach(model.availableRates, id: \.self) { Text("\(rateLabel($0)) kHz").tag($0) }
                    }
                    Picker("Audio path", selection: $model.mode) {
                        ForEach(ConnectionMode.allCases) { Text($0.name).tag($0) }
                    }
                    Text(state.connected ? "Turn off matching before changing these settings." : "Format matching lets your player handle playback and follows the source format when available.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if model.mode != .format {
                        Text("Relay modes are experimental. They require audio capture permission; exclusive preview also requires BlackHole 2ch.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }.disabled(state.connected || state.busy).font(.system(size: 12))
            }
        }
    }
    private var about: some View {
        VStack(alignment: .leading, spacing: 16) {
            pageHeader("About filo")
            Text("Your music. A direct connection.").font(.system(size: 19, weight: .medium))
            Text("Automatic output format matching, quietly in your menu bar.").font(.system(size: 12)).foregroundStyle(.secondary)
            Text(model.appVersion).font(.system(size: 11)).foregroundStyle(.secondary)
            Link("Guide and source code", destination: URL(string: "https://github.com/Audiofool934/filo")!).font(.system(size: 12))
            Spacer()
        }
    }
}

private struct PanelMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let view = NSGlassEffectView()
            view.style = .regular; view.cornerRadius = 20
            return view
        }
        let view = NSVisualEffectView()
        view.material = .popover; view.blendingMode = .behindWindow; view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
private struct ControlGlass: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) { content.glassEffect(.regular, in: .capsule) }
        else { content.background(.regularMaterial, in: Capsule()) }
    }
}

/// Only two downsampled scenes stay decoded. Closed panels do not request artwork.
private enum SceneArtwork {
    static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 2; cache.totalCostLimit = 4 * 1024 * 1024
        return cache
    }()
    static var icons: [MusicSource: NSImage] = [:]
    static func image(rate: Double?) -> NSImage? {
        let name: String
        switch rate ?? 48000 {
        case ...44100: name = "cd"
        case ...48000: name = "studio"
        case ...96000: name = "hifi"
        default: name = "reference"
        }
        if let cached = cache.object(forKey: name as NSString) { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Scenes"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 680,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let result = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        cache.setObject(result, forKey: name as NSString, cost: image.bytesPerRow * image.height)
        return result
    }
    static func appIcon(_ source: MusicSource) -> NSImage? {
        if let icon = icons[source] { return icon }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[source] = icon
        return icon
    }
}
