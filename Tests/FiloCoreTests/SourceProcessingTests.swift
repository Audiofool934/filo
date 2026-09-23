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
        XCTAssertNil(oldState.primaryObservedAt)
        let now = Date(timeIntervalSince1970: 100)
        let state = PlayerState(playing: true, trackID: "A", volume: 100,
                                processing: SourceProcessingState(volume: 100, trackID: "A"), primaryObservedAt: now)
        let decoded = try JSONDecoder().decode(PlayerState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.primaryObservedAt, now)
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
        let observation = Date(timeIntervalSince1970: 100)
        let current = PlayerState(playing: true, trackID: "B", volume: 75, primaryObservedAt: observation)
        let merged = current.mergingSupplemental(old)
        XCTAssertEqual(merged.primaryObservedAt, observation)
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

    func testHungPrimaryHelperInvalidatesCachedPlaybackAndDoesNotRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("mock-player")
        try """
        #!/usr/bin/python3
        import json, signal, sys, time
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        count = 0
        for request in sys.stdin:
            if request.strip() == "processing":
                print(json.dumps({"playing": True, "trackID": "OLD", "localRate": 192000}), flush=True)
            else:
                count += 1
                if count == 1:
                    print(json.dumps({"playing": True, "trackID": "CURRENT", "volume": 100,
                                      "primaryObservedAt": time.time() - 978307200}), flush=True)
                else:
                    time.sleep(60)
        """.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let queue = DispatchQueue(label: "filo.test.primary-deadline")
        var deadlines: [DispatchWorkItem] = []
        let reader = PlayerReader(queue: queue, scheduleDeadline: { _, item in deadlines.append(item) })
        defer { queue.sync { reader.stop() } }
        let first = expectation(description: "Initial primary observation")
        let timeout = expectation(description: "Hung essential request invalidates playback")
        var receivedFirst = false
        var receivedTimeout = false
        var stateAfterTimeout: PlayerState?
        reader.onState = { state in
            if receivedTimeout {
                stateAfterTimeout = state
                return
            }
            if state.error?.contains("timed out") == true {
                receivedTimeout = true
                stateAfterTimeout = state
                timeout.fulfill()
            } else if state.trackID == "CURRENT", !receivedFirst {
                receivedFirst = true
                XCTAssertNotNil(state.primaryObservedAt)
                XCTAssertNil(state.localRate)
                first.fulfill()
            }
        }
        try queue.sync { try reader.start(source: .appleMusic, executable: helper) }
        wait(for: [first], timeout: 5)
        // Advance only after a successful response proves the helper is ready.
        queue.sync {
            XCTAssertTrue(receivedFirst)
            XCTAssertEqual(deadlines.count, 1)
            guard receivedFirst, deadlines.count == 1 else { return }
            XCTAssertTrue(deadlines[0].isCancelled)
            reader.request()
            XCTAssertEqual(deadlines.count, 2)
            deadlines[1].perform()
        }
        wait(for: [timeout], timeout: 3)
        // A poll after failure must not restart either helper or restore old metadata.
        queue.sync {
            reader.request()
            XCTAssertFalse(stateAfterTimeout?.playing ?? true)
            XCTAssertNil(stateAfterTimeout?.trackID)
            XCTAssertNil(stateAfterTimeout?.volume)
            XCTAssertNil(stateAfterTimeout?.primaryObservedAt)
            XCTAssertNil(stateAfterTimeout?.processing)
            XCTAssertNil(stateAfterTimeout?.localRate)
            XCTAssertEqual(deadlines.count, 2)
        }
    }

    func testReconnectDiscardsPreviousSourceDeadlineAndPendingReply() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("mock-player")
        try """
        #!/usr/bin/python3
        import json, sys, time
        for request in sys.stdin:
            if sys.argv[-1] == "appleMusic":
                time.sleep(60)
            else:
                print(json.dumps({"playing": True, "trackID": "SPOTIFY", "volume": 100,
                                  "primaryObservedAt": time.time() - 978307200}), flush=True)
        """.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let queue = DispatchQueue(label: "filo.test.source-generation")
        var deadlines: [DispatchWorkItem] = []
        let reader = PlayerReader(queue: queue, scheduleDeadline: { _, item in deadlines.append(item) })
        defer { queue.sync { reader.stop() } }
        let current = expectation(description: "New source response")
        var latest: PlayerState?
        var received = false
        reader.onState = { state in
            latest = state
            if !received, state.trackID == "SPOTIFY" { received = true; current.fulfill() }
        }
        try queue.sync {
            try reader.start(source: .appleMusic, executable: helper)
            try reader.start(source: .spotify, executable: helper)
        }
        wait(for: [current], timeout: 5)
        queue.sync {
            XCTAssertEqual(deadlines.count, 2)
            guard deadlines.count == 2 else { return }
            XCTAssertTrue(deadlines[0].isCancelled)
            XCTAssertTrue(deadlines[1].isCancelled)
            // A previous source's scheduled item cannot invalidate the ready source.
            deadlines[0].perform()
            deadlines[1].perform()
            XCTAssertEqual(latest?.trackID, "SPOTIFY")
            XCTAssertNil(latest?.error)
        }
    }
}
