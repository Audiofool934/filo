import AVFoundation
import CryptoKit
import XCTest
@testable import FiloCore

final class ReferencePCMTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("filo-reference-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private func reference(frames: Int = 512, bits: Int = 24) -> ReferencePCM {
        var samples = [Float]()
        for index in 0..<(frames * 2) {
            var word = UInt32(index + 1) &* 0x9e3779b9
            word ^= word >> 16; word = word &* 0x85ebca6b; word ^= word >> 13
            let value = Int32(word & 0xffff) - 32768
            samples.append(Float(value) / Float(1 << (bits - 1)))
        }
        return ReferencePCM(samples: samples, sampleRate: 48_000, bits: bits,
                            fileSHA256: "test-reference", sourceFormat: "integer PCM")
    }

    func testFixturePackingDigestAndNoOverwrite() throws {
        let directory = try temporaryDirectory()
        for bits in [16, 24] {
            let url = directory.appendingPathComponent("fixture-\(bits).wav")
            let reference = try ReferencePCM.generateFixture(at: url, sampleRate: 48_000, bits: bits, duration: 0.02)
            let data = try Data(contentsOf: url)
            XCTAssertEqual(reference.frameCount, 960)
            XCTAssertEqual(reference.bits, bits)
            XCTAssertEqual(reference.sampleRate, 48_000)
            XCTAssertEqual(reference.fileSHA256, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
            XCTAssertEqual(String(data: data[0..<4], encoding: .ascii), "RIFF")
            XCTAssertEqual(data.count, 44 + reference.samples.count * bits / 8)
            // Decode packed little-endian integers independently of AVAudioFile and the C generator.
            let bytes = bits / 8
            for index in reference.samples.indices {
                var word: UInt32 = 0
                for byte in 0..<bytes { word |= UInt32(data[44 + index * bytes + byte]) << (byte * 8) }
                let signed = Int32(bitPattern: word << (32 - bits)) >> (32 - bits)
                XCTAssertEqual(reference.samples[index], Float(signed) / Float(1 << (bits - 1)))
                XCTAssertLessThanOrEqual(abs(reference.samples[index]), 0.001)
            }
            XCTAssertTrue(ReferencePCM.compare(capture: reference.samples, reference: reference).fullReferenceExact)
            XCTAssertThrowsError(try ReferencePCM.generateFixture(at: url, sampleRate: 44_100, bits: bits, duration: 0.02))
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }

    func testFixtureAndLoadBounds() throws {
        let url = try temporaryDirectory().appendingPathComponent("fixture.wav")
        for rate in [Double.nan, .infinity, 0, -1, 44_100.5, 1_000_000] {
            XCTAssertThrowsError(try ReferencePCM.generateFixture(at: url, sampleRate: rate, bits: 24, duration: 1))
        }
        for duration in [Double.nan, .infinity, 0, -1, 0.0001, 301] {
            XCTAssertThrowsError(try ReferencePCM.generateFixture(at: url, sampleRate: 48_000, bits: 24, duration: duration))
        }
        XCTAssertThrowsError(try ReferencePCM.generateFixture(at: url, sampleRate: 768_000, bits: 24, duration: 100))
        XCTAssertThrowsError(try ReferencePCM.generateFixture(at: url, sampleRate: 48_000, bits: 32, duration: 1))
        _ = try ReferencePCM.generateFixture(at: url, sampleRate: 48_000, bits: 24, duration: 0.02)
        XCTAssertThrowsError(try ReferencePCM.load(from: url, maximumFrames: 500))
        XCTAssertThrowsError(try ReferencePCM.load(from: url, maximumFrames: Int.max))
        XCTAssertThrowsError(try ReferencePCM.load(from: URL(string: "https://example.invalid/reference.wav")!))
    }

    func testALACDecodePreservesReference() throws {
        let directory = try temporaryDirectory()
        let source = try ReferencePCM.generateFixture(at: directory.appendingPathComponent("source.wav"),
                                                      sampleRate: 48_000, bits: 24, duration: 0.02)
        let encoded = directory.appendingPathComponent("reference.m4a")
        try writeAudio(source.samples, to: encoded, settings: [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitDepthHintKey: 24
        ])
        let decoded = try ReferencePCM.load(from: encoded)
        XCTAssertEqual(decoded.sourceFormat, "ALAC")
        XCTAssertEqual(decoded.bits, 24)
        XCTAssertEqual(decoded.samples, source.samples)
    }

    func testRejectsFloatPCM32BitIntegerAndLossyAAC() throws {
        let directory = try temporaryDirectory(), samples = reference().samples
        for floating in [true, false] {
            let url = directory.appendingPathComponent("unsupported-\(floating).wav")
            try writeAudio(samples, to: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: floating, AVLinearPCMIsBigEndianKey: false
            ])
            XCTAssertThrowsError(try ReferencePCM.load(from: url))
        }
        let url = directory.appendingPathComponent("lossy.m4a")
        try writeAudio(samples, to: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000
        ])
        XCTAssertThrowsError(try ReferencePCM.load(from: url))
    }

    private func writeAudio(_ samples: [Float], to url: URL, settings: [String: Any]) throws {
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                   frameCapacity: AVAudioFrameCount(samples.count / 2)))
        buffer.frameLength = buffer.frameCapacity
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for frame in 0..<samples.count / 2 {
            channels[0][frame] = samples[frame * 2]
            channels[1][frame] = samples[frame * 2 + 1]
        }
        try file.write(from: buffer)
        // Closing the file at this function boundary finalizes compressed file metadata.
    }

    func testFullCoverageAllowsOnlyExternalSilence() throws {
        let ref = reference()
        let capture = [Float](repeating: 0, count: 34) + ref.samples + [Float](repeating: 0, count: 26)
        let result = ReferencePCM.compare(capture: capture, reference: ref)
        XCTAssertTrue(result.fullReferenceExact)
        XCTAssertEqual(result.anchorFrames, 32)
        XCTAssertEqual(result.leadingCaptureFrames, 17)
        XCTAssertEqual(result.trailingCaptureFrames, 13)
        XCTAssertEqual(result.comparedFrames, ref.frameCount)
        XCTAssertEqual(result.missingPrefixFrames, 0)
        XCTAssertEqual(result.missingSuffixFrames, 0)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        XCTAssertEqual(object["fullReferenceExact"] as? Bool, true)

        let trailing = ReferencePCM.compare(capture: ref.samples + [0, 0.125], reference: ref)
        XCTAssertTrue(trailing.windowExact)
        XCTAssertFalse(trailing.fullReferenceExact)
        XCTAssertEqual(trailing.nonzeroTrailingSamples, 1)
    }

    func testPartialWindowsNeverCertifyTheFullReference() {
        let ref = reference()
        let prefixMissing = ReferencePCM.compare(capture: Array(ref.samples.dropFirst(40)), reference: ref)
        XCTAssertTrue(prefixMissing.windowExact)
        XCTAssertFalse(prefixMissing.fullReferenceExact)
        XCTAssertEqual(prefixMissing.missingPrefixFrames, 20)
        let tailMissing = ReferencePCM.compare(capture: Array(ref.samples.dropLast(60)), reference: ref)
        XCTAssertTrue(tailMissing.windowExact)
        XCTAssertFalse(tailMissing.fullReferenceExact)
        XCTAssertEqual(tailMissing.missingSuffixFrames, 30)

        var padded = ref.samples
        padded.insert(contentsOf: [Float](repeating: 0, count: 16), at: 0)
        padded.append(contentsOf: [Float](repeating: 0, count: 16))
        let withSilence = ReferencePCM(samples: padded, sampleRate: ref.sampleRate, bits: ref.bits,
                                       fileSHA256: ref.fileSHA256, sourceFormat: ref.sourceFormat)
        XCTAssertTrue(ReferencePCM.compare(capture: [0, 0] + padded + [0, 0], reference: withSilence).fullReferenceExact)
        XCTAssertFalse(ReferencePCM.compare(capture: Array(padded.dropLast(4)), reference: withSilence).fullReferenceExact)
    }

    func testComparisonRejectsCorruptionWithoutRealignment() {
        let ref = reference()
        var dropped = ref.samples; dropped.removeSubrange(200..<202)
        var repeated = ref.samples; repeated.insert(contentsOf: ref.samples[200..<202], at: 200)
        var gain = ref.samples; gain[200] *= 0.5
        var swapped = ref.samples; swapped.swapAt(200, 201)
        var silent = ref.samples; silent.replaceSubrange(200..<204, with: [0, 0, 0, 0])
        for corrupted in [dropped, repeated, gain, swapped, silent] {
            let result = ReferencePCM.compare(capture: corrupted, reference: ref)
            XCTAssertTrue(result.aligned)
            XCTAssertFalse(result.windowExact)
            XCTAssertFalse(result.fullReferenceExact)
            XCTAssertGreaterThan(result.mismatchedSamples, 0)
            XCTAssertGreaterThan(result.maxIntegerError, 0)
        }
    }

    func testAnchorReallyRequires32StereoFramesAndRejectsAmbiguity() {
        let ref = reference()
        var corruptAnchor = ref.samples
        corruptAnchor[40] += 1.0 / 8388608
        XCTAssertFalse(ReferencePCM.compare(capture: corruptAnchor, reference: ref).aligned)
        var nonfinite = ref.samples; nonfinite[300] = .nan
        let result = ReferencePCM.compare(capture: nonfinite, reference: ref)
        XCTAssertFalse(result.fullReferenceExact)
        XCTAssertNotNil(result.failureReason)
        XCTAssertFalse(ReferencePCM.compare(capture: [Float](repeating: 0, count: 200), reference: ref).fullReferenceExact)
        let repeated = ReferencePCM(samples: ref.samples + ref.samples, sampleRate: ref.sampleRate, bits: ref.bits,
                                    fileSHA256: ref.fileSHA256, sourceFormat: ref.sourceFormat)
        let ambiguous = ReferencePCM.compare(capture: ref.samples, reference: repeated)
        XCTAssertTrue(ambiguous.alignmentAmbiguous)
        XCTAssertFalse(ambiguous.fullReferenceExact)
    }
}
