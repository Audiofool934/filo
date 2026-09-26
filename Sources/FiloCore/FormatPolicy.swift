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

/// Associates nearby decoder diagnostics with a playback transition.
/// Decoder messages have no track identity, so this is a bounded inference, not authenticated metadata.
public struct FormatPolicy {
    public private(set) var trackID: String?
    public private(set) var trackStarted = Date.distantPast
    public private(set) var current: SourceFormat?
    public private(set) var playing = false
    private var pending: [SourceFormat] = []
    private var transitionRates: Set<Double> = []
    private var assignedRate: Double?
    private var assignedEvents: [SourceFormat] = []
    private var discardedThrough = Date.distantPast
    public init() {}

    public mutating func trackChanged(id: String?, playing: Bool, now: Date = Date(), observedAt: Date? = nil) {
        let resumedUnknown = playing && !self.playing && current == nil
        self.playing = playing
        guard id != trackID || resumedUnknown else { return }
        trackID = id; trackStarted = now; current = nil
        if let observedAt {
            let age = now.timeIntervalSince(observedAt)
            if age.isFinite, age >= -0.1, age <= 3 { trackStarted = observedAt }
        }
        transitionRates.removeAll(); assignedRate = nil
        assignedEvents.removeAll { now.timeIntervalSince($0.observedAt) > 3 }
        // Startup can precede the player's notification. Only previously unassigned
        // diagnostics can be considered, and only once, inside this short window.
        pending.removeAll {
            now.timeIntervalSince($0.observedAt) > 3 ||
                $0.observedAt < trackStarted.addingTimeInterval(-2) || $0.observedAt > now
        }
        if playing, id != nil {
            transitionRates = Set(pending.map(\.rate))
            if transitionRates.count == 1 {
                current = pending.last; assignedRate = current?.rate
                rememberAssigned(pending, now: now)
            }
        }
        pending.removeAll()
    }
    public mutating func observe(_ format: SourceFormat, now: Date = Date()) -> SourceFormat? {
        guard now.timeIntervalSince(format.observedAt) >= -0.1,
              now.timeIntervalSince(format.observedAt) <= 3 else { return nil }
        // A file read associated with the current track is stronger evidence than
        // an unassociated decoder diagnostic, including a possible prefetch.
        guard current?.evidence != .localFile else { return nil }
        pending.removeAll { now.timeIntervalSince($0.observedAt) > 3 }
        assignedEvents.removeAll { now.timeIntervalSince($0.observedAt) > 3 }
        guard format.observedAt > discardedThrough, !assignedEvents.contains(format) else { return nil }
        guard playing, trackID != nil, now.timeIntervalSince(trackStarted) <= 8 else {
            pending.append(format)
            return nil
        }
        // A log record can arrive after the playback reply even when decoding
        // preceded the read. The same pre-transition allowance applies either way.
        guard format.observedAt >= trackStarted.addingTimeInterval(-2) else { return nil }
        transitionRates.insert(format.rate)
        // Ambiguity persists for this window. Expiration of an earlier diagnostic
        // does not identify which rate belonged to the currently playing track.
        guard transitionRates.count == 1 else {
            current = nil
            // A rejected different-rate diagnostic may precede the next track's
            // notification. It was never assigned to this track, unlike assignedRate.
            if format.rate != assignedRate { pending.append(format) }
            return nil
        }
        current = format; assignedRate = format.rate
        rememberAssigned([format], now: now)
        return format
    }
    public mutating func useLocal(_ format: SourceFormat) {
        guard playing, trackID != nil, format.evidence == .localFile else { return }
        current = format
        pending.removeAll()
    }
    private mutating func rememberAssigned(_ formats: [SourceFormat], now: Date) {
        for format in formats where !assignedEvents.contains(format) { assignedEvents.append(format) }
        // Bound the three-second replay guard even if diagnostics unexpectedly flood.
        // Evicted observations stay ineligible rather than becoming reusable candidates.
        if assignedEvents.count > 256 {
            discardedThrough = max(now, assignedEvents.map(\.observedAt).max() ?? now)
            assignedEvents.removeAll()
        }
    }
    public mutating func reset() { self = FormatPolicy() }
}
