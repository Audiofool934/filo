import XCTest
@testable import FiloCore

final class SourceProcessingAssessmentTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 100)
    private func cleanState() -> PlayerState {
        PlayerState(playing: true, trackID: "A", volume: 100,
            processing: SourceProcessingState(volume: 100, muted: false, equalizerEnabled: false,
                observedAt: now, trackID: "A", trackVolumeAdjustment: 0,
                trackEqualizerPreset: "", trackObservedAt: now), primaryObservedAt: now)
    }

    func testKnownFreshProcessingBlocksAndPrimaryVolumeTakesPrecedence() {
        var state = cleanState()
        state.volume = 80
        state.processing?.volume = 100
        XCTAssertNotNil(SourceProcessingAssessment(state: state, source: .appleMusic, now: now).blockingReason)
        state.volume = 100
        state.processing?.volume = 80
        XCTAssertNil(SourceProcessingAssessment(state: state, source: .appleMusic, now: now).blockingReason)
        state.processing?.muted = true
        state.processing?.equalizerEnabled = true
        state.processing?.trackVolumeAdjustment = -10
        state.processing?.trackEqualizerPreset = "Flat"
        let result = SourceProcessingAssessment(state: state, source: .appleMusic, now: now)
        XCTAssertEqual(result.knownIssues.count, 4)
        XCTAssertNotNil(result.blockingReason)
    }

    func testUnknownStaleAndFutureControlsRemainUnverified() {
        for offset in [-4.0, 0.001] {
            var state = cleanState()
            state.processing?.muted = true
            state.processing?.equalizerEnabled = true
            state.processing?.observedAt = now.addingTimeInterval(offset)
            let result = SourceProcessingAssessment(state: state, source: .appleMusic, now: now)
            XCTAssertNil(result.blockingReason)
            XCTAssertTrue(result.unverifiedControls.contains("Application mute"))
            XCTAssertTrue(result.unverifiedControls.contains("Application equalizer"))
        }
        let unknown = SourceProcessingAssessment(state: PlayerState(), source: .spotify, now: now)
        XCTAssertNil(unknown.blockingReason)
        XCTAssertTrue(unknown.unverifiedControls.contains("Application volume"))
        XCTAssertTrue(unknown.unverifiedControls.contains("Application mute"))
        XCTAssertTrue(unknown.unverifiedControls.contains("Application equalizer"))
    }

    func testStaleUnknownAndFuturePrimaryVolumeAndIdentityAreUnverified() {
        for volume in [0, 100] {
            for observation in [nil, now.addingTimeInterval(-3.001), now.addingTimeInterval(0.001)] {
                var state = cleanState()
                state.volume = volume
                state.primaryObservedAt = observation
                // A fresh optional response cannot refresh the primary volume or track identity.
                state.processing?.trackVolumeAdjustment = 10
                let result = SourceProcessingAssessment(state: state, source: .appleMusic, now: now)
                XCTAssertNil(result.blockingReason)
                XCTAssertTrue(result.unverifiedControls.contains("Application volume"))
                XCTAssertTrue(result.unverifiedControls.contains("Track volume adjustment"))
                XCTAssertTrue(result.unverifiedControls.contains("Track equalizer preset"))
                XCTAssertTrue(result.summary.contains("Current playback information is unverified"))
            }
        }
        var state = cleanState()
        state.primaryObservedAt = now.addingTimeInterval(-3)
        state.volume = 0
        XCTAssertNotNil(SourceProcessingAssessment(state: state, source: .appleMusic, now: now).blockingReason)
    }

    func testTrackModifiersRequireMatchingIdentityAndFreshObservation() {
        for offset in [-7.001, 0.001] {
            var state = cleanState()
            state.processing?.trackVolumeAdjustment = 20
            state.processing?.trackEqualizerPreset = "Rock"
            state.processing?.trackObservedAt = now.addingTimeInterval(offset)
            let result = SourceProcessingAssessment(state: state, source: .appleMusic, now: now)
            XCTAssertNil(result.blockingReason)
            XCTAssertTrue(result.unverifiedControls.contains("Track volume adjustment"))
            XCTAssertTrue(result.unverifiedControls.contains("Track equalizer preset"))
        }
        var state = cleanState()
        state.processing?.trackVolumeAdjustment = 20
        state.processing?.trackID = "B"
        XCTAssertNil(SourceProcessingAssessment(state: state, source: .appleMusic, now: now).blockingReason)
        state.processing?.trackID = nil
        state.trackID = nil
        XCTAssertNil(SourceProcessingAssessment(state: state, source: .appleMusic, now: now).blockingReason)
    }

    func testFreshnessIncludesExactBoundaryAndNeverPromotesAllReadableControlsToVerified() throws {
        var state = cleanState()
        state.processing?.observedAt = now.addingTimeInterval(-3)
        state.processing?.trackObservedAt = now.addingTimeInterval(-7)
        let clear = SourceProcessingAssessment(state: state, source: .appleMusic, now: now)
        XCTAssertNil(clear.blockingReason)
        XCTAssertEqual(clear.unverifiedControls, ["Sound Check", "Sound Enhancer", "Dolby Atmos", "Song transitions"])
        XCTAssertTrue(clear.summary.contains("remain unverified"))
        state.processing?.muted = true
        state.processing?.trackVolumeAdjustment = 10
        XCTAssertEqual(SourceProcessingAssessment(state: state, source: .appleMusic, now: now).knownIssues.count, 2)
        _ = try JSONEncoder().encode(clear)
    }

    func testPlayerErrorAndInvalidValuesCannotCreateTrustedProcessingObservations() {
        var state = cleanState()
        state.volume = 20
        state.processing?.muted = true
        state.error = "Reader stopped"
        let unavailable = SourceProcessingAssessment(state: state, source: .appleMusic, now: now)
        XCTAssertNil(unavailable.blockingReason)
        XCTAssertTrue(unavailable.summary.contains("unavailable"))
        state = cleanState()
        state.volume = 101
        state.processing?.trackVolumeAdjustment = -101
        let malformed = SourceProcessingAssessment(state: state, source: .appleMusic, now: now)
        XCTAssertNil(malformed.blockingReason)
        XCTAssertTrue(malformed.unverifiedControls.contains("Application volume"))
        XCTAssertTrue(malformed.unverifiedControls.contains("Track volume adjustment"))
    }
}
