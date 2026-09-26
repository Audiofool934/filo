import XCTest
@testable import FiloCore

final class DecoderEventParserTests: XCTestCase {
    private let message = "ACAppleLosslessDecoder.cpp:680 (0x123) Input format:  2 ch,  192000 Hz, alac (0x00000003) from 24-bit source, 4096 frames/packet"

    private func event(timestamp: Any?, message: String? = nil) throws -> Data {
        var fields: [String: Any] = ["eventMessage": message ?? self.message]
        if let timestamp { fields["timestamp"] = timestamp }
        return try JSONSerialization.data(withJSONObject: fields)
    }

    func testUsesActualLogStreamTimestampShapeAndEquivalentTimezones() throws {
        // Shape observed from this host's log stream --style ndjson using our own OSLog probe.
        let local = try XCTUnwrap(DecoderEventParser.parse(event(timestamp: "2026-09-26 15:19:51.641979+0800")))
        let utc = try XCTUnwrap(DecoderEventParser.parse(event(timestamp: "2026-09-26T07:19:51.641979Z")))
        let colonOffset = try XCTUnwrap(DecoderEventParser.parse(event(timestamp: "2026-09-26T15:19:51.641979+08:00")))
        XCTAssertEqual(local, utc)
        XCTAssertEqual(local, colonOffset)
        XCTAssertEqual(local.rate, 192000)
        XCTAssertEqual(local.bits, 24)
        XCTAssertEqual(local.observedAt.timeIntervalSince1970, 1790407191.641979, accuracy: 0.001)
    }

    func testMalformedOrMissingTimestampNeverBecomesFreshReceiptTime() throws {
        let invalid: [Any?] = [nil, 1790407191.0, "", "not a timestamp", "2026-09-26 15:19:51"]
        for timestamp in invalid {
            XCTAssertNil(DecoderEventParser.parse(try event(timestamp: timestamp)))
        }
        XCTAssertNil(DecoderEventParser.parse(Data("not json".utf8)))
        XCTAssertNil(DecoderEventParser.parse(try event(timestamp: "2026-09-26T07:19:51Z", message: "device sample rate = 192000 Hz")))
    }

    func testDelayedDecoderEventCannotSetNewTrackRate() throws {
        let event = try XCTUnwrap(DecoderEventParser.parse(event(timestamp: "2026-09-26 15:19:51.641979+0800")))
        let receivedAt = event.observedAt.addingTimeInterval(30)
        var policy = FormatPolicy()
        policy.trackChanged(id: "new track", playing: true, now: receivedAt)
        XCTAssertNil(policy.observe(event, now: receivedAt))
        XCTAssertNil(policy.current)
    }
}
