import XCTest
import CoreAudio
@testable import FiloCore

final class OutputByteVerificationTests: XCTestCase {
    private struct Fixture {
        let reference: ReferencePCM
        let integers: [Int32]
    }

    private func fixture(bits: Int = 24, frames: Int = 96) -> Fixture {
        let scale = Int32(1 << (bits - 1))
        var values: [Int32] = [-scale, scale - 1, -1, 0, 1, scale / 2, -scale / 2, 0x1234]
        for index in values.count..<(frames * 2) {
            values.append(Int32((index * 7919) % Int(scale)) - scale / 2)
        }
        let samples = values.map { Float($0) / Float(scale) }
        let reference = ReferencePCM(samples: samples, sampleRate: 48_000, bits: bits,
                                     fileSHA256: "test-reference", sourceFormat: "integer PCM")
        return Fixture(reference: reference, integers: values)
    }

    private func format(bits: UInt32, wordBytes: UInt32, high: Bool = false) -> AudioStreamBasicDescription {
        var flags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsNonMixable
        if bits == wordBytes * 8 { flags |= kAudioFormatFlagIsPacked }
        if high { flags |= kAudioFormatFlagIsAlignedHigh }
        return AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: flags, mBytesPerPacket: wordBytes * 2, mFramesPerPacket: 1,
            mBytesPerFrame: wordBytes * 2, mChannelsPerFrame: 2, mBitsPerChannel: bits, mReserved: 0)
    }

    /// Fixtures originate as signed integer words, not from the serializer or its Float conversion.
    private func bytes(_ fixture: Fixture, validBits: Int, wordBytes: Int, high: Bool = false) -> Data {
        var result = Data()
        for value in fixture.integers {
            let widened = Int64(value) * Int64(1 << (validBits - fixture.reference.bits))
            let payload = UInt64(bitPattern: widened) & ((UInt64(1) << validBits) - 1)
            var storage = UInt32(payload << (high ? wordBytes * 8 - validBits : 0)).littleEndian
            withUnsafeBytes(of: &storage) { result.append(contentsOf: $0.prefix(wordBytes)) }
        }
        return result
    }

    func testExactIntegerWideningAndPackedHighLowAlignedWordsPass() throws {
        let cases: [(source: Int, valid: Int, bytes: Int, high: Bool, firstWords: [UInt8])] = [
            (16, 16, 2, false, [0x00, 0x80, 0xff, 0x7f]),
            (24, 24, 3, false, [0x00, 0x00, 0x80, 0xff, 0xff, 0x7f]),
            (16, 32, 4, false, [0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0xff, 0x7f]),
            (24, 32, 4, false, [0x00, 0x00, 0x00, 0x80, 0x00, 0xff, 0xff, 0x7f]),
            (24, 24, 4, true, [0x00, 0x00, 0x00, 0x80, 0x00, 0xff, 0xff, 0x7f]),
            (24, 24, 4, false, [0x00, 0x00, 0x80, 0x00, 0xff, 0xff, 0x7f, 0x00]),
            (16, 16, 4, true, [0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0xff, 0x7f]),
            (16, 16, 4, false, [0x00, 0x80, 0x00, 0x00, 0xff, 0x7f, 0x00, 0x00])
        ]
        for item in cases {
            let fixture = fixture(bits: item.source)
            let payload = bytes(fixture, validBits: item.valid, wordBytes: item.bytes, high: item.high)
            XCTAssertEqual(Array(payload.prefix(item.firstWords.count)), item.firstWords)
            let result = OutputByteVerification.compare(capture: payload,
                format: format(bits: UInt32(item.valid), wordBytes: UInt32(item.bytes), high: item.high),
                reference: fixture.reference)
            XCTAssertTrue(result.passed, result.failureReason ?? "")
            XCTAssertTrue(result.exactReferencePrecision)
            XCTAssertEqual(result.comparedFrames, fixture.reference.frameCount)
            XCTAssertEqual(result.mismatchedBytes, 0)
            XCTAssertEqual(result.actualCaptureSHA256, result.expectedReferenceSHA256)
            XCTAssertEqual(result.actualAlignedSHA256, result.expectedAlignedSHA256)
            XCTAssertEqual(result.actualCaptureSHA256.count, 64)
            _ = try JSONEncoder().encode(result)
        }
    }

    func testOnePaddingBitFailsEvenWhenDecodedSamplesAreExactlyEqual() {
        for high in [false, true] {
            let fixture = fixture()
            var capture = bytes(fixture, validBits: 24, wordBytes: 4, high: high)
            let paddingOffset = high ? 0 : 3
            capture[paddingOffset] ^= 1
            let result = OutputByteVerification.compare(capture: capture,
                format: format(bits: 24, wordBytes: 4, high: high), reference: fixture.reference)
            XCTAssertTrue(result.sampleComparison?.fullReferenceExact == true)
            XCTAssertFalse(result.passed)
            XCTAssertEqual(result.mismatchedBytes, 1)
            XCTAssertEqual(result.mismatchedSampleWords, 1)
            XCTAssertEqual(result.mismatchedFrames, 1)
            XCTAssertEqual(result.nonzeroPaddingBytes, 1)
            XCTAssertEqual(result.firstMismatchedByte, paddingOffset)
            XCTAssertEqual(result.firstMismatchedFrame, 0)
            XCTAssertNotEqual(result.actualAlignedSHA256, result.expectedAlignedSHA256)
        }
    }

    func testLow32BitCorruptionCannotHideBehindFloat32Rounding() {
        let fixture = fixture()
        var capture = bytes(fixture, validBits: 32, wordBytes: 4)
        capture[0] ^= 1
        let result = OutputByteVerification.compare(capture: capture,
            format: format(bits: 32, wordBytes: 4), reference: fixture.reference)
        XCTAssertTrue(result.sampleComparison?.fullReferenceExact == true)
        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.mismatchedBytes, 1)
        XCTAssertEqual(result.nonzeroPaddingBytes, 0)
    }

    func testOnlySilentCompletePrefixAndTailAreAccepted() {
        let fixture = fixture()
        let format = format(bits: 24, wordBytes: 4)
        let payload = bytes(fixture, validBits: 24, wordBytes: 4)
        let capture = Data(repeating: 0, count: 5 * 8) + payload + Data(repeating: 0, count: 7 * 8)
        let good = OutputByteVerification.compare(capture: capture, format: format, reference: fixture.reference)
        XCTAssertTrue(good.passed)
        XCTAssertEqual(good.sampleComparison?.leadingCaptureFrames, 5)
        XCTAssertEqual(good.sampleComparison?.trailingCaptureFrames, 7)
        XCTAssertEqual(good.actualAlignedSHA256, good.expectedReferenceSHA256)
        XCTAssertNotEqual(good.actualCaptureSHA256, good.actualAlignedSHA256)
        var noncanonicalTail = capture
        noncanonicalTail[noncanonicalTail.count - 1] = 1
        let bad = OutputByteVerification.compare(capture: noncanonicalTail, format: format, reference: fixture.reference)
        XCTAssertTrue(bad.sampleComparison?.fullReferenceExact == true)
        XCTAssertFalse(bad.passed)
        XCTAssertEqual(bad.nonzeroTrailingBytes, 1)
        XCTAssertEqual(bad.nonzeroPaddingBytes, 1)

        let missingFirst = OutputByteVerification.compare(capture: Data(payload.dropFirst(8)), format: format,
                                                          reference: fixture.reference)
        XCTAssertFalse(missingFirst.passed)
        XCTAssertEqual(missingFirst.sampleComparison?.missingPrefixFrames, 1)
        let missingLast = OutputByteVerification.compare(capture: Data(payload.dropLast(8)), format: format,
                                                         reference: fixture.reference)
        XCTAssertFalse(missingLast.passed)
        XCTAssertEqual(missingLast.sampleComparison?.missingSuffixFrames, 1)
    }

    func testWrongEndianMalformedBytesAndRateMismatchCannotPass() throws {
        let fixture = fixture()
        let payload = bytes(fixture, validBits: 24, wordBytes: 3)
        var wrongEndian = Data()
        for index in stride(from: 0, to: payload.count, by: 3) {
            wrongEndian.append(contentsOf: payload[index..<(index + 3)].reversed())
        }
        let format = format(bits: 24, wordBytes: 3)
        XCTAssertFalse(OutputByteVerification.compare(capture: wrongEndian, format: format, reference: fixture.reference).passed)
        let partial = OutputByteVerification.compare(capture: Data(payload.dropLast()), format: format,
                                                     reference: fixture.reference)
        XCTAssertFalse(partial.passed)
        XCTAssertFalse(partial.captureWellFormed)
        var wrongRate = format
        wrongRate.mSampleRate = 44_100
        let rateResult = OutputByteVerification.compare(capture: payload, format: wrongRate, reference: fixture.reference)
        XCTAssertFalse(rateResult.passed)
        XCTAssertFalse(rateResult.rateMatches)
        for flag in [kAudioFormatFlagIsBigEndian, kAudioFormatFlagIsNonInterleaved, kAudioFormatFlagIsFloat] {
            var unsupported = format
            unsupported.mFormatFlags |= flag
            XCTAssertFalse(OutputByteVerification.compare(capture: payload, format: unsupported,
                                                          reference: fixture.reference).validFormat)
        }
        var inconsistent = format
        inconsistent.mBytesPerPacket = 5
        XCTAssertFalse(OutputByteVerification.compare(capture: payload, format: inconsistent,
                                                      reference: fixture.reference).validFormat)
        inconsistent = format
        inconsistent.mSampleRate = .nan
        let invalidRate = OutputByteVerification.compare(capture: payload, format: inconsistent, reference: fixture.reference)
        XCTAssertFalse(invalidRate.passed)
        _ = try JSONEncoder().encode(invalidRate)
    }

    func testInsufficientPrecisionAndOffGridReferencesAreRejected() {
        let fixture = fixture()
        let narrow = OutputByteVerification.compare(capture: Data(repeating: 0, count: 96 * 4),
            format: format(bits: 16, wordBytes: 2), reference: fixture.reference)
        XCTAssertFalse(narrow.passed)
        XCTAssertFalse(narrow.exactReferencePrecision)
        var samples = fixture.reference.samples
        samples[70] = 1.0 / Float(1 << 25)
        let offGrid = ReferencePCM(samples: samples, sampleRate: 48_000, bits: 24,
                                   fileSHA256: "invalid", sourceFormat: "integer PCM")
        let invalid = OutputByteVerification.compare(capture: bytes(fixture, validBits: 32, wordBytes: 4),
            format: format(bits: 32, wordBytes: 4), reference: offGrid)
        XCTAssertFalse(invalid.passed)
        XCTAssertFalse(invalid.exactReferencePrecision)
    }
}
