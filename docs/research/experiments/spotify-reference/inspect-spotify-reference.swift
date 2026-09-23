import AVFoundation
import CoreAudio
import CryptoKit
import Darwin
import FiloCore
import FiloPCM
import Foundation

// Task-only Spotify process-tap inspection, restricted to our original synthetic fixture.
let usage = """
Usage: work/inspect-spotify-reference --known-synthetic-only --format wav|alac|flac [--seconds 45] [--label RUN] [--validate-only]
Only the fixed five-second 44100/24 stereo files in work/spotify-reference-fixtures are accepted.
The operator must play the selected synthetic file once in Spotify after READY_ARMED.
This program never launches or controls Spotify and must not capture subscription audio.
Captures only com.spotify.client on BlackHole at 44100 Hz, relay=false, with no physical DAC output.
Capture duration must be 10...60 whole seconds; process readiness has a separate 15-second deadline.
Writes new spotify-FORMAT-LABEL-tap.f32 and .json files under work, without overwriting.
--help reads no fixture and touches no audio hardware or application.
--validate-only independently decodes and checks the fixed fixture without accessing HAL, routing, Spotify, or capture.
"""
let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
let work = executable.deletingLastPathComponent(), repository = work.deletingLastPathComponent()
func uptime() -> Double { ProcessInfo.processInfo.systemUptime }
func progress(_ value: String) { FileHandle.standardError.write(Data((value + "\n").utf8)) }
func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func hashFile(_ file: URL) throws -> String { hash(try Data(contentsOf: file)) }
func floatBytes(_ samples: [Float]) -> Data {
    var data = Data(capacity: samples.count * 4)
    for sample in samples {
        var word = sample.bitPattern.littleEndian
        withUnsafeBytes(of: &word) { data.append(contentsOf: $0) }
    }
    return data
}

struct Options {
    let format: String, seconds: Int, label: String
    let validateOnly: Bool
    init(_ arguments: [String]) throws {
        var values: [String: String] = [:], acknowledged = false, validateOnly = false, index = 0
        while index < arguments.count {
            let key = arguments[index]
            if key == "--known-synthetic-only", !acknowledged { acknowledged = true; index += 1; continue }
            if key == "--validate-only", !validateOnly { validateOnly = true; index += 1; continue }
            guard ["--format", "--seconds", "--label"].contains(key), values[key] == nil,
                  index + 1 < arguments.count else { throw AudioFailure(usage) }
            values[key] = arguments[index + 1]; index += 2
        }
        guard acknowledged, let format = values["--format"], ["wav", "alac", "flac"].contains(format),
              let seconds = Int(values["--seconds"] ?? "45"), (10...60).contains(seconds) else { throw AudioFailure(usage) }
        let label = values["--label"] ?? "first"
        guard !label.isEmpty, label.count <= 40,
              label.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-").contains($0) }) else {
            throw AudioFailure("The run label must contain 1...40 ASCII letters, digits, or hyphens.")
        }
        self.format = format; self.seconds = seconds; self.label = label; self.validateOnly = validateOnly
    }
    var fixtureURL: URL {
        let extensionName = ["wav": "wav", "alac": "m4a", "flac": "flac"][format]!
        return work.appendingPathComponent("spotify-reference-fixtures/filo reference 44100 stereo 24bit \(format.uppercased()).\(extensionName)")
    }
    var base: URL { work.appendingPathComponent("spotify-\(format)-\(label)-tap") }
}

// The canonical ReferencePCM decoder does not claim FLAC support; this local check does.
// Every decoded Float32 sample must independently equal the known original integer sample.
func validateFixture(_ options: Options, canonical: ReferencePCM) throws -> String {
    let url = options.fixtureURL
    let metadata = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard metadata.isRegularFile == true, let size = metadata.fileSize, size > 0, size <= 4_000_000 else {
        throw AudioFailure("The fixed fixture must be a bounded regular local file.")
    }
    let before = try hashFile(url)
    let file: AVAudioFile
    do { file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: true) }
    catch { throw AudioFailure("Fixture decoder open failed for \(options.format): \(error.localizedDescription)") }
    let source = file.fileFormat.streamDescription.pointee
    let expectedID = ["wav": kAudioFormatLinearPCM, "alac": kAudioFormatAppleLossless, "flac": kAudioFormatFLAC][options.format]!
    guard source.mFormatID == expectedID, source.mSampleRate == 44100, source.mChannelsPerFrame == 2,
          file.length == 220500, file.processingFormat.sampleRate == 44100,
          file.processingFormat.channelCount == 2, file.processingFormat.commonFormat == .pcmFormatFloat32,
          file.processingFormat.isInterleaved,
          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16384) else {
        throw AudioFailure("The selected fixture does not decode directly to the required codec, duration, and stereo format.")
    }
    var index = 0
    while index < canonical.samples.count {
        do { try file.read(into: buffer, frameCount: min(buffer.frameCapacity, AVAudioFrameCount((canonical.samples.count - index) / 2))) }
        catch { throw AudioFailure("Fixture decode failed for \(options.format) at frame \(index / 2): \(error.localizedDescription)") }
        guard buffer.frameLength > 0, buffer.stride == 2, let pointer = buffer.floatChannelData?[0] else {
            throw AudioFailure("The fixture ended early or changed its decode layout.")
        }
        for sampleIndex in 0..<(Int(buffer.frameLength) * 2) {
            guard index < canonical.samples.count, pointer[sampleIndex].bitPattern == canonical.samples[index].bitPattern,
                  pointer[sampleIndex] == filo_test_sample(UInt64(index / 2), UInt32(index % 2), 24) else {
                throw AudioFailure("The selected file differs from the original deterministic sample sequence.")
            }
            index += 1
        }
    }
    // AVAudioFile throws on an additional read at EOF for each of these codecs.
    // Its declared valid-frame count was checked above; require every one to be consumed exactly.
    guard index == canonical.samples.count, file.framePosition == file.length, file.length == 220500,
          try hashFile(url) == before else { throw AudioFailure("The fixture length or contents changed during decoding.") }
    return before
}

struct Report: Encodable {
    let boundary, playerBundleID, sourceCodec, referenceFile, referenceSHA256, canonicalReferenceSHA256: String
    let referenceFrames: Int
    let referenceBits: Int
    let sampleRate: Double
    let channels: Int
    let captureFile, captureSHA256, sampleEncoding, expectedFloat32SHA256: String
    let sourceSHA256: [String: String]
    let binarySHA256, createdAt, systemVersion: String
    let requestedCaptureSeconds: Int
    let elapsedCaptureSeconds: Double
    let captureCapacityFrames: UInt64
    let inputFormat: PCMFormat?
    let metrics: TransportMetrics?
    let comparison: ReferencePCMComparison
    let firstNonzeroFrame, lastNonzeroFrame: Int?
    let nonFiniteSamples, off24BitGridSamples: Int
    let alignedFloat32WordMismatches: Int?
    let timestampEvidence: String
    let sourcePlaybackCompletion: String
    let restorationErrors: [String]
    let failure: String?
    let passed: Bool
}

func inspect(_ options: Options) throws -> Bool {
    let captureURL = options.base.appendingPathExtension("f32"), reportURL = options.base.appendingPathExtension("json")
    if !options.validateOnly {
        guard !FileManager.default.fileExists(atPath: captureURL.path), !FileManager.default.fileExists(atPath: reportURL.path),
              FileManager.default.isWritableFile(atPath: work.path) else { throw AudioFailure("A run output already exists or work is not writable; use a new label.") }
    }
    let canonical = try ReferencePCM.load(from: work.appendingPathComponent("filo-reference-44100-24.wav"), maximumFrames: 220500)
    guard canonical.frameCount == 220500, canonical.samples.count == 441000, canonical.bits == 24,
          canonical.sampleRate == 44100, canonical.sourceFormat == "integer PCM" else { throw AudioFailure("The original canonical WAV is required.") }
    for index in canonical.samples.indices {
        guard canonical.samples[index] == filo_test_sample(UInt64(index / 2), UInt32(index % 2), 24) else {
            throw AudioFailure("The canonical WAV differs from the known synthetic sequence.")
        }
    }
    let referenceHash = try validateFixture(options, canonical: canonical)
    if options.validateOnly {
        let value: [String: Any] = ["validationOnly": true, "hardwareAccess": false, "passed": true,
            "sourceCodec": options.format.uppercased(), "referenceFile": options.fixtureURL.lastPathComponent,
            "referenceSHA256": referenceHash, "canonicalReferenceSHA256": canonical.fileSHA256,
            "sampleRate": canonical.sampleRate, "bits": canonical.bits, "frames": canonical.frameCount,
            "comparedSamples": canonical.samples.count, "mismatchedFloat32Words": 0,
            "expectedFloat32SHA256": hash(floatBytes(canonical.samples))]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]))
        FileHandle.standardOutput.write(Data([10]))
        return true
    }
    let sourceNames = ["work/inspect-spotify-reference.swift", "Sources/FiloCore/AudioSession.swift",
                       "Sources/FiloCore/ReferencePCM.swift", "Sources/FiloPCM/Transport.c"]
    let sourceHashes = try Dictionary(uniqueKeysWithValues: sourceNames.map { ($0, try hashFile(repository.appendingPathComponent($0))) })
    let binaryHash = try hashFile(executable)
    progress("REFERENCE_VALIDATED codec=\(options.format) frames=220500 SHA256=\(referenceHash)")

    var interrupted: Int32?
    let signalNumbers = [SIGINT, SIGTERM, SIGHUP]
    let oldSignals = signalNumbers.map { signal($0, SIG_IGN) }
    let signals = signalNumbers.map { number in
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler { interrupted = number }; source.resume(); return source
    }
    defer {
        signals.forEach { $0.cancel() }
        for (number, old) in zip(signalNumbers, oldSignals) { signal(number, old) }
    }
    func waitBriefly() throws {
        _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        Thread.sleep(forTimeInterval: 0.01)
        if let interrupted { throw AudioFailure("Interrupted by signal \(interrupted).") }
    }
    let route = DeviceLease(journalURL: DeviceLease.defaultJournalURL), session = AudioSession()
    var devices: [OutputDevice] = [], samples: [Float] = []
    var inputFormat: PCMFormat?, metrics: TransportMetrics?, failure: String?
    var beganAt: Double?, elapsed = 0.0, completedWindow = false
    let capacity = UInt64((options.seconds + 2) * 44100)
    do {
        let exclusiveRecovery = ExclusiveRecoveryJournal.recoverOrphaned()
        guard exclusiveRecovery.isEmpty else { throw AudioFailure(exclusiveRecovery.joined(separator: " ")) }
        let routeRecovery = route.recoverOrphaned()
        guard routeRecovery.isEmpty else { throw AudioFailure(routeRecovery.joined(separator: " ")) }
        devices = try HAL.outputDevices()
        let sources = devices.filter(ConnectionController.isExclusiveSourceDevice)
        guard sources.count == 1, let initial = sources.first else { throw AudioFailure("One unambiguous BlackHole 2ch source is required.") }
        try route.begin(output: initial); try route.apply(rate: 44100)
        guard let source = try HAL.outputDevices().first(where: { $0.uid == initial.uid }), source.rate == 44100 else {
            throw AudioFailure("BlackHole did not confirm the fixed 44100 Hz rate.")
        }
        progress("WAITING_SPOTIFY_PROCESS route=BlackHole rate=44100 deadline=15s; no player launch or transport control is performed.")
        var processes: [AudioProcess] = []
        let deadline = uptime() + 15
        while processes.isEmpty {
            processes = try HAL.processes().filter { $0.bundleID == "com.spotify.client" && kill($0.pid, 0) == 0 }
            if !processes.isEmpty { break }
            guard uptime() < deadline else { throw AudioFailure("Spotify did not expose an audio process within 15 seconds.") }
            try waitBriefly()
        }
        guard try HAL.defaultOutput() == source.id, try HAL.rate(source.id) == 44100 else { throw AudioFailure("The reference route changed before arming.") }
        try session.startCapture(processIDs: processes.map(\.id).sorted(), output: source, relay: false, captureFrames: capacity)
        inputFormat = session.inputFormat
        guard inputFormat?.isFloatStereo == true, inputFormat?.rate == 44100 else { throw AudioFailure("The tap did not confirm matching-rate stereo Float32.") }
        beganAt = uptime()
        var nextCheck = 0.0
        progress("READY_ARMED seconds=\(options.seconds) rate=44100 relay=false codec=\(options.format); play only the selected five-second synthetic fixture once now.")
        while uptime() - beganAt! < Double(options.seconds) {
            try waitBriefly()
            let m = session.metrics
            guard m.invalidBuffers == 0, m.capturedFrames < capacity else { throw AudioFailure("The capture buffer filled or its layout became invalid.") }
            if uptime() >= nextCheck {
                guard try HAL.defaultOutput() == source.id, try HAL.rate(source.id) == 44100 else { throw AudioFailure("The source route or rate changed during capture.") }
                let current = try HAL.processes()
                guard processes.allSatisfy({ original in current.contains(where: { $0.id == original.id && $0.pid == original.pid && $0.bundleID == "com.spotify.client" }) }) else {
                    throw AudioFailure("The selected Spotify process identity changed during capture.")
                }
                guard try hashFile(options.fixtureURL) == referenceHash else { throw AudioFailure("The selected fixture changed during capture.") }
                nextCheck = uptime() + 1
            }
        }
        completedWindow = true
    } catch { failure = error.localizedDescription }
    // Release tap IO before route restoration, including interruption and failed setup.
    if session.running {
        samples = session.finishCapture(); metrics = session.metrics
        if let beganAt { elapsed = uptime() - beganAt }
    }
    session.stop()
    let restorationErrors = route.restore()
    progress(restorationErrors.isEmpty ? "ROUTE_RESTORED" : "RESTORATION_REQUIRES_ATTENTION")

    let comparison = ReferencePCM.compare(capture: samples, reference: canonical)
    let raw = floatBytes(samples)
    var nonFinite = 0, offGrid = 0, first: Int?, last: Int?
    for (index, sample) in samples.enumerated() {
        if sample != 0 { if first == nil { first = index / 2 }; last = index / 2 }
        if !sample.isFinite { nonFinite += 1 }
        else if (Double(sample) * 8388608).rounded(.towardZero) != Double(sample) * 8388608 { offGrid += 1 }
    }
    var wordMismatches: Int?
    if comparison.fullReferenceExact {
        let start = comparison.captureStartFrame * 2
        wordMismatches = canonical.samples.indices.reduce(0) { count, index in
            count + (samples[start + index].bitPattern == canonical.samples[index].bitPattern ? 0 : 1)
        }
    }
    func sanitize(_ text: String) -> String {
        var result = text.replacingOccurrences(of: repository.path, with: "<repository>").replacingOccurrences(of: NSHomeDirectory(), with: "<home>")
        for device in devices where !device.uid.isEmpty { result = result.replacingOccurrences(of: device.uid, with: "<device>") }
        return result
    }
    let passed = completedWindow && failure == nil && restorationErrors.isEmpty && comparison.fullReferenceExact
        && wordMismatches == 0 && nonFinite == 0 && offGrid == 0 && (metrics?.callbacks ?? 0) > 0
        && metrics?.invalidBuffers == 0 && metrics?.capturedFrames == UInt64(samples.count / 2)
        && comparison.leadingCaptureFrames >= 512 && comparison.trailingCaptureFrames >= 44100
    let report = Report(boundary: "Spotify process-specific Float32 tap pinned to BlackHole; relay disabled; physical DAC, USB receiver and streaming masters unobserved",
        playerBundleID: "com.spotify.client", sourceCodec: options.format.uppercased(), referenceFile: options.fixtureURL.lastPathComponent,
        referenceSHA256: referenceHash, canonicalReferenceSHA256: canonical.fileSHA256,
        referenceFrames: canonical.frameCount, referenceBits: canonical.bits, sampleRate: 44100, channels: 2,
        captureFile: captureURL.lastPathComponent, captureSHA256: hash(raw), sampleEncoding: "IEEE754 Float32 little-endian, interleaved L/R",
        expectedFloat32SHA256: hash(floatBytes(canonical.samples)), sourceSHA256: sourceHashes, binarySHA256: binaryHash,
        createdAt: ISO8601DateFormatter().string(from: Date()), systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
        requestedCaptureSeconds: options.seconds, elapsedCaptureSeconds: elapsed, captureCapacityFrames: capacity,
        inputFormat: inputFormat, metrics: metrics, comparison: comparison, firstNonzeroFrame: first, lastNonzeroFrame: last,
        nonFiniteSamples: nonFinite, off24BitGridSamples: offGrid, alignedFloat32WordMismatches: wordMismatches,
        timestampEvidence: "Unavailable in this tap-only AudioSession: TransportMetrics exposes no callback timestamp continuity counters.",
        sourcePlaybackCompletion: "Not queried; complete first-to-last reference coverage is established only by the independent capture comparison.",
        restorationErrors: restorationErrors.map(sanitize), failure: failure.map(sanitize), passed: passed)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let reportData = try encoder.encode(report)
    try raw.write(to: captureURL, options: .withoutOverwriting)
    try reportData.write(to: reportURL, options: .withoutOverwriting)
    FileHandle.standardOutput.write(reportData); FileHandle.standardOutput.write(Data([10]))
    return passed
}

if CommandLine.arguments.dropFirst().contains("--help") { print(usage); exit(EXIT_SUCCESS) }
signal(SIGPIPE, SIG_IGN)
do { if try !inspect(Options(Array(CommandLine.arguments.dropFirst()))) { exit(EXIT_FAILURE) } }
catch { progress("inspect-spotify-reference: \(error.localizedDescription)"); exit(EXIT_FAILURE) }
