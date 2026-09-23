import Foundation

/// Adjusts virtual delivery timing; it never operates on audio samples.
public struct ClockFollower {
    public let sampleRate: Double
    public let targetFrames: Double
    private var filteredError: Double = 0
    private var integral: Double = 0
    private var correction: Double = 0
    private var saturatedSeconds: Double = 0
    public private(set) var minimumQueued: UInt64 = .max
    public private(set) var maximumQueued: UInt64 = 0
    public init(sampleRate: Double, targetFrames: UInt64) {
        self.sampleRate = sampleRate; self.targetFrames = Double(targetFrames)
    }
    public mutating func update(queuedFrames: UInt64, elapsed: Double) throws -> Float {
        guard sampleRate.isFinite, sampleRate > 0, elapsed.isFinite, elapsed > 0, elapsed < 2 else {
            throw AudioFailure("The virtual-clock controller missed its timing deadline.")
        }
        minimumQueued = min(minimumQueued, queuedFrames); maximumQueued = max(maximumQueued, queuedFrames)
        let errorSeconds = (Double(queuedFrames) - targetFrames) / sampleRate
        let smoothing = 1 - exp(-elapsed / 2)
        filteredError += smoothing * (errorSeconds - filteredError)
        let limit = 0.002
        let proposedIntegral = integral + filteredError * elapsed
        let proposed = -(0.03 * filteredError + 0.002 * proposedIntegral)
        if abs(proposed) < limit { integral = proposedIntegral }
        let target = max(-limit, min(limit, proposed))
        let slew = 0.0002 * elapsed
        correction += max(-slew, min(slew, target - correction))
        saturatedSeconds = abs(proposed) >= limit ? saturatedSeconds + elapsed : 0
        guard saturatedSeconds < 15 else { throw AudioFailure("The virtual clock could not follow the DAC within its correction range.") }
        return Float(0.5 + correction / 0.02)
    }
}
