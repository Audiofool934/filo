import Foundation
import FiloPCM

public struct PCMComparison: Codable {
    public let aligned: Bool
    public let leadingCaptureFrames: Int
    public let sourceFrameOffset: Int
    public let comparedFrames: Int
    public let mismatchedSamples: Int
    public let maxIntegerError: Double
    public var exact: Bool { aligned && comparedFrames > 0 && mismatchedSamples == 0 }
}

public enum PCMVerification {
    public static func compare(_ capture: [Float], bits: UInt32, maximumSourceFrames: Int) -> PCMComparison {
        func failure() -> PCMComparison {
            PCMComparison(aligned: false, leadingCaptureFrames: 0, sourceFrameOffset: 0,
                          comparedFrames: 0, mismatchedSamples: 0, maxIntegerError: 0)
        }
        guard [16, 24].contains(bits), capture.count >= 64, capture.count % 2 == 0,
              maximumSourceFrames > 0 else { return failure() }
        var leading = 0
        while leading < capture.count / 2 && capture[leading * 2] == 0 && capture[leading * 2 + 1] == 0 { leading += 1 }
        guard leading + 16 < capture.count / 2 else { return failure() }
        var offset: Int?
        for candidate in 0..<maximumSourceFrames {
            if (0..<32).allSatisfy({ i in
                capture[leading * 2 + i] == filo_test_sample(UInt64(candidate + i / 2), UInt32(i % 2), bits)
            }) { offset = candidate; break }
        }
        guard let offset else { return failure() }
        var mismatch = 0, maxError = Double(0)
        for i in (leading * 2)..<capture.count {
            let expected = filo_test_sample(UInt64(offset + i / 2 - leading), UInt32(i % 2), bits)
            if capture[i] != expected {
                mismatch += 1
                let error = abs(Double(capture[i]) - Double(expected)) * (bits == 16 ? 32768 : 8388608)
                maxError = max(maxError, error.isFinite ? error : Double.greatestFiniteMagnitude)
            }
        }
        return PCMComparison(aligned: true, leadingCaptureFrames: leading, sourceFrameOffset: offset,
                             comparedFrames: capture.count / 2 - leading, mismatchedSamples: mismatch, maxIntegerError: maxError)
    }
}
