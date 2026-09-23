import SwiftUI
import FiloCore

private let accent = Color(red: 0.12, green: 0.48, blue: 0.46)

struct FiloView: View {
    @ObservedObject var model: AppModel
    @State private var showDetails = false
    private var state: ConnectionSnapshot { model.snapshot }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                configuration
                Text("This becomes your Mac’s output while connected.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                signalPath
                status
                Button(action: model.toggleConnection) {
                    HStack {
                        Spacer()
                        if state.busy { ProgressView().controlSize(.small) }
                        Text(state.connected ? "Disconnect" : "Connect").fontWeight(.semibold)
                        Spacer()
                    }.padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent).tint(accent).controlSize(.large)
                .disabled(state.busy || (!state.connected && model.selectedOutput == nil))
                .keyboardShortcut(.return, modifiers: [])
                DisclosureGroup("Connection details", isExpanded: $showDetails) { details.padding(.top, 12) }
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                footer
            }
            .padding(.horizontal, 28).padding(.top, 30).padding(.bottom, 24)
        }
        .frame(width: 440, height: 650)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: model.outputUID) { _, _ in
            if model.rate != 0, !(model.selectedOutput?.supportedRates.contains(model.rate) ?? false) { model.rate = 0 }
        }
        .onChange(of: model.source) { _, _ in model.rate = 0 }
    }
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("filo").font(.system(size: 34, weight: .medium, design: .rounded)).tracking(-1.5)
                Text("Your music. A direct connection.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 0) {
                Circle().stroke(accent, lineWidth: 1.5).frame(width: 7, height: 7)
                Rectangle().fill(accent).frame(width: 40, height: 1.5)
                Circle().fill(accent).frame(width: 7, height: 7)
            }.padding(.top, 17).accessibilityHidden(true)
        }
    }
    private var configuration: some View {
        VStack(spacing: 14) {
            field("Music app") {
                Picker("Music app", selection: $model.source) {
                    ForEach(MusicSource.allCases) { Text($0.name).tag($0) }
                }.labelsHidden()
            }
            field("Output") {
                Picker("Output device", selection: $model.outputUID) {
                    if model.selectedOutput == nil { Text("Choose an output").tag(model.outputUID) }
                    ForEach(state.devices) { Text($0.name).tag($0.uid) }
                }.labelsHidden()
            }
            field("Sample rate") {
                Picker("Sample rate", selection: $model.rate) {
                    Text(model.source == .appleMusic ? "Automatic" : "Spotify · 44.1 kHz").tag(Double(0))
                    ForEach(model.selectedOutput?.supportedRates ?? [], id: \.self) { Text("\(rateLabel($0)) kHz").tag($0) }
                }.labelsHidden()
            }
        }.disabled(state.connected || state.busy)
    }
    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 86, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
    private var signalPath: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("SOURCE").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
                Text(state.sourceFormat.map { "\(rateLabel($0.rate)) kHz" } ?? "Unknown")
                    .font(.system(size: 21, weight: .medium, design: .monospaced))
                Text(sourceDescription).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.right").foregroundStyle(accent).font(.system(size: 14, weight: .light))
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 6) {
                Text("OUTPUT").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
                Text(model.selectedOutput.map { "\(rateLabel($0.rate)) kHz" } ?? "Offline")
                    .font(.system(size: 21, weight: .medium, design: .monospaced))
                Text(model.selectedOutput?.formats.first.map { "\($0.channels) ch · \($0.bits)-bit container" } ?? "No device")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(accent.opacity(0.14), lineWidth: 0.5))
    }
    private var status: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Circle().fill(state.error != nil ? Color.orange : (state.connected ? accent : Color.secondary.opacity(0.4))).frame(width: 6, height: 6)
                Text(state.title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: model.openSource) { Image(systemName: "arrow.up.right.square") }.buttonStyle(.plain)
                    .help("Open \(model.source.name)")
            }
            Text(state.error ?? state.detail).font(.system(size: 11)).foregroundStyle(state.error == nil ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
            if let volume = state.player.volume, state.player.playing, volume < 100 {
                Text("Player volume is \(volume)%. For unchanged PCM, use 100% and control listening level on your DAC.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.frame(minHeight: 55, alignment: .topLeading)
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Audio path", selection: $model.mode) {
                ForEach([ConnectionMode.format, .relay]) { Text($0.name).tag($0) }
            }.disabled(state.connected)
            Text("Format matching lets your player output normally. Direct relay forwards the chosen app without DSP. The output remains shared with other apps.")
                .fixedSize(horizontal: false, vertical: true)
            if model.source == .spotify {
                Text("Spotify uses a fixed 44.1 kHz music profile. filo cannot verify individual Spotify tracks, podcasts, or ads.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Matching rates and exclusive access do not prove end-to-end bit-perfect playback. Source processing, normalization, and the final DAC input need separate verification.")
                .fixedSize(horizontal: false, vertical: true)
            if let metrics = state.metrics {
                Text("Relay: \(metrics.frames) frames · \(metrics.invalidBuffers) invalid buffers").monospacedDigit()
                Text("Non-silent samples: \(metrics.nonzeroSamples)").monospacedDigit()
            }
            if let format = state.tapFormat {
                Text("Capture: \(rateLabel(format.rate)) kHz · \(format.channels) ch · Float32")
            }
            Button("Copy diagnostics", action: model.copyDiagnostics).controlSize(.small)
        }
    }
    private var sourceDescription: String {
        guard let format = state.sourceFormat else { return model.source.name }
        if let bits = format.bits { return "\(bits)-bit · \(format.evidence.rawValue)" }
        return format.evidence.rawValue
    }
    private var footer: some View {
        HStack {
            Text("1.0.0").foregroundStyle(.tertiary)
            Spacer()
            Link("Guide", destination: URL(string: "https://github.com/Audiofool934/filo#readme")!)
            Text("·").foregroundStyle(.tertiary)
            Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain).foregroundStyle(.secondary).keyboardShortcut("q")
        }.font(.system(size: 10))
    }
}
