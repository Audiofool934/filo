import XCTest
@testable import FiloCore

final class ClockFollowerTests: XCTestCase {
    private struct Simulation {
        var minimumFrames = Double.infinity
        var maximumFrames = -Double.infinity
        var minimumObservedFrames = Double.infinity
        var maximumObservedFrames = -Double.infinity
        var finalPitch: Float = 0.5
        var tailMeanFrames = 0.0
        var tailMeanResidualPPM = 0.0
    }

    /// The source oscillator and physical sink are separate clocks.
    /// Pitch changes frame delivery cadence, never the identity or number of samples.
    /// Callback-boundary observations have a deterministic, zero-mean block-sized error.
    private func simulate(rate: Double, oscillatorPPM: Double, seconds: Int) throws -> Simulation {
        let target = UInt64(rate * 0.15)
        var follower = ClockFollower(sampleRate: rate, targetFrames: target)
        var queued = Double(target)
        var pitch: Float = 0.5
        var result = Simulation()
        let elapsedPattern = [0.85, 0.85, 1.15, 1.15, 0.9, 0.9, 1.1, 1.1]
        let callbackFrames = [128, 256, 512, 1024, 512, 256, 128]
        var tailSeconds = 0.0
        for step in 0..<seconds {
            let elapsed = elapsedPattern[step % elapsedPattern.count]
            let correction = 0.02 * (Double(pitch) - 0.5)
            let sourceSpeed = 1 + oscillatorPPM / 1_000_000 + correction
            queued += rate * (sourceSpeed - 1) * elapsed
            let block = Double(callbackFrames[(step / 2) % callbackFrames.count])
            let observationJitter = step.isMultiple(of: 2) ? block : -block
            let observed = queued + observationJitter
            // Do not clamp a failing plant into a representable, apparently safe queue.
            guard queued > 0, observed >= 0, observed.isFinite else {
                throw AudioFailure("Simulation exhausted its queue at step \(step), rate \(rate), oscillator \(oscillatorPPM) ppm.")
            }
            result.minimumFrames = min(result.minimumFrames, queued)
            result.maximumFrames = max(result.maximumFrames, queued)
            result.minimumObservedFrames = min(result.minimumObservedFrames, observed)
            result.maximumObservedFrames = max(result.maximumObservedFrames, observed)
            pitch = try follower.update(queuedFrames: UInt64(observed.rounded()), elapsed: elapsed)
            if step >= seconds - 600 {
                result.tailMeanFrames += queued * elapsed
                result.tailMeanResidualPPM += (sourceSpeed - 1) * 1_000_000 * elapsed
                tailSeconds += elapsed
            }
        }
        result.tailMeanFrames /= tailSeconds
        result.tailMeanResidualPPM /= tailSeconds
        result.finalPitch = pitch
        return result
    }

    func testSixHourClockOffsetsStayInsideReserveWithCallbackObservationJitter() throws {
        for rate in [44_100.0, 192_000.0] {
            for oscillatorPPM in [-500.0, -100.0, 100.0, 500.0] {
                let result = try simulate(rate: rate, oscillatorPPM: oscillatorPPM, seconds: 6 * 60 * 60)
                let scenario = "\(rate) Hz, \(oscillatorPPM) ppm"
                // Half the starting reserve remains available for non-modelled scheduling events.
                XCTAssertGreaterThan(result.minimumFrames / rate, 0.075, scenario)
                XCTAssertLessThan(result.maximumFrames / rate, 0.225, scenario)
                XCTAssertGreaterThan(result.minimumObservedFrames / rate, 0.075, scenario)
                XCTAssertLessThan(result.maximumObservedFrames / rate, 0.225, scenario)
                XCTAssertEqual(result.tailMeanFrames / rate, 0.15, accuracy: 0.005, scenario)
                XCTAssertEqual(result.tailMeanResidualPPM, 0, accuracy: 10, scenario)
                if oscillatorPPM > 0 {
                    XCTAssertLessThan(result.finalPitch, 0.5, scenario)
                } else {
                    XCTAssertGreaterThan(result.finalPitch, 0.5, scenario)
                }
            }
        }
    }

    func testControllerSlowsAnOverfullQueueAndAcceleratesAnUnderfullQueue() throws {
        for rate in [44_100.0, 192_000.0] {
            let target = UInt64(rate * 0.15)
            var overfull = ClockFollower(sampleRate: rate, targetFrames: target)
            var underfull = ClockFollower(sampleRate: rate, targetFrames: target)
            var balanced = ClockFollower(sampleRate: rate, targetFrames: target)
            XCTAssertLessThan(try overfull.update(queuedFrames: target + UInt64(rate * 0.05), elapsed: 1), 0.5)
            XCTAssertGreaterThan(try underfull.update(queuedFrames: target - UInt64(rate * 0.05), elapsed: 1), 0.5)
            XCTAssertEqual(try balanced.update(queuedFrames: target, elapsed: 1), 0.5)
        }
    }

    func testCorrectionIsClampedAndSlewLimitedBeforePersistentSaturationFails() throws {
        let rate = 44_100.0
        for queue in [UInt64(0), UInt64(rate * 4)] {
            var follower = ClockFollower(sampleRate: rate, targetFrames: UInt64(rate * 0.15))
            var previousCorrection = 0.0
            var lastPitch: Float = 0.5
            let elapsed = 0.25
            for _ in 0..<48 {
                lastPitch = try follower.update(queuedFrames: queue, elapsed: elapsed)
                let correction = 0.02 * (Double(lastPitch) - 0.5)
                // Float transport of pitch permits only its representation rounding error.
                XCTAssertLessThanOrEqual(abs(correction), 0.002 + 2e-9)
                XCTAssertLessThanOrEqual(abs(correction - previousCorrection), 0.0002 * elapsed + 2e-9)
                previousCorrection = correction
            }
            let expected = queue == 0 ? 0.6 : 0.4
            XCTAssertEqual(Double(lastPitch), expected, accuracy: 1e-7)
        }

        var saturated = ClockFollower(sampleRate: rate, targetFrames: UInt64(rate * 0.15))
        for _ in 0..<14 {
            _ = try saturated.update(queuedFrames: UInt64(rate * 4), elapsed: 1)
        }
        XCTAssertThrowsError(try saturated.update(queuedFrames: UInt64(rate * 4), elapsed: 1))
    }

    func testMissedOrInvalidDeadlinesAreRejectedBeforeObservationsMutate() throws {
        for elapsed in [0.0, -0.1, 2.0, 3.0, Double.infinity, Double.nan] {
            var follower = ClockFollower(sampleRate: 44_100, targetFrames: 6_615)
            XCTAssertThrowsError(try follower.update(queuedFrames: 6_615, elapsed: elapsed))
            XCTAssertEqual(follower.minimumQueued, UInt64.max)
            XCTAssertEqual(follower.maximumQueued, 0)
        }
        for rate in [0.0, -44_100.0, Double.infinity, Double.nan] {
            var follower = ClockFollower(sampleRate: rate, targetFrames: 6_615)
            XCTAssertThrowsError(try follower.update(queuedFrames: 6_615, elapsed: 1))
        }
        var timely = ClockFollower(sampleRate: 44_100, targetFrames: 6_615)
        XCTAssertEqual(try timely.update(queuedFrames: 6_615, elapsed: 1.999), 0.5)
    }
}
