import XCTest
@testable import FiloCore

final class SourceProcessingTests: XCTestCase {
    func testMissingOrMalformedControlsNeverBecomeSafeDefaults() {
        XCTAssertNil(SourceProcessingState.boolean(nil))
        XCTAssertNil(SourceProcessingState.boolean(""))
        XCTAssertNil(SourceProcessingState.boolean("missing value"))
        XCTAssertNil(SourceProcessingState.boolean("0"))
        XCTAssertEqual(SourceProcessingState.boolean("false"), false)
        XCTAssertEqual(SourceProcessingState.boolean("true"), true)
        XCTAssertNil(SourceProcessingState.integer(nil, in: 0...100))
        XCTAssertNil(SourceProcessingState.integer("", in: 0...100))
        XCTAssertNil(SourceProcessingState.integer("101", in: 0...100))
        XCTAssertNil(SourceProcessingState.integer("-1", in: 0...100))
        XCTAssertEqual(SourceProcessingState.integer("100", in: 0...100), 100)
        XCTAssertEqual(SourceProcessingState.integer("-100", in: -100...100), -100)
    }

    func testTrackTransitionClearsCachedControlsButRetainsApplicationObservation() {
        let now = Date(timeIntervalSince1970: 100)
        let observation = SourceProcessingState(volume: 100, muted: false, equalizerEnabled: false,
                                                observedAt: now, trackID: "A", trackVolumeAdjustment: 0,
                                                trackEqualizerPreset: "", trackObservedAt: now)
        XCTAssertEqual(observation.matching(trackID: "A"), observation)
        for identity in ["B", nil] {
            let next = observation.matching(trackID: identity)
            XCTAssertNil(next.trackID)
            XCTAssertNil(next.trackVolumeAdjustment)
            XCTAssertNil(next.trackEqualizerPreset)
            XCTAssertNil(next.trackObservedAt)
            XCTAssertEqual(next.volume, 100)
            XCTAssertEqual(next.muted, false)
            XCTAssertEqual(next.equalizerEnabled, false)
            XCTAssertEqual(next.observedAt, now)
        }
    }

    func testProcessingEvidencePreservesUnknownAndSupportsOlderHelperMessages() throws {
        let oldMessage = Data(#"{"playing":true,"trackID":"A","volume":100}"#.utf8)
        let oldState = try JSONDecoder().decode(PlayerState.self, from: oldMessage)
        XCTAssertNil(oldState.processing)
        let state = PlayerState(playing: true, trackID: "A", volume: 100,
                                processing: SourceProcessingState(volume: 100, trackID: "A"))
        let decoded = try JSONDecoder().decode(PlayerState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.processing?.volume, 100)
        XCTAssertNil(decoded.processing?.muted)
        XCTAssertNil(decoded.processing?.equalizerEnabled)
        XCTAssertNil(decoded.processing?.trackVolumeAdjustment)
        XCTAssertNil(decoded.processing?.trackEqualizerPreset)
        XCTAssertNil(decoded.processing?.observedAt)
    }

    func testSlowSupplementalResponseCannotAttachPreviousTrackFormatOrControls() {
        let old = PlayerState(playing: true, trackID: "A", volume: 100, localRate: 192000,
                              processing: SourceProcessingState(volume: 100, muted: false,
                                                                trackID: "A", trackVolumeAdjustment: 0))
        let current = PlayerState(playing: true, trackID: "B", volume: 75)
        let merged = current.mergingSupplemental(old)
        XCTAssertEqual(merged.trackID, "B")
        XCTAssertEqual(merged.volume, 75)
        XCTAssertEqual(merged.processing?.volume, 75)
        XCTAssertEqual(merged.processing?.muted, false)
        XCTAssertNil(merged.localRate)
        XCTAssertNil(merged.processing?.trackID)
        XCTAssertNil(merged.processing?.trackVolumeAdjustment)
        let sameTrack = PlayerState(playing: true, trackID: "A").mergingSupplemental(old)
        XCTAssertEqual(sameTrack.localRate, 192000)
        XCTAssertEqual(sameTrack.processing?.trackVolumeAdjustment, 0)
        let failed = PlayerState(error: "Unavailable").mergingSupplemental(old)
        XCTAssertNil(failed.processing)
        XCTAssertNil(failed.localRate)
    }

    func testSlowSupplementalHelperDoesNotDelayEssentialPlaybackState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("mock-player")
        try """
        #!/usr/bin/python3
        import json, sys, time
        for request in sys.stdin:
            if request.strip() == "processing":
                time.sleep(5)
                print(json.dumps({"playing": True, "trackID": "A", "localRate": 192000}), flush=True)
            else:
                print(json.dumps({"playing": True, "trackID": "B", "volume": 100}), flush=True)
        """.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let queue = DispatchQueue(label: "filo.test.player-readback")
        let reader = PlayerReader(queue: queue)
        defer { queue.sync { reader.stop() } }
        let first = expectation(description: "Essential state arrives while supplemental helper is blocked")
        let second = expectation(description: "A second essential request is not queued behind supplemental work")
        var responses = 0
        reader.onState = { state in
            guard state.trackID == "B", state.error == nil else { return }
            responses += 1
            if responses == 1 { first.fulfill() }
            if responses == 2 { second.fulfill() }
        }
        try queue.sync { try reader.start(source: .appleMusic, executable: helper) }
        wait(for: [first], timeout: 2)
        queue.async { reader.request() }
        wait(for: [second], timeout: 2)
    }
}
