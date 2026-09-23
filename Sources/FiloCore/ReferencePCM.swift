import AVFoundation
import CryptoKit
import Foundation
import FiloPCM

/// A finite, independently decoded local reference, in interleaved stereo Float32.
public struct ReferencePCM {
    public static let maximumReferenceFrames = 24_000_000
    public static let maximumFileBytes = 512 * 1024 * 1024
    public static let anchorFrames = 32

    public let samples: [Float]
    public let sampleRate: Double
    public let bits: Int
    public let fileSHA256: String
    public let sourceFormat: String
    public var frameCount: Int { samples.count / 2 }

    /// Writes an original quiet fixture; an existing destination is never overwritten.
    public static func generateFixture(at url: URL, sampleRate: Double, bits: Int,
                                       duration: TimeInterval) throws -> ReferencePCM {
        guard url.isFileURL, sampleRate.isFinite, sampleRate >= 8_000, sampleRate <= 768_000,
              sampleRate.rounded() == sampleRate, [16, 24].contains(bits),
              duration.isFinite, duration > 0, duration <= 300 else {
            throw AudioFailure("A fixture requires a local path, an integer rate from 8 to 768 kHz, 16/24 bits, and a duration up to 300 seconds.")
        }
        let requestedFrames = (sampleRate * duration).rounded(.down)
        guard requestedFrames >= Double(anchorFrames), requestedFrames <= Double(maximumReferenceFrames) else {
            throw AudioFailure("Fixture length must be between 32 and \(maximumReferenceFrames) stereo frames.")
        }
        let frames = Int(requestedFrames), bytesPerSample = bits / 8
        let dataBytes = frames * 2 * bytesPerSample
        var data = Data(capacity: 44 + dataBytes)
        func append16(_ value: UInt16) {
            data.append(UInt8(truncatingIfNeeded: value))
            data.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        func append32(_ value: UInt32) {
            for shift in stride(from: 0, through: 24, by: 8) {
                data.append(UInt8(truncatingIfNeeded: value >> shift))
            }
        }
        data.append(contentsOf: "RIFF".utf8); append32(UInt32(36 + dataBytes))
        data.append(contentsOf: "WAVEfmt ".utf8); append32(16)
        append16(1); append16(2); append32(UInt32(sampleRate))
        append32(UInt32(sampleRate) * UInt32(2 * bytesPerSample))
        append16(UInt16(2 * bytesPerSample)); append16(UInt16(bits))
        data.append(contentsOf: "data".utf8); append32(UInt32(dataBytes))
        let scale = Float(1 << (bits - 1))
        for frame in 0..<frames {
            for channel: UInt32 in 0..<2 {
                let sample = Int32(filo_test_sample(UInt64(frame), channel, UInt32(bits)) * scale)
                let word = UInt32(bitPattern: sample)
                for byte in 0..<bytesPerSample { data.append(UInt8(truncatingIfNeeded: word >> (byte * 8))) }
            }
        }
        try data.write(to: url, options: .withoutOverwriting)
        let reference = try load(from: url)
        guard reference.frameCount == frames, reference.bits == bits, reference.sampleRate == sampleRate else {
            throw AudioFailure("The fixture did not decode to its declared format.")
        }
        for index in reference.samples.indices {
            guard reference.samples[index] == filo_test_sample(UInt64(index / 2), UInt32(index % 2), UInt32(bits)) else {
                throw AudioFailure("The fixture decoder did not reproduce the generated PCM samples.")
            }
        }
        return reference
    }

    /// Only integer PCM and ALAC at at most 24 valid bits are accepted as references.
    public static func load(from url: URL, maximumFrames: Int = maximumReferenceFrames) throws -> ReferencePCM {
        guard url.isFileURL, maximumFrames >= anchorFrames, maximumFrames <= maximumReferenceFrames else {
            throw AudioFailure("A reference requires a local file and a bounded frame limit.")
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let fileSize = values.fileSize,
              fileSize > 0, fileSize <= maximumFileBytes else {
            throw AudioFailure("The reference must be a regular file of at most 512 MiB.")
        }
        let digestBefore = try digestFile(url)
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: true)
        let format = file.fileFormat.streamDescription.pointee
        let bits: Int, sourceFormat: String
        switch format.mFormatID {
        case kAudioFormatLinearPCM:
            guard format.mFormatFlags & kAudioFormatFlagIsFloat == 0,
                  [8, 16, 20, 24].contains(Int(format.mBitsPerChannel)) else {
                throw AudioFailure("Reference PCM must have 8, 16, 20, or 24 integer valid bits; Float PCM and 32-bit PCM are not certified.")
            }
            bits = Int(format.mBitsPerChannel); sourceFormat = "integer PCM"
        case kAudioFormatAppleLossless:
            switch format.mFormatFlags {
            case kAppleLosslessFormatFlag_16BitSourceData: bits = 16
            case kAppleLosslessFormatFlag_20BitSourceData: bits = 20
            case kAppleLosslessFormatFlag_24BitSourceData: bits = 24
            default: throw AudioFailure("ALAC reference bit depth is unsupported or exceeds 24 bits.")
            }
            sourceFormat = "ALAC"
        default:
            throw AudioFailure("Only integer PCM and ALAC files are accepted as lossless references.")
        }
        guard format.mChannelsPerFrame == 2, format.mSampleRate.isFinite,
              format.mSampleRate >= 8_000, format.mSampleRate <= 768_000,
              file.processingFormat.sampleRate == format.mSampleRate,
              file.processingFormat.channelCount == 2, file.processingFormat.isInterleaved,
              file.processingFormat.commonFormat == .pcmFormatFloat32 else {
            throw AudioFailure("The reference must decode directly to stereo Float32 at its original sample rate.")
        }
        guard file.length >= AVAudioFramePosition(anchorFrames), file.length <= AVAudioFramePosition(maximumFrames) else {
            throw AudioFailure("Reference length is outside the permitted frame limit.")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384) else {
            throw AudioFailure("Could not allocate the reference decode buffer.")
        }
        let expectedFrames = Int(file.length)
        var samples = [Float]()
        samples.reserveCapacity(expectedFrames * 2)
        let scale = Double(1 << (bits - 1))
        while samples.count / 2 < expectedFrames {
            let remaining = expectedFrames - samples.count / 2
            try file.read(into: buffer, frameCount: min(buffer.frameCapacity, AVAudioFrameCount(remaining)))
            guard buffer.frameLength > 0 else { throw AudioFailure("The reference ended before its declared frame count.") }
            guard samples.count / 2 + Int(buffer.frameLength) <= maximumFrames,
                  let pointer = buffer.floatChannelData?[0], buffer.stride == 2 else {
                throw AudioFailure("Unexpected reference decode length or layout.")
            }
            for index in 0..<(Int(buffer.frameLength) * 2) {
                let value = pointer[index], integer = Double(value) * scale
                guard value.isFinite, value >= -1, value < 1, integer.rounded(.towardZero) == integer else {
                    throw AudioFailure("Decoded reference samples are not exact integers at the declared bit depth.")
                }
                samples.append(value)
            }
        }
        guard samples.count / 2 == expectedFrames, try digestFile(url) == digestBefore else {
            throw AudioFailure("The reference was truncated or changed while it was being decoded.")
        }
        return ReferencePCM(samples: samples, sampleRate: format.mSampleRate, bits: bits,
                            fileSHA256: digestBefore, sourceFormat: sourceFormat)
    }

    private static func digestFile(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256(), bytes = 0
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            bytes += data.count
            guard bytes <= maximumFileBytes else { throw AudioFailure("The reference file exceeds 512 MiB.") }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Finds one unique 32-frame anchor, then uses one fixed offset for the entire overlap.
    public static func compare(capture: [Float], reference: ReferencePCM) -> ReferencePCMComparison {
        let capturedFrames = capture.count / 2, referenceFrames = reference.frameCount
        func failure(_ reason: String, ambiguous: Bool = false) -> ReferencePCMComparison {
            ReferencePCMComparison(aligned: false, alignmentAmbiguous: ambiguous, anchorFrames: anchorFrames,
                capturedFrames: capturedFrames, referenceFrames: referenceFrames, captureStartFrame: 0,
                referenceStartFrame: 0, comparedFrames: 0, mismatchedSamples: 0, maxIntegerError: 0,
                missingPrefixFrames: 0, missingSuffixFrames: referenceFrames, leadingCaptureFrames: 0,
                trailingCaptureFrames: 0, nonzeroLeadingSamples: 0, nonzeroTrailingSamples: 0,
                windowExact: false, fullReferenceExact: false, failureReason: reason)
        }
        guard capture.count % 2 == 0, reference.samples.count % 2 == 0,
              capturedFrames >= anchorFrames, referenceFrames >= anchorFrames,
              [8, 16, 20, 24].contains(reference.bits) else {
            return failure("A comparison requires complete stereo frames and at least 32 frames on each side.")
        }
        guard capture.allSatisfy(\.isFinite), reference.samples.allSatisfy(\.isFinite) else {
            return failure("Non-finite samples cannot form an exact integer PCM comparison.")
        }
        var firstNonzero = 0
        while firstNonzero < capturedFrames,
              capture[firstNonzero * 2] == 0, capture[firstNonzero * 2 + 1] == 0 { firstNonzero += 1 }
        guard firstNonzero + anchorFrames <= capturedFrames else {
            return failure("No complete non-silent 32-frame anchor was captured.")
        }
        let pattern = Array(capture[(firstNonzero * 2)..<((firstNonzero + anchorFrames) * 2)])
        // KMP keeps long reference searches linear and avoids a large frame-index allocation.
        var prefix = [Int](repeating: 0, count: pattern.count), matched = 0
        for index in 1..<pattern.count {
            while matched > 0 && pattern[index] != pattern[matched] { matched = prefix[matched - 1] }
            if pattern[index] == pattern[matched] { matched += 1 }
            prefix[index] = matched
        }
        matched = 0
        var anchor: Int?
        for index in reference.samples.indices {
            while matched > 0 && reference.samples[index] != pattern[matched] { matched = prefix[matched - 1] }
            if reference.samples[index] == pattern[matched] { matched += 1 }
            if matched == pattern.count {
                let start = index + 1 - pattern.count
                if start % 2 == 0 {
                    if anchor != nil { return failure("The 32-frame anchor repeats in the reference; alignment is ambiguous.", ambiguous: true) }
                    anchor = start / 2
                }
                matched = prefix[matched - 1]
            }
        }
        guard let anchor else { return failure("No exact 32-frame stereo anchor matches the reference.") }
        let offset = firstNonzero - anchor
        let captureStart = max(0, offset), referenceStart = max(0, -offset)
        let count = min(capturedFrames - captureStart, referenceFrames - referenceStart)
        var mismatches = 0, maxError = 0.0
        let scale = Double(1 << (reference.bits - 1))
        for index in 0..<(count * 2) {
            let actual = capture[captureStart * 2 + index]
            let expected = reference.samples[referenceStart * 2 + index]
            if actual != expected {
                mismatches += 1
                maxError = max(maxError, abs(Double(actual) - Double(expected)) * scale)
            }
        }
        let end = captureStart + count
        let leadingNonzero = capture[..<(captureStart * 2)].reduce(0) { $0 + ($1 == 0 ? 0 : 1) }
        let trailingNonzero = capture[(end * 2)...].reduce(0) { $0 + ($1 == 0 ? 0 : 1) }
        let missingSuffix = referenceFrames - referenceStart - count
        let windowExact = count > 0 && mismatches == 0
        let fullExact = windowExact && referenceStart == 0 && missingSuffix == 0
            && leadingNonzero == 0 && trailingNonzero == 0
        return ReferencePCMComparison(aligned: true, alignmentAmbiguous: false, anchorFrames: anchorFrames,
            capturedFrames: capturedFrames, referenceFrames: referenceFrames, captureStartFrame: captureStart,
            referenceStartFrame: referenceStart, comparedFrames: count, mismatchedSamples: mismatches,
            maxIntegerError: maxError, missingPrefixFrames: referenceStart, missingSuffixFrames: missingSuffix,
            leadingCaptureFrames: captureStart, trailingCaptureFrames: capturedFrames - end,
            nonzeroLeadingSamples: leadingNonzero, nonzeroTrailingSamples: trailingNonzero,
            windowExact: windowExact, fullReferenceExact: fullExact, failureReason: nil)
    }
}

/// All results describe the supplied capture boundary; none infer hardware endpoint receipt.
public struct ReferencePCMComparison: Codable {
    public let aligned: Bool
    public let alignmentAmbiguous: Bool
    public let anchorFrames: Int
    public let capturedFrames: Int
    public let referenceFrames: Int
    public let captureStartFrame: Int
    public let referenceStartFrame: Int
    public let comparedFrames: Int
    public let mismatchedSamples: Int
    public let maxIntegerError: Double
    public let missingPrefixFrames: Int
    public let missingSuffixFrames: Int
    public let leadingCaptureFrames: Int
    public let trailingCaptureFrames: Int
    public let nonzeroLeadingSamples: Int
    public let nonzeroTrailingSamples: Int
    public let windowExact: Bool
    public let fullReferenceExact: Bool
    public let failureReason: String?
}
