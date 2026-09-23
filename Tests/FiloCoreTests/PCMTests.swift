import XCTest
import FiloPCM
@testable import FiloCore

final class PCMTests: XCTestCase {
    func testPCMIntegerRepresentations() {
        // Every 16-bit value and 24-bit boundaries survive the Float32 container.
        for value in Int32(-32768)...Int32(32767) {
            XCTAssertEqual(Int32(Float(value) / 32768 * 32768), value)
        }
        for value: Int32 in [-8388608, -8388607, -65537, -1, 0, 1, 65537, 8388606, 8388607] {
            XCTAssertEqual(Int32(Float(value) / 8388608 * 8388608), value)
        }
    }
    func testSyntheticChannelsAreDistinctAndQuiet() {
        for frame in 0..<1000 {
            XCTAssertLessThanOrEqual(abs(filo_test_sample(UInt64(frame), 0, 24)), 0.001)
        }
        XCTAssertNotEqual(filo_test_sample(100, 0, 24), filo_test_sample(100, 1, 24))
    }
}
