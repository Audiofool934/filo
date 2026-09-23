import Foundation

public enum MusicSource: String, Codable, CaseIterable, Identifiable {
    case appleMusic, spotify
    public var id: String { rawValue }
    public var name: String { self == .appleMusic ? "Apple Music" : "Spotify" }
    public var bundleID: String { self == .appleMusic ? "com.apple.Music" : "com.spotify.client" }
}

public enum FormatEvidence: String, Codable {
    case localFile = "Local file"
    case decoder = "Music decoder"
    case spotifyPolicy = "Spotify music profile"
    case manual = "Manual selection"
}

public struct SourceFormat: Codable, Equatable {
    public var rate: Double
    public var bits: Int?
    public var evidence: FormatEvidence
    public var observedAt: Date
    public init(rate: Double, bits: Int? = nil, evidence: FormatEvidence, observedAt: Date = Date()) {
        self.rate = rate; self.bits = bits; self.evidence = evidence; self.observedAt = observedAt
    }
}

/// Only decoder-input messages are accepted. Device formats and generic Hz strings are not source evidence.
public enum DecoderFormatParser {
    private static let pattern = try! NSRegularExpression(
        pattern: #"ACAppleLosslessDecoder\.cpp:.*Input format:\s*(\d+) ch,\s*(\d+) Hz, alac .*from (\d+)-bit source"#)

    public static func parse(_ message: String, at date: Date = Date()) -> SourceFormat? {
        let range = NSRange(message.startIndex..., in: message)
        guard let match = pattern.firstMatch(in: message, range: range) else { return nil }
        func number(_ index: Int) -> Int? {
            guard let range = Range(match.range(at: index), in: message) else { return nil }
            return Int(message[range])
        }
        guard number(1) == 2, let rate = number(2), let bits = number(3),
              [16, 20, 24, 32].contains(bits), rate >= 8000, rate <= 768000 else { return nil }
        return SourceFormat(rate: Double(rate), bits: bits, evidence: .decoder, observedAt: date)
    }
}

/// Track identity gates decoder observations so prebuffered future tracks cannot switch the current output.
public struct FormatPolicy {
    public private(set) var trackID: String?
    public private(set) var trackStarted = Date.distantPast
    public private(set) var current: SourceFormat?
    public private(set) var playing = false
    private var recent: [SourceFormat] = []
    public init() {}

    public mutating func trackChanged(id: String?, playing: Bool, now: Date = Date()) {
        let resumedUnknown = playing && !self.playing && current == nil
        self.playing = playing
        guard id != trackID || resumedUnknown else { return }
        trackID = id; trackStarted = now; current = nil
        // Decoder startup can precede the player's notification. Keep a bounded
        // transition window, with explicit decoder provenance rather than a PCM guarantee.
        recent.removeAll { now.timeIntervalSince($0.observedAt) > 2 || $0.observedAt > now }
        if playing, id != nil, Set(recent.map(\.rate)).count == 1 { current = recent.last }
    }
    public mutating func observe(_ format: SourceFormat, now: Date = Date()) -> SourceFormat? {
        guard now.timeIntervalSince(format.observedAt) >= -0.1,
              now.timeIntervalSince(format.observedAt) <= 3 else { return nil }
        recent.append(format)
        recent.removeAll { now.timeIntervalSince($0.observedAt) > 3 }
        guard playing, trackID != nil, format.observedAt >= trackStarted,
              now.timeIntervalSince(trackStarted) <= 8 else { return nil }
        // Conflicting decoder rates in one transition can be prefetch. Wait for an unambiguous observation.
        guard Set(recent.map(\.rate)).count == 1 else { current = nil; return nil }
        current = format
        return format
    }
    public mutating func useLocal(_ format: SourceFormat) {
        guard playing, trackID != nil, format.evidence == .localFile else { return }
        current = format
    }
    public mutating func reset() { self = FormatPolicy() }
}
