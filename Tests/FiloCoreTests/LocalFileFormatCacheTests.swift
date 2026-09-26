import XCTest
@testable import FiloCore

final class LocalFileFormatCacheTests: XCTestCase {
    func testTransientFailureRetriesAndRecoversWithoutChangingTrack() {
        let now = Date(timeIntervalSince1970: 100)
        var cache = LocalFileFormatCache()
        XCTAssertTrue(cache.shouldRead(trackID: "A", now: now))
        // A missing location or file-open failure records no rate.
        XCTAssertNil(cache.rate)
        XCTAssertFalse(cache.shouldRead(trackID: "A", now: now.addingTimeInterval(4.9)))
        if cache.shouldRead(trackID: "A", now: now.addingTimeInterval(5)) {
            cache.record(rate: 96000, trackID: "A")
        } else {
            XCTFail("A failed header probe must not remain cached for the entire track")
        }
        XCTAssertEqual(cache.rate, 96000)
    }

    func testSuccessfulHeaderIsCachedForSameTrack() {
        let now = Date(timeIntervalSince1970: 100)
        var cache = LocalFileFormatCache()
        XCTAssertTrue(cache.shouldRead(trackID: "A", now: now))
        cache.record(rate: 44100, trackID: "A")
        for seconds in [0.1, 5, 60, 600] {
            XCTAssertFalse(cache.shouldRead(trackID: "A", now: now.addingTimeInterval(seconds)))
            XCTAssertEqual(cache.rate, 44100)
        }
    }

    func testNewTrackInvalidatesCacheAndRejectsOldTrackResult() {
        let now = Date(timeIntervalSince1970: 100)
        var cache = LocalFileFormatCache()
        XCTAssertTrue(cache.shouldRead(trackID: "A", now: now))
        cache.record(rate: 192000, trackID: "A")
        XCTAssertTrue(cache.shouldRead(trackID: "B", now: now.addingTimeInterval(0.5)))
        XCTAssertNil(cache.rate)
        cache.record(rate: 192000, trackID: "A")
        XCTAssertNil(cache.rate)
        cache.record(rate: 48000, trackID: "B")
        XCTAssertEqual(cache.rate, 48000)
        XCTAssertFalse(cache.shouldRead(trackID: nil, now: now.addingTimeInterval(1)))
        XCTAssertNil(cache.rate)
        XCTAssertNil(cache.trackID)
    }

    func testFileAttemptsLeaveFollowingPollsForOptionalProcessing() {
        let now = Date(timeIntervalSince1970: 100)
        var cache = LocalFileFormatCache()
        // The helper devotes a true result to the file lookup, and a false result to DSP reads.
        XCTAssertTrue(cache.shouldRead(trackID: "A", now: now))
        for seconds in [0.5, 1, 2, 4.9] {
            XCTAssertFalse(cache.shouldRead(trackID: "A", now: now.addingTimeInterval(seconds)))
        }
        XCTAssertTrue(cache.shouldRead(trackID: "A", now: now.addingTimeInterval(5)))
        XCTAssertFalse(cache.shouldRead(trackID: "A", now: now.addingTimeInterval(5.5)))
        XCTAssertTrue(cache.shouldRead(trackID: "A", now: now.addingTimeInterval(10)))
    }
}
