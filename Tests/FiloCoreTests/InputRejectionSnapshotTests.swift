import Foundation
import FiloPCM
import XCTest
@testable import FiloCore

final class InputRejectionSnapshotTests: XCTestCase {
    func testNonfiniteBitPayloadRemainsJSONEncodableWithoutFloatConversion() throws {
        var metadata = FiloBridgeRejection()
        metadata.available = true
        metadata.callbackFrames = 1
        metadata.firstRejectedChannel = 1
        metadata.rejectedSampleBits = 0x7fc01234
        metadata.capturedFrames = 1
        metadata.sourceBits = 24
        metadata.outputBits = 32
        let snapshot = InputRejectionSnapshot(metadata, sampleBits: [0x80000000, 0x7fc01234])
        let data = try JSONEncoder().encode(snapshot)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["capturedSampleBits"] as? [UInt32], [0x80000000, 0x7fc01234])
        XCTAssertEqual(object["rejectedSampleBits"] as? UInt32, 0x7fc01234)
        XCTAssertEqual(object["finite"] as? Bool, false)
        XCTAssertEqual(object["sourceRepresentable"] as? Bool, false)
    }

    func testUnassertedSourcePrecisionIsAbsentRatherThanFailed() throws {
        var metadata = FiloBridgeRejection()
        metadata.available = true
        metadata.callbackFrames = 1
        metadata.capturedFrames = 1
        metadata.sourceBits = 0
        metadata.outputBits = 16
        metadata.finite = true
        metadata.rejectedSampleBits = Float(1.0 / 65536).bitPattern
        let snapshot = InputRejectionSnapshot(metadata, sampleBits: [metadata.rejectedSampleBits, 0])
        let data = try JSONEncoder().encode(snapshot)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["sourceRepresentable"])
        XCTAssertEqual(object["outputRepresentable"] as? Bool, false)
        XCTAssertEqual(object["sourceBits"] as? UInt32, 0)
    }
}
