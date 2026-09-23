import CoreAudio
import CryptoKit
import Foundation

/// An observation at the supplied output-buffer boundary, not proof of USB receiver delivery.
public struct OutputByteComparison: Codable {
    public fileprivate(set) var outputFormat: PCMFormat?
    public fileprivate(set) var bytesPerPacket: UInt32 = 0
    public fileprivate(set) var framesPerPacket: UInt32 = 0
    public fileprivate(set) var validFormat = false
    public fileprivate(set) var captureWellFormed = false
    public fileprivate(set) var rateMatches = false
    public fileprivate(set) var exactReferencePrecision = false
    public fileprivate(set) var referenceBits = 0
    public fileprivate(set) var containerBits = 0
    public fileprivate(set) var paddingBits = 0
    public fileprivate(set) var precisionHandling = "Unverified"
    public fileprivate(set) var totalOutputBytes = 0
    public fileprivate(set) var capturedFrames = 0
    public fileprivate(set) var referenceFrames = 0
    public fileprivate(set) var comparedFrames = 0
    public fileprivate(set) var comparedBytes = 0
    public fileprivate(set) var mismatchedBytes = 0
    public fileprivate(set) var mismatchedSampleWords = 0
    public fileprivate(set) var mismatchedFrames = 0
    /// Absolute byte offset within the supplied capture, including startup silence.
    public fileprivate(set) var firstMismatchedByte: Int?
    public fileprivate(set) var firstMismatchedFrame: Int?
    public fileprivate(set) var nonzeroLeadingBytes = 0
    public fileprivate(set) var nonzeroTrailingBytes = 0
    public fileprivate(set) var nonzeroPaddingBytes = 0
    public fileprivate(set) var actualCaptureSHA256 = ""
    public fileprivate(set) var expectedReferenceSHA256: String?
    public fileprivate(set) var actualAlignedSHA256: String?
    public fileprivate(set) var expectedAlignedSHA256: String?
    public fileprivate(set) var sampleComparison: ReferencePCMComparison?
    public fileprivate(set) var passed = false
    public fileprivate(set) var failureReason: String?
}

/// Independent integer-word verification; this implementation does not call the realtime serializer.
public enum OutputByteVerification {
    public static func compare(capture: [UInt8], format: AudioStreamBasicDescription,
                               reference: ReferencePCM) -> OutputByteComparison {
        compare(capture: Data(capture), format: format, reference: reference)
    }

    public static func compare(capture: Data, format: AudioStreamBasicDescription,
                               reference: ReferencePCM) -> OutputByteComparison {
        var result = OutputByteComparison()
        // Keep a malformed-rate result JSON-encodable instead of embedding NaN in PCMFormat.
        if format.mSampleRate.isFinite { result.outputFormat = PCMFormat(format) }
        result.bytesPerPacket = format.mBytesPerPacket
        result.framesPerPacket = format.mFramesPerPacket
        result.totalOutputBytes = capture.count
        result.referenceFrames = reference.frameCount
        result.referenceBits = reference.bits
        result.actualCaptureSHA256 = digest(capture)
        result.rateMatches = format.mSampleRate.isFinite && reference.sampleRate.isFinite
            && format.mSampleRate > 0 && format.mSampleRate == reference.sampleRate

        let flags = format.mFormatFlags
        let allowedFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
            | kAudioFormatFlagIsAlignedHigh | kAudioFormatFlagIsNonMixable
        let frameBytes = Int(format.mBytesPerFrame)
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mSampleRate.isFinite, format.mSampleRate > 0,
              format.mChannelsPerFrame == 2,
              flags & kAudioFormatFlagIsSignedInteger != 0,
              flags & ~allowedFlags == 0,
              format.mFramesPerPacket == 1, format.mBytesPerPacket == format.mBytesPerFrame,
              format.mReserved == 0, [4, 6, 8].contains(frameBytes),
              [16, 24, 32].contains(format.mBitsPerChannel) else {
            result.failureReason = "Output bytes require interleaved stereo little-endian signed integer PCM with 16/24/32 valid bits, 2/3/4-byte words, and one complete frame per packet."
            return result
        }
        let wordBytes = frameBytes / 2, containerBits = wordBytes * 8
        let bits = Int(format.mBitsPerChannel)
        guard bits <= containerBits,
              flags & kAudioFormatFlagIsPacked == 0 || bits == containerBits else {
            result.failureReason = "The declared packed/aligned PCM precision does not fit its sample-word container."
            return result
        }
        result.validFormat = true
        result.containerBits = containerBits
        result.paddingBits = containerBits - bits
        result.capturedFrames = capture.count / frameBytes
        guard capture.count % frameBytes == 0, capture.count <= ReferencePCM.maximumFileBytes else {
            result.failureReason = "The output capture has a partial stereo frame or exceeds the 512 MiB verification limit."
            return result
        }
        result.captureWellFormed = true
        guard result.rateMatches else {
            result.failureReason = "The output sample rate does not equal the known reference rate."
            return result
        }
        guard reference.samples.count % 2 == 0,
              reference.frameCount >= ReferencePCM.anchorFrames,
              reference.frameCount <= ReferencePCM.maximumReferenceFrames,
              [8, 16, 20, 24].contains(reference.bits), bits >= reference.bits else {
            result.failureReason = "The reference must contain complete bounded stereo integer PCM at no more than 24 bits, and the output must preserve its declared precision."
            return result
        }
        let referenceScale = pow(2.0, Double(reference.bits - 1))
        guard reference.samples.allSatisfy({ sample in
            let integer = Double(sample) * referenceScale
            return sample.isFinite && sample >= -1 && sample < 1 && integer.rounded(.towardZero) == integer
        }) else {
            result.failureReason = "The reference contains a non-finite, out-of-range, or off-grid sample."
            return result
        }
        result.exactReferencePrecision = true
        result.precisionHandling = "Exact integer widening from \(reference.bits) to \(bits) valid bits; \(containerBits - bits) container padding bits must be zero."

        let alignmentShift = flags & kAudioFormatFlagIsAlignedHigh != 0 ? containerBits - bits : 0
        let validMask = (UInt64(1) << bits) - 1
        let signBit = UInt64(1) << (bits - 1)
        let outputScale = pow(2.0, Double(bits - 1))
        // Scale only by exact powers of two. Reference validation guarantees an integer result.
        func expectedWord(_ sample: Float) -> UInt64 {
            let signed = Int64(Double(sample) * outputScale)
            return (UInt64(bitPattern: signed) & validMask) << alignmentShift
        }
        var expectedReferenceHash = SHA256(), hashChunk = Data()
        hashChunk.reserveCapacity(65_536)
        for sample in reference.samples {
            let word = expectedWord(sample)
            for byte in 0..<wordBytes { hashChunk.append(UInt8(truncatingIfNeeded: word >> (byte * 8))) }
            if hashChunk.count >= 65_536 {
                expectedReferenceHash.update(data: hashChunk)
                hashChunk.removeAll(keepingCapacity: true)
            }
        }
        expectedReferenceHash.update(data: hashChunk)
        result.expectedReferenceSHA256 = hex(expectedReferenceHash.finalize())
        hashChunk.removeAll(keepingCapacity: true)

        capture.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var decoded = [Float]()
            decoded.reserveCapacity(result.capturedFrames * 2)
            for sample in 0..<(result.capturedFrames * 2) {
                var rawWord: UInt64 = 0
                for byte in 0..<wordBytes { rawWord |= UInt64(bytes[sample * wordBytes + byte]) << (byte * 8) }
                let payload = (rawWord >> alignmentShift) & validMask
                let signed = payload & signBit == 0 ? Int64(payload) : Int64(payload) - Int64(UInt64(1) << bits)
                // Float conversion is used only for alignment. Raw comparison below still
                // detects low 32-bit changes that Float32 cannot distinguish.
                decoded.append(Float(Double(signed) / outputScale))
                for byte in 0..<wordBytes {
                    let bitOffset = byte * 8
                    let isPadding = bitOffset < alignmentShift || bitOffset >= alignmentShift + bits
                    if isPadding, bytes[sample * wordBytes + byte] != 0 { result.nonzeroPaddingBytes += 1 }
                }
            }
            let comparison = ReferencePCM.compare(capture: decoded, reference: reference)
            result.sampleComparison = comparison
            guard comparison.aligned else {
                result.failureReason = comparison.failureReason ?? "No unambiguous reference alignment was established."
                return
            }
            result.comparedFrames = comparison.comparedFrames
            result.comparedBytes = comparison.comparedFrames * frameBytes
            let firstFrame = comparison.captureStartFrame
            let endFrame = firstFrame + comparison.comparedFrames
            let firstByte = firstFrame * frameBytes, endByte = endFrame * frameBytes
            let sliceStart = capture.startIndex + firstByte, sliceEnd = capture.startIndex + endByte
            result.actualAlignedSHA256 = digest(capture[sliceStart..<sliceEnd])
            var expectedAlignedHash = SHA256()
            for frame in 0..<result.capturedFrames {
                let isAligned = frame >= firstFrame && frame < endFrame
                var frameMismatch = false
                for channel in 0..<2 {
                    let referenceIndex = (comparison.referenceStartFrame + frame - firstFrame) * 2 + channel
                    let word = isAligned ? expectedWord(reference.samples[referenceIndex]) : 0
                    var wordMismatch = false
                    for byte in 0..<wordBytes {
                        let offset = frame * frameBytes + channel * wordBytes + byte
                        let expected = UInt8(truncatingIfNeeded: word >> (byte * 8))
                        let actual = bytes[offset]
                        if isAligned { hashChunk.append(expected) }
                        if frame < firstFrame, actual != 0 { result.nonzeroLeadingBytes += 1 }
                        if frame >= endFrame, actual != 0 { result.nonzeroTrailingBytes += 1 }
                        if actual != expected {
                            result.mismatchedBytes += 1; wordMismatch = true; frameMismatch = true
                            if result.firstMismatchedByte == nil {
                                result.firstMismatchedByte = offset; result.firstMismatchedFrame = frame
                            }
                        }
                    }
                    if wordMismatch { result.mismatchedSampleWords += 1 }
                }
                if frameMismatch { result.mismatchedFrames += 1 }
                if hashChunk.count >= 65_536 {
                    expectedAlignedHash.update(data: hashChunk)
                    hashChunk.removeAll(keepingCapacity: true)
                }
            }
            expectedAlignedHash.update(data: hashChunk)
            result.expectedAlignedSHA256 = hex(expectedAlignedHash.finalize())
            result.passed = comparison.fullReferenceExact && result.mismatchedBytes == 0
                && result.nonzeroPaddingBytes == 0
                && result.actualAlignedSHA256 == result.expectedAlignedSHA256
                && result.expectedAlignedSHA256 == result.expectedReferenceSHA256
            if !result.passed {
                result.failureReason = result.mismatchedBytes > 0 || result.nonzeroPaddingBytes > 0
                    ? "The output contains noncanonical or mismatching bytes, including padding or surrounding silence."
                    : "The capture does not contain the entire reference exactly once with silent prefix and tail."
            }
        }
        return result
    }

    private static func digest(_ data: Data) -> String { hex(SHA256.hash(data: data)) }
    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
