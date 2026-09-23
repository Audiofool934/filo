import XCTest
@testable import FiloCore

final class ExclusivePlaybackPolicyTests: XCTestCase {
    func testExplicitRateArmsBeforePlayAndPreservesOpeningAcrossMetadataArrival() {
        let idle = PlayerState()
        let firstTrack = PlayerState(playing: true, trackID: "first")
        let nextTrack = PlayerState(playing: true, trackID: "next")
        let paused = PlayerState(playing: false, trackID: "first")
        let unavailable = PlayerState(error: "Reader unavailable")
        for evidence in [FormatEvidence.manual, .spotifyPolicy] {
            let format = SourceFormat(rate: 44100, evidence: evidence)
            XCTAssertTrue(ExclusivePlaybackPolicy.canArm(format: format, state: idle, processesAvailable: true))
            XCTAssertTrue(ExclusivePlaybackPolicy.canArm(format: format, state: paused, processesAvailable: true))
            XCTAssertFalse(ExclusivePlaybackPolicy.canArm(format: format, state: idle, processesAvailable: false))
            XCTAssertFalse(ExclusivePlaybackPolicy.canArm(format: format, state: unavailable, processesAvailable: true))
            XCTAssertFalse(ExclusivePlaybackPolicy.requiresRearm(previous: idle, current: firstTrack, format: format))
            XCTAssertFalse(ExclusivePlaybackPolicy.requiresRearm(previous: firstTrack, current: nextTrack, format: format))
            XCTAssertTrue(ExclusivePlaybackPolicy.requiresRearm(previous: firstTrack, current: paused, format: format))
            XCTAssertFalse(ExclusivePlaybackPolicy.requiresRearm(previous: paused, current: paused, format: format))
            XCTAssertFalse(ExclusivePlaybackPolicy.requiresRearm(previous: paused, current: firstTrack, format: format))
            XCTAssertTrue(ExclusivePlaybackPolicy.requiresRearm(previous: firstTrack, current: unavailable, format: format))
        }
        let automatic = SourceFormat(rate: 44100, evidence: .decoder)
        XCTAssertFalse(ExclusivePlaybackPolicy.canArm(format: nil, state: firstTrack, processesAvailable: true))
        XCTAssertFalse(ExclusivePlaybackPolicy.canArm(format: automatic, state: idle, processesAvailable: true))
        XCTAssertFalse(ExclusivePlaybackPolicy.canArm(format: automatic, state: PlayerState(playing: true), processesAvailable: true))
        XCTAssertTrue(ExclusivePlaybackPolicy.canArm(format: automatic, state: firstTrack, processesAvailable: true))
        XCTAssertTrue(ExclusivePlaybackPolicy.requiresRearm(previous: firstTrack, current: nextTrack, format: automatic))
    }
}
