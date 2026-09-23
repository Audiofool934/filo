import Foundation

/// Gates known player processing while keeping unavailable controls explicitly unverified.
/// It does not certify source identity or end-to-end bit-perfect playback.
public struct SourceProcessingAssessment: Codable {
    public let blockingReason: String?
    public let summary: String
    public let knownIssues: [String]
    public let unverifiedControls: [String]

    public init(state: PlayerState, source: MusicSource, now: Date = Date()) {
        var issues: [String] = []
        var unknown: [String] = []
        func fresh(_ observation: Date?, maximumAge: TimeInterval) -> Bool {
            guard let observation else { return false }
            let age = now.timeIntervalSince(observation)
            return age.isFinite && age >= 0 && age <= maximumAge
        }
        let available = state.error == nil
        let primaryFresh = available && fresh(state.primaryObservedAt, maximumAge: 3)
        if primaryFresh, let volume = state.volume, (0...100).contains(volume) {
            if volume != 100 { issues.append("Set \(source.name) volume to 100% before starting exclusive preview.") }
        } else {
            unknown.append("Application volume")
        }
        let processing = state.processing
        let appFresh = available && fresh(processing?.observedAt, maximumAge: 3)
        if appFresh, let muted = processing?.muted {
            if muted { issues.append("Unmute \(source.name) before starting exclusive preview.") }
        } else {
            unknown.append("Application mute")
        }
        if appFresh, let equalizer = processing?.equalizerEnabled {
            if equalizer { issues.append("Turn off the \(source.name) equalizer before starting exclusive preview.") }
        } else {
            unknown.append("Application equalizer")
        }
        let sameTrack = state.trackID != nil && state.trackID?.isEmpty == false && processing?.trackID == state.trackID
        let trackFresh = primaryFresh && sameTrack && fresh(processing?.trackObservedAt, maximumAge: 7)
        if trackFresh, let adjustment = processing?.trackVolumeAdjustment, (-100...100).contains(adjustment) {
            if adjustment != 0 { issues.append("Reset the track's volume adjustment to 0% before starting exclusive preview.") }
        } else {
            unknown.append("Track volume adjustment")
        }
        if trackFresh, let preset = processing?.trackEqualizerPreset {
            if !preset.isEmpty { issues.append("Remove the track's equalizer preset before starting exclusive preview.") }
        } else {
            unknown.append("Track equalizer preset")
        }
        if source == .appleMusic {
            unknown += ["Sound Check", "Sound Enhancer", "Dolby Atmos", "Song transitions"]
        } else {
            unknown += ["Volume normalization", "Automix", "Crossfade", "Lossless selection"]
        }
        knownIssues = issues
        unverifiedControls = unknown
        blockingReason = issues.first
        if !available {
            summary = "Player information is unavailable. Processing and end-to-end sample identity remain unverified."
        } else if !issues.isEmpty {
            summary = "Known player processing is active. \(unknown.count) other controls and end-to-end sample identity remain unverified."
        } else if !primaryFresh {
            summary = "Current playback information is unverified. \(unknown.count) controls and end-to-end sample identity remain unverified."
        } else {
            summary = "No alteration was identified in the readable controls. \(unknown.count) controls and end-to-end sample identity remain unverified."
        }
    }
}
