import XCTest
@testable import FiloCore

final class PolicyTests: XCTestCase {
    func testDecoderParserRejectsHardwareOutputAndPrivateContent() {
        let valid = "ACAppleLosslessDecoder.cpp:680 (0x123) Input format:  2 ch,  192000 Hz, alac (0x00000003) from 24-bit source, 4096 frames/packet"
        XCTAssertEqual(DecoderFormatParser.parse(valid)?.rate, 192000)
        XCTAssertEqual(DecoderFormatParser.parse(valid)?.bits, 24)
        XCTAssertNil(DecoderFormatParser.parse(valid.replacingOccurrences(of: "Input format:", with: "Output format:")))
        XCTAssertNil(DecoderFormatParser.parse("device sample rate = 192000 Hz"))
        XCTAssertNil(DecoderFormatParser.parse(valid.replacingOccurrences(of: "192000", with: "<private>")))
        XCTAssertNil(DecoderFormatParser.parse(valid.replacingOccurrences(of: "2 ch", with: "6 ch")))
    }
    func testRateCanGoDownOnNaturalTrackTransition() {
        var policy = FormatPolicy()
        let now = Date()
        policy.trackChanged(id: "A", playing: true, now: now)
        XCTAssertEqual(policy.observe(SourceFormat(rate: 192000, evidence: .decoder, observedAt: now), now: now)?.rate, 192000)
        policy.trackChanged(id: "B", playing: true, now: now.addingTimeInterval(60))
        XCTAssertNil(policy.current)
        let event = SourceFormat(rate: 44100, evidence: .decoder, observedAt: now.addingTimeInterval(60.1))
        XCTAssertEqual(policy.observe(event, now: now.addingTimeInterval(60.2))?.rate, 44100)
    }
    func testRejectsStaleFuturePausedAndPrefetchedEvents() {
        var policy = FormatPolicy()
        let now = Date()
        policy.trackChanged(id: "A", playing: true, now: now)
        XCTAssertNil(policy.observe(SourceFormat(rate: 48000, evidence: .decoder, observedAt: now.addingTimeInterval(-2.1)), now: now))
        XCTAssertNil(policy.observe(SourceFormat(rate: 48000, evidence: .decoder, observedAt: now.addingTimeInterval(10)), now: now))
        XCTAssertNil(policy.observe(SourceFormat(rate: 48000, evidence: .decoder, observedAt: now.addingTimeInterval(30)), now: now.addingTimeInterval(30)))
        policy.trackChanged(id: "A", playing: false, now: now)
        XCTAssertNil(policy.observe(SourceFormat(rate: 48000, evidence: .decoder, observedAt: now), now: now))
    }
    func testConflictingDecoderEventsRemoveConfidence() {
        var policy = FormatPolicy()
        let now = Date()
        policy.trackChanged(id: "A", playing: true, now: now)
        XCTAssertNotNil(policy.observe(SourceFormat(rate: 44100, evidence: .decoder, observedAt: now), now: now))
        XCTAssertNil(policy.observe(SourceFormat(rate: 192000, evidence: .decoder, observedAt: now), now: now))
        XCTAssertNil(policy.current)
    }
    func testDecoderCanPrecedeTrackNotificationButNotByAnOldTrackDuration() {
        var policy = FormatPolicy()
        let now = Date()
        XCTAssertNil(policy.observe(SourceFormat(rate: 96000, evidence: .decoder, observedAt: now), now: now))
        policy.trackChanged(id: "A", playing: true, now: now.addingTimeInterval(0.2))
        XCTAssertEqual(policy.current?.rate, 96000)
        policy.trackChanged(id: "B", playing: true, now: now.addingTimeInterval(30))
        XCTAssertNil(policy.current)
    }
    func testResumeUnknownOpensANewDetectionWindow() {
        var policy = FormatPolicy()
        let now = Date()
        policy.trackChanged(id: "A", playing: false, now: now)
        policy.trackChanged(id: "A", playing: true, now: now.addingTimeInterval(60))
        let event = SourceFormat(rate: 48000, evidence: .decoder, observedAt: now.addingTimeInterval(60.1))
        XCTAssertEqual(policy.observe(event, now: now.addingTimeInterval(60.2))?.rate, 48000)
    }
    func testRapidSkipDoesNotReuseDecoderAlreadyAssignedToPreviousTrack() {
        let now = Date(timeIntervalSince1970: 100)
        var policy = FormatPolicy()
        policy.trackChanged(id: "A", playing: true, now: now)
        XCTAssertNotNil(policy.observe(SourceFormat(rate: 192000, evidence: .decoder, observedAt: now), now: now))
        policy.trackChanged(id: "B", playing: true, now: now.addingTimeInterval(0.5))
        XCTAssertNil(policy.current)
        let next = SourceFormat(rate: 44100, evidence: .decoder, observedAt: now.addingTimeInterval(0.6))
        XCTAssertEqual(policy.observe(next, now: next.observedAt)?.rate, 44100)
    }

    func testAmbiguousWindowDoesNotRecoverOnlyBecauseOldEventExpired() {
        let now = Date(timeIntervalSince1970: 100)
        var policy = FormatPolicy()
        policy.trackChanged(id: "A", playing: true, now: now)
        for (seconds, rate) in [(0.0, 44100.0), (1.0, 192000.0), (4.0, 192000.0)] {
            let event = SourceFormat(rate: rate, evidence: .decoder, observedAt: now.addingTimeInterval(seconds))
            _ = policy.observe(event, now: event.observedAt)
        }
        XCTAssertNil(policy.current)
        policy.trackChanged(id: "B", playing: true, now: now.addingTimeInterval(10))
        XCTAssertNil(policy.current)
        let next = SourceFormat(rate: 48000, evidence: .decoder, observedAt: now.addingTimeInterval(10.1))
        XCTAssertEqual(policy.observe(next, now: next.observedAt)?.rate, 48000)
    }

    func testLocalFileEvidenceCannotBeOverwrittenByUnattributedDecoder() {
        let now = Date(timeIntervalSince1970: 100)
        var policy = FormatPolicy()
        policy.trackChanged(id: "A", playing: true, now: now)
        let local = SourceFormat(rate: 44100, evidence: .localFile, observedAt: now)
        policy.useLocal(local)
        let decoder = SourceFormat(rate: 192000, evidence: .decoder, observedAt: now.addingTimeInterval(1))
        XCTAssertNil(policy.observe(decoder, now: decoder.observedAt))
        XCTAssertEqual(policy.current, local)
    }

    func testPretransitionObservationIsConsumedOnlyOnce() {
        let now = Date(timeIntervalSince1970: 100)
        var policy = FormatPolicy()
        let format = SourceFormat(rate: 96000, evidence: .decoder, observedAt: now)
        XCTAssertNil(policy.observe(format, now: now))
        policy.trackChanged(id: "A", playing: true, now: now.addingTimeInterval(0.2))
        XCTAssertEqual(policy.current?.rate, 96000)
        policy.trackChanged(id: "B", playing: true, now: now.addingTimeInterval(0.4))
        XCTAssertNil(policy.current)
    }

    func testLatePrefetchIsDeferredUntilNextTrackAndKnownPauseKeepsCurrent() {
        let now = Date(timeIntervalSince1970: 100)
        var policy = FormatPolicy()
        policy.trackChanged(id: "A", playing: true, now: now)
        let first = SourceFormat(rate: 192000, evidence: .decoder, observedAt: now)
        XCTAssertNotNil(policy.observe(first, now: now))
        let prefetch = SourceFormat(rate: 44100, evidence: .decoder, observedAt: now.addingTimeInterval(30))
        XCTAssertNil(policy.observe(prefetch, now: prefetch.observedAt))
        XCTAssertEqual(policy.current?.rate, 192000)
        policy.trackChanged(id: "B", playing: true, now: now.addingTimeInterval(30.2))
        XCTAssertEqual(policy.current?.rate, 44100)
        policy.trackChanged(id: "B", playing: false, now: now.addingTimeInterval(40))
        policy.trackChanged(id: "B", playing: true, now: now.addingTimeInterval(60))
        XCTAssertEqual(policy.current?.rate, 44100)
    }

    func testDifferentRateBeforeRapidTrackNotificationRemainsOnlyACandidate() {
        let now = Date(timeIntervalSince1970: 100)
        var policy = FormatPolicy()
        policy.trackChanged(id: "A", playing: true, now: now)
        let first = SourceFormat(rate: 192000, evidence: .decoder, observedAt: now)
        XCTAssertNotNil(policy.observe(first, now: now))
        let next = SourceFormat(rate: 44100, evidence: .decoder, observedAt: now.addingTimeInterval(0.4))
        XCTAssertNil(policy.observe(next, now: next.observedAt))
        XCTAssertNil(policy.current)
        policy.trackChanged(id: "B", playing: true, now: now.addingTimeInterval(0.6))
        XCTAssertEqual(policy.current?.rate, 44100)
        policy.trackChanged(id: "C", playing: true, now: now.addingTimeInterval(0.8))
        XCTAssertNil(policy.current)
    }

    func testSeveralUnassignedRatesCannotChooseNextTrackFormat() {
        let now = Date(timeIntervalSince1970: 100)
        var policy = FormatPolicy()
        policy.trackChanged(id: "A", playing: true, now: now)
        for (seconds, rate) in [(0.0, 192000.0), (0.4, 44100.0), (0.5, 48000.0)] {
            let event = SourceFormat(rate: rate, evidence: .decoder, observedAt: now.addingTimeInterval(seconds))
            _ = policy.observe(event, now: event.observedAt)
        }
        policy.trackChanged(id: "B", playing: true, now: now.addingTimeInterval(0.6))
        XCTAssertNil(policy.current)
    }

    func testPlaybackObservationTimeDoesNotTreatPendingDecoderAsFuture() {
        let now = Date(timeIntervalSince1970: 100)
        var policy = FormatPolicy()
        let event = SourceFormat(rate: 96000, evidence: .decoder, observedAt: now.addingTimeInterval(0.5))
        XCTAssertNil(policy.observe(event, now: event.observedAt))
        policy.trackChanged(id: "A", playing: true, now: now.addingTimeInterval(1), observedAt: now)
        XCTAssertEqual(policy.trackStarted, now)
        XCTAssertEqual(policy.current?.rate, 96000)
        for invalid in [now.addingTimeInterval(-4), now.addingTimeInterval(1), Date(timeIntervalSince1970: .nan)] {
            var fallback = FormatPolicy()
            fallback.trackChanged(id: "A", playing: true, now: now, observedAt: invalid)
            XCTAssertEqual(fallback.trackStarted, now)
        }
    }

    func testDelayedPretransitionDecoderCanMatchButAssignedReplayCannot() {
        let now = Date(timeIntervalSince1970: 100)
        var policy = FormatPolicy()
        policy.trackChanged(id: "A", playing: true, now: now)
        let first = SourceFormat(rate: 192000, evidence: .decoder, observedAt: now)
        XCTAssertNotNil(policy.observe(first, now: now))
        policy.trackChanged(id: "B", playing: true, now: now.addingTimeInterval(1))
        XCTAssertNil(policy.observe(first, now: now.addingTimeInterval(1.1)))
        XCTAssertNil(policy.current)
        let next = SourceFormat(rate: 44100, evidence: .decoder, observedAt: now.addingTimeInterval(0.8))
        XCTAssertEqual(policy.observe(next, now: now.addingTimeInterval(1.2))?.rate, 44100)
        policy.trackChanged(id: "C", playing: true, now: now.addingTimeInterval(1.3))
        XCTAssertNil(policy.observe(next, now: now.addingTimeInterval(1.4)))
        XCTAssertNil(policy.current)
    }

    func testDiagnosticFloodCannotMakeEvictedAssignedEventReusable() {
        let now = Date(timeIntervalSince1970: 100)
        var policy = FormatPolicy()
        policy.trackChanged(id: "A", playing: true, now: now)
        let first = SourceFormat(rate: 44100, evidence: .decoder, observedAt: now)
        for index in 0..<300 {
            let event = SourceFormat(rate: 44100, evidence: .decoder, observedAt: now.addingTimeInterval(Double(index) / 1000))
            XCTAssertNotNil(policy.observe(event, now: event.observedAt))
        }
        policy.trackChanged(id: "B", playing: true, now: now.addingTimeInterval(1))
        XCTAssertNil(policy.observe(first, now: now.addingTimeInterval(1.1)))
        XCTAssertNil(policy.current)
    }

}
