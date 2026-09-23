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
        XCTAssertNil(policy.observe(SourceFormat(rate: 48000, evidence: .decoder, observedAt: now.addingTimeInterval(-1)), now: now))
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
}
