import XCTest
import CoreAudio
import FiloPCM

final class BridgeTests: XCTestCase {
    private func format(bits: UInt32 = 32, floating: Bool = true, planar: Bool = false,
                        container: UInt32? = nil, high: Bool = false) -> AudioStreamBasicDescription {
        let bytes = container ?? bits / 8
        var flags: UInt32 = floating ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger
        if bytes * 8 == bits { flags |= kAudioFormatFlagIsPacked }
        if planar { flags |= kAudioFormatFlagIsNonInterleaved }
        if high { flags |= kAudioFormatFlagIsAlignedHigh }
        let frameBytes = bytes * (planar ? 1 : 2)
        return AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: flags, mBytesPerPacket: frameBytes, mFramesPerPacket: 1,
            mBytesPerFrame: frameBytes, mChannelsPerFrame: 2, mBitsPerChannel: bits, mReserved: 0)
    }

    private func config(capacity: UInt64 = 16, prime: UInt64 = 1,
                        output: AudioStreamBasicDescription? = nil, sourceBits: UInt32 = 0,
                        capture: UInt64 = 0) -> FiloBridgeConfig {
        var result = FiloBridgeConfig()
        result.capacityFrames = capacity; result.primeFrames = prime
        result.renderCaptureFrames = capture
        result.inputFormat = format(); result.outputFormat = output ?? format()
        result.inputBufferCount = 1; result.sourceBits = sourceBits
        return result
    }

    private func create(_ configuration: FiloBridgeConfig) throws -> OpaquePointer {
        var configuration = configuration
        return try XCTUnwrap(filo_bridge_create(&configuration))
    }

    @discardableResult
    private func push(_ values: [Float], into bridge: OpaquePointer) -> Bool {
        var values = values
        return values.withUnsafeMutableBytes { data in
            var list = AudioBufferList(mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(data.count), mData: data.baseAddress))
            return filo_bridge_push(bridge, &list)
        }
    }

    private func render(_ frames: Int, from bridge: OpaquePointer) -> (Bool, [Float]) {
        var samples = [Float](repeating: 0.75, count: frames * 2)
        let ok = samples.withUnsafeMutableBytes { data in
            var list = AudioBufferList(mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(data.count), mData: data.baseAddress))
            return filo_bridge_render(bridge, &list)
        }
        return (ok, samples)
    }

    private func pattern(_ range: Range<Int>) -> [Float] {
        range.flatMap { frame in [Float(frame) / 32768, -Float(frame) / 32768] }
    }

    func testPrimingRetainsSourceFramesAndRingWrapPreservesOrder() throws {
        let bridge = try create(config(capacity: 8, prime: 4))
        defer { filo_bridge_destroy(bridge) }
        XCTAssertEqual(render(2, from: bridge).1, [0, 0, 0, 0])
        XCTAssertTrue(push(pattern(1..<3), into: bridge))
        XCTAssertEqual(render(2, from: bridge).1, [0, 0, 0, 0])
        XCTAssertEqual(filo_bridge_metrics(bridge).queuedFrames, 2)
        XCTAssertFalse(filo_bridge_metrics(bridge).started)
        XCTAssertTrue(push(pattern(3..<7), into: bridge))
        XCTAssertEqual(render(3, from: bridge).1, pattern(1..<4))
        XCTAssertTrue(push(pattern(7..<11), into: bridge))
        XCTAssertEqual(render(7, from: bridge).1, pattern(4..<11))
        let m = filo_bridge_metrics(bridge)
        XCTAssertEqual(m.capturedFrames, 10); XCTAssertEqual(m.deliveredFrames, 10)
        XCTAssertEqual(m.queuedFrames, 0); XCTAssertEqual(m.startupSilenceFrames, 4)
        XCTAssertEqual(m.initialQueuedFrames, 6)
        XCTAssertEqual(m.fault, 0)
    }

    func testUnderflowLatchesAndDoesNotRepeatOrResume() throws {
        let bridge = try create(config())
        defer { filo_bridge_destroy(bridge) }
        XCTAssertTrue(push(pattern(1..<3), into: bridge))
        XCTAssertEqual(render(2, from: bridge).1, pattern(1..<3))
        let failed = render(1, from: bridge)
        XCTAssertFalse(failed.0); XCTAssertEqual(failed.1, [0, 0])
        XCTAssertFalse(push(pattern(3..<4), into: bridge))
        XCTAssertFalse(render(1, from: bridge).0)
        let m = filo_bridge_metrics(bridge)
        XCTAssertEqual(m.fault, UInt32(FiloBridgeFaultUnderflow.rawValue))
        XCTAssertEqual(m.underflows, 1); XCTAssertEqual(m.deliveredFrames, 2)
    }

    func testOverflowRejectsWholeCallbackWithoutReplacingQueuedFrames() throws {
        let bridge = try create(config(capacity: 4))
        defer { filo_bridge_destroy(bridge) }
        XCTAssertTrue(push(pattern(1..<4), into: bridge))
        XCTAssertEqual(render(1, from: bridge).1, pattern(1..<2))
        XCTAssertFalse(push(pattern(4..<7), into: bridge))
        let failed = render(2, from: bridge)
        XCTAssertFalse(failed.0); XCTAssertEqual(failed.1, [0, 0, 0, 0])
        let m = filo_bridge_metrics(bridge)
        XCTAssertEqual(m.fault, UInt32(FiloBridgeFaultOverflow.rawValue))
        XCTAssertEqual(m.capturedFrames, 3); XCTAssertEqual(m.deliveredFrames, 1)
        XCTAssertEqual(m.overflows, 1)
    }

    func testEveryIntegerLayoutWritesIndependentExpectedBytes() throws {
        // Include sign boundaries, one-LSB values, unequal channels, and 24-bit maxima.
        for bits: UInt32 in [16, 24, 32] {
            let sourceBits: UInt32 = min(bits, 24)
            let sourceScale = Double(UInt64(1) << (sourceBits - 1))
            let signedValues: [Int64] = [-(Int64(1) << (sourceBits - 1)), -1, 0, 1,
                (Int64(1) << (sourceBits - 1)) - 1, -123]
            let samples = signedValues.map { Float(Double($0) / sourceScale) }
            let containers: [(UInt32, Bool)] = bits == 24 ? [(3, false), (4, false), (4, true)] : [(bits / 8, false)]
            for (bytes, high) in containers {
                for planar in [false, true] {
                    let outputFormat = format(bits: bits, floating: false, planar: planar, container: bytes, high: high)
                    let bridge = try create(config(output: outputFormat, sourceBits: sourceBits, capture: 3))
                    defer { filo_bridge_destroy(bridge) }
                    XCTAssertTrue(push(samples, into: bridge))
                    let bank = BufferBank(channels: planar ? [1, 1] : [2], bytes: Int(outputFormat.mBytesPerFrame) * 3)
                    XCTAssertTrue(filo_bridge_render(bridge, bank.list))
                    for channel in 0..<2 {
                        for frame in 0..<3 {
                            let source = signedValues[frame * 2 + channel]
                            let scaled = source * (Int64(1) << (bits - sourceBits))
                            let mask: UInt64 = (UInt64(1) << bits) - 1
                            var word = UInt64(bitPattern: scaled) & mask
                            if high { word <<= bytes * 8 - bits }
                            let expected = (0..<Int(bytes)).map { UInt8(truncatingIfNeeded: word >> (8 * $0)) }
                            let buffer = planar ? channel : 0
                            let offset = planar ? frame * Int(bytes) : (frame * 2 + channel) * Int(bytes)
                            XCTAssertEqual(bank.bytes(buffer, offset: offset, count: Int(bytes)), expected,
                                "bits=\(bits), bytes=\(bytes), high=\(high), planar=\(planar)")
                        }
                    }
                    let capture = try XCTUnwrap(filo_bridge_render_capture(bridge))
                    XCTAssertEqual(Array(UnsafeBufferPointer(start: capture, count: samples.count)), samples)
                    XCTAssertEqual(filo_bridge_metrics(bridge).renderedCaptureFrames, 3)
                    let rawCapture = try XCTUnwrap(filo_bridge_render_bytes(bridge))
                    let expectedRaw = signedValues.flatMap { source -> [UInt8] in
                        let scaled = source * (Int64(1) << (bits - sourceBits))
                        var word = UInt64(bitPattern: scaled) & ((UInt64(1) << bits) - 1)
                        if high { word <<= bytes * 8 - bits }
                        return (0..<Int(bytes)).map { UInt8(truncatingIfNeeded: word >> (8 * $0)) }
                    }
                    XCTAssertEqual(filo_bridge_render_bytes_per_frame(bridge), bytes * 2)
                    XCTAssertEqual(filo_bridge_render_byte_count(bridge), UInt64(expectedRaw.count))
                    XCTAssertEqual(Array(UnsafeBufferPointer(start: rawCapture, count: expectedRaw.count)), expectedRaw)
                }
            }
        }
    }

    func testPlanarTapSpanSkipsDisabledPhysicalInputs() throws {
        var settings = config(capture: 2)
        settings.inputFormat = format(planar: true)
        settings.inputBufferOffset = 1; settings.inputBufferCount = 2
        let bridge = try create(settings)
        defer { filo_bridge_destroy(bridge) }
        let bank = BufferBank(channels: [1, 1, 1], bytes: 8)
        bank.buffers[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 8, mData: nil)
        bank.setFloats([0.25, -0.5], buffer: 1)
        bank.setFloats([-0.25, 0.5], buffer: 2)
        XCTAssertTrue(filo_bridge_push(bridge, bank.list))
        XCTAssertEqual(render(2, from: bridge).1, [0.25, -0.25, -0.5, 0.5])
    }

    func testRejectsRoundingClippingNonfiniteAndFalseSourceDepth() throws {
        for value: Float in [1, -1.1, .infinity, -.infinity, .nan, 1.0 / 65536] {
            let bridge = try create(config(output: format(bits: 16, floating: false)))
            defer { filo_bridge_destroy(bridge) }
            XCTAssertFalse(push([0, value], into: bridge))
            let m = filo_bridge_metrics(bridge)
            XCTAssertEqual(m.fault, UInt32(FiloBridgeFaultRepresentation.rawValue))
            XCTAssertEqual(m.capturedFrames, 0)
        }
        let bridge = try create(config(sourceBits: 16))
        defer { filo_bridge_destroy(bridge) }
        XCTAssertFalse(push([1.0 / 65536, 0], into: bridge))
        XCTAssertEqual(filo_bridge_metrics(bridge).representationFailures, 1)
    }

    func testFloatPathPreservesSignedZeroAndCaptureIsBounded() throws {
        let bridge = try create(config(capture: 1))
        defer { filo_bridge_destroy(bridge) }
        let samples: [Float] = [Float(bitPattern: 0x80000000), 0, Float(bitPattern: 1), -0.5]
        XCTAssertTrue(push(samples, into: bridge))
        XCTAssertEqual(render(2, from: bridge).1.map(\.bitPattern), samples.map(\.bitPattern))
        XCTAssertEqual(filo_bridge_metrics(bridge).renderedCaptureFrames, 1)
        let capture = try XCTUnwrap(filo_bridge_render_capture(bridge))
        XCTAssertEqual(capture[0].bitPattern, 0x80000000)
        let rawCapture = try XCTUnwrap(filo_bridge_render_bytes(bridge))
        XCTAssertEqual(filo_bridge_render_byte_count(bridge), 8)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: rawCapture, count: 8)), [0, 0, 0, 128, 0, 0, 0, 0])
    }

    func testRejectsUnsupportedFormatsAndMalformedOutputBeforePlayback() throws {
        var candidates: [FiloBridgeConfig] = []
        var wrongRate = config(); wrongRate.outputFormat.mSampleRate = 44100; candidates.append(wrongRate)
        var bigEndian = config(); bigEndian.outputFormat.mFormatFlags |= kAudioFormatFlagIsBigEndian; candidates.append(bigEndian)
        var falsePacked = config(output: format(bits: 24, floating: false, container: 4))
        falsePacked.outputFormat.mFormatFlags |= kAudioFormatFlagIsPacked; candidates.append(falsePacked)
        var wrongFrames = config(); wrongFrames.outputFormat.mFramesPerPacket = 2; candidates.append(wrongFrames)
        var overflowWidth = config(output: format(bits: 24, floating: false))
        overflowWidth.outputFormat.mBytesPerFrame = 1_073_741_830
        overflowWidth.outputFormat.mBytesPerPacket = 1_073_741_830
        candidates.append(overflowWidth)
        candidates.append(config(capacity: 7)); candidates.append(config(prime: 0))
        for var candidate in candidates { XCTAssertNil(filo_bridge_create(&candidate)) }
        let bridge = try create(config(capacity: 4))
        defer { filo_bridge_destroy(bridge) }
        let bank = BufferBank(channels: [2], bytes: 17)
        XCTAssertFalse(filo_bridge_render(bridge, bank.list))
        XCTAssertEqual(bank.bytes(0, offset: 0, count: 17), [UInt8](repeating: 0, count: 17))
        XCTAssertEqual(filo_bridge_metrics(bridge).fault, UInt32(FiloBridgeFaultOutputLayout.rawValue))
    }

    private func timestamp(sample: Double?, host: UInt64?) -> AudioTimeStamp {
        var time = AudioTimeStamp()
        if let sample { time.mSampleTime = sample; time.mFlags.insert(.sampleTimeValid) }
        if let host { time.mHostTime = host; time.mFlags.insert(.hostTimeValid) }
        return time
    }

    private func captureCallback(_ bridge: OpaquePointer, frames: Int, sample: Double?, host: UInt64?) {
        let input = BufferBank(channels: [2], bytes: frames * 8)
        input.setFloats(pattern(0..<frames), buffer: 0)
        let unusedOutput = BufferBank(channels: [2], bytes: frames * 8)
        var now = AudioTimeStamp(), inputTime = timestamp(sample: sample, host: host), unused = AudioTimeStamp()
        XCTAssertEqual(filo_bridge_capture_io(0, &now, input.list, &inputTime, unusedOutput.list, &unused,
                                              UnsafeMutableRawPointer(bridge)), noErr)
    }

    private func outputCallback(_ bridge: OpaquePointer, frames: Int, sample: Double?, host: UInt64?) -> [UInt8] {
        let output = BufferBank(channels: [2], bytes: frames * 8)
        let unusedInput = BufferBank(channels: [2], bytes: frames * 8)
        var now = AudioTimeStamp(), outputTime = timestamp(sample: sample, host: host), unused = AudioTimeStamp()
        XCTAssertEqual(filo_bridge_output_io(0, &now, unusedInput.list, &unused, output.list, &outputTime,
                                             UnsafeMutableRawPointer(bridge)), noErr)
        return output.bytes(0, offset: 0, count: frames * 8)
    }

    func testTimestampContinuityUsesPreviousFrameCountAndAllowsBoundedFraction() throws {
        let bridge = try create(config(capacity: 32))
        defer { filo_bridge_destroy(bridge) }
        captureCallback(bridge, frames: 2, sample: -10, host: 100)
        captureCallback(bridge, frames: 3, sample: -7.5, host: 200) // Exactly +0.5 from the anchored timeline.
        captureCallback(bridge, frames: 1, sample: -4.5, host: 300) // Same +0.5 offset, exact adjacent progression.
        let m = filo_bridge_metrics(bridge)
        XCTAssertEqual(m.fault, 0); XCTAssertEqual(m.capturedFrames, 6)
        XCTAssertEqual(m.inputTimestampMissing, 0); XCTAssertEqual(m.inputTimestampDiscontinuities, 0)
    }

    func testInputTimestampJumpsRepeatsAndAccumulatedFractionLatchFault() throws {
        for next in [10.0, 11.499, 12.501, 13.0] {
            let bridge = try create(config())
            defer { filo_bridge_destroy(bridge) }
            captureCallback(bridge, frames: 2, sample: 10, host: 100)
            captureCallback(bridge, frames: 2, sample: next, host: 200)
            let m = filo_bridge_metrics(bridge)
            XCTAssertEqual(m.fault, UInt32(FiloBridgeFaultTimestamp.rawValue))
            XCTAssertEqual(m.capturedFrames, 2); XCTAssertEqual(m.inputTimestampDiscontinuities, 1)
            XCTAssertEqual(render(2, from: bridge).1, [0, 0, 0, 0])
        }
        let bridge = try create(config())
        defer { filo_bridge_destroy(bridge) }
        captureCallback(bridge, frames: 2, sample: 0, host: 100)
        captureCallback(bridge, frames: 2, sample: 2.4, host: 200)
        captureCallback(bridge, frames: 2, sample: 4.8, host: 300)
        XCTAssertEqual(filo_bridge_metrics(bridge).fault, UInt32(FiloBridgeFaultTimestamp.rawValue))
        XCTAssertEqual(filo_bridge_metrics(bridge).capturedFrames, 4)
    }

    func testOppositeHalfFrameOffsetsCannotHideAWholeFrameDiscontinuity() throws {
        let bridge = try create(config())
        defer { filo_bridge_destroy(bridge) }
        captureCallback(bridge, frames: 2, sample: 0, host: 100)
        captureCallback(bridge, frames: 2, sample: 2.5, host: 200)
        captureCallback(bridge, frames: 2, sample: 3.5, host: 300)
        XCTAssertEqual(filo_bridge_metrics(bridge).fault, UInt32(FiloBridgeFaultTimestamp.rawValue))
        XCTAssertEqual(filo_bridge_metrics(bridge).capturedFrames, 4)
        XCTAssertEqual(filo_bridge_metrics(bridge).inputTimestampDiscontinuities, 1)
    }

    func testProductionHasNoDiagnosticCaptureAndSilenceKeepsItsPosition() throws {
        let bridge = try create(config(capacity: 32))
        defer { filo_bridge_destroy(bridge) }
        let samples = pattern(1..<3) + [Float](repeating: 0, count: 8) + pattern(3..<5)
        XCTAssertTrue(push(samples, into: bridge))
        XCTAssertEqual(render(8, from: bridge).1, samples)
        XCTAssertNil(filo_bridge_render_capture(bridge))
        XCTAssertNil(filo_bridge_render_bytes(bridge))
        XCTAssertEqual(filo_bridge_render_byte_count(bridge), 0)
        XCTAssertEqual(filo_bridge_metrics(bridge).renderedCaptureFrames, 0)
        XCTAssertEqual(filo_bridge_metrics(bridge).fault, 0)
        XCTAssertEqual(filo_bridge_metrics(bridge).initialQueuedFrames, 8)
    }

    func testOutputTimestampIncludesStartupSilenceAndRejectsBackwardHostTime() throws {
        let bridge = try create(config(prime: 4))
        defer { filo_bridge_destroy(bridge) }
        XCTAssertEqual(outputCallback(bridge, frames: 2, sample: 100, host: 500), [UInt8](repeating: 0, count: 16))
        XCTAssertTrue(push(pattern(1..<5), into: bridge))
        _ = outputCallback(bridge, frames: 3, sample: 102, host: 600)
        let m = filo_bridge_metrics(bridge)
        XCTAssertEqual(m.fault, 0); XCTAssertEqual(m.deliveredFrames, 3)
        XCTAssertEqual(m.startupSilenceFrames, 2)
        XCTAssertEqual(outputCallback(bridge, frames: 1, sample: 105, host: 599), [UInt8](repeating: 0, count: 8))
        XCTAssertEqual(filo_bridge_metrics(bridge).fault, UInt32(FiloBridgeFaultTimestamp.rawValue))
        XCTAssertEqual(filo_bridge_metrics(bridge).outputTimestampDiscontinuities, 1)
        XCTAssertEqual(filo_bridge_metrics(bridge).deliveredFrames, 3)
    }

    func testMissingTimestampEvidenceIsCountedAndCannotHideSampleJump() throws {
        let bridge = try create(config(capacity: 32))
        defer { filo_bridge_destroy(bridge) }
        captureCallback(bridge, frames: 2, sample: 0, host: 100)
        captureCallback(bridge, frames: 3, sample: nil, host: nil)
        captureCallback(bridge, frames: 1, sample: .nan, host: 200)
        captureCallback(bridge, frames: 2, sample: 6, host: nil)
        var m = filo_bridge_metrics(bridge)
        XCTAssertEqual(m.fault, 0); XCTAssertEqual(m.inputTimestampMissing, 3)
        XCTAssertEqual(m.capturedFrames, 8)
        captureCallback(bridge, frames: 2, sample: 9, host: 300) // Expected sample 8, including evidence gaps.
        m = filo_bridge_metrics(bridge)
        XCTAssertEqual(m.fault, UInt32(FiloBridgeFaultTimestamp.rawValue))
        XCTAssertEqual(m.inputTimestampDiscontinuities, 1); XCTAssertEqual(m.capturedFrames, 8)
    }

    func testOutputMissingEvidenceAndRepeatedSampleTimeAreSeparateFromInput() throws {
        let bridge = try create(config())
        defer { filo_bridge_destroy(bridge) }
        XCTAssertTrue(push(pattern(1..<7), into: bridge))
        _ = outputCallback(bridge, frames: 2, sample: nil, host: nil)
        _ = outputCallback(bridge, frames: 2, sample: 100, host: 200)
        XCTAssertEqual(outputCallback(bridge, frames: 2, sample: 100, host: 300), [UInt8](repeating: 0, count: 16))
        let m = filo_bridge_metrics(bridge)
        XCTAssertEqual(m.outputTimestampMissing, 1); XCTAssertEqual(m.outputTimestampDiscontinuities, 1)
        XCTAssertEqual(m.inputTimestampMissing, 0); XCTAssertEqual(m.inputTimestampDiscontinuities, 0)
        XCTAssertEqual(m.deliveredFrames, 4)
    }

    func testRawCaptureOwnsCopiedBytesAndRemainsBoundedAcrossCallbacks() throws {
        let outputFormat = format(bits: 24, floating: false, planar: true)
        let bridge = try create(config(output: outputFormat, capture: 3))
        defer { filo_bridge_destroy(bridge) }
        let samples: [Float] = [1.0 / 8388608, -1.0 / 8388608, 0.5, -0.5, 0.25, -0.25, 0, 0]
        XCTAssertTrue(push(samples, into: bridge))
        let bank = BufferBank(channels: [1, 1], bytes: 6)
        XCTAssertTrue(filo_bridge_render(bridge, bank.list))
        XCTAssertTrue(filo_bridge_render(bridge, bank.list))
        // Overwrite the reused output buffers after the callback; capture must own its bytes.
        bank.fill(0xA5)
        let raw = try XCTUnwrap(filo_bridge_render_bytes(bridge))
        let expected: [UInt8] = [1, 0, 0, 255, 255, 255, 0, 0, 64, 0, 0, 192, 0, 0, 32, 0, 0, 224]
        XCTAssertEqual(filo_bridge_render_byte_count(bridge), UInt64(expected.count))
        XCTAssertEqual(filo_bridge_render_bytes_per_frame(bridge), 6)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: raw, count: expected.count)), expected)
        XCTAssertEqual(filo_bridge_metrics(bridge).renderedCaptureFrames, 3)
        XCTAssertEqual(filo_bridge_metrics(bridge).deliveredFrames, 4)
    }

    func testConcurrentProducerConsumerWithDifferentChunkSizes() throws {
        let bridge = try create(config(capacity: 128))
        defer { filo_bridge_destroy(bridge) }
        let total = 12000
        let group = DispatchGroup()
        let received = SampleReceipt()
        let deadline = Date().addingTimeInterval(10)
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            var position = 0
            while position < total && Date() < deadline {
                let count = min(position % 17 + 1, total - position)
                let metrics = filo_bridge_metrics(bridge)
                if metrics.fault != 0 { break }
                if metrics.queuedFrames + UInt64(count) > 128 { Thread.sleep(forTimeInterval: 0.00001); continue }
                if !self.push(self.pattern(position..<(position + count)), into: bridge) { break }
                position += count
            }
        }
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            var position = 0
            var result: [Float] = []
            while position < total && Date() < deadline {
                let count = min(position % 29 + 1, total - position)
                let metrics = filo_bridge_metrics(bridge)
                if metrics.fault != 0 { break }
                if metrics.queuedFrames < UInt64(count) { Thread.sleep(forTimeInterval: 0.00001); continue }
                let output = self.render(count, from: bridge)
                if !output.0 { break }
                result.append(contentsOf: output.1); position += count
            }
            received.set(result)
        }
        // Both workers have a bounded deadline; never free the bridge while either still uses it.
        group.wait()
        XCTAssertEqual(received.get(), pattern(0..<total))
        let metrics = filo_bridge_metrics(bridge)
        XCTAssertEqual(metrics.fault, 0)
        XCTAssertEqual(metrics.capturedFrames, UInt64(total)); XCTAssertEqual(metrics.deliveredFrames, UInt64(total))
    }
}

private final class SampleReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    func set(_ value: [Float]) { lock.lock(); samples = value; lock.unlock() }
    func get() -> [Float] { lock.lock(); defer { lock.unlock() }; return samples }
}

private final class BufferBank {
    let list: UnsafeMutablePointer<AudioBufferList>
    private let raw: UnsafeMutableRawPointer
    private let storage: [UnsafeMutableRawPointer]
    var buffers: UnsafeMutableAudioBufferListPointer { UnsafeMutableAudioBufferListPointer(list) }
    init(channels: [UInt32], bytes: Int) {
        raw = .allocate(byteCount: MemoryLayout<AudioBufferList>.size + (channels.count - 1) * MemoryLayout<AudioBuffer>.stride,
                        alignment: MemoryLayout<AudioBufferList>.alignment)
        list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        list.initialize(to: AudioBufferList(mNumberBuffers: UInt32(channels.count), mBuffers: AudioBuffer()))
        storage = channels.map { _ in
            let pointer = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 8)
            pointer.initializeMemory(as: UInt8.self, repeating: 0xA5, count: bytes)
            return pointer
        }
        for i in channels.indices {
            buffers[i] = AudioBuffer(mNumberChannels: channels[i], mDataByteSize: UInt32(bytes), mData: storage[i])
        }
    }
    func setFloats(_ values: [Float], buffer: Int) {
        for (index, value) in values.enumerated() { storage[buffer].storeBytes(of: value, toByteOffset: index * 4, as: Float.self) }
    }
    func bytes(_ buffer: Int, offset: Int, count: Int) -> [UInt8] {
        Array(UnsafeBufferPointer(start: storage[buffer].advanced(by: offset).assumingMemoryBound(to: UInt8.self), count: count))
    }
    func fill(_ value: UInt8) {
        for (index, pointer) in storage.enumerated() {
            pointer.initializeMemory(as: UInt8.self, repeating: value, count: Int(buffers[index].mDataByteSize))
        }
    }
    deinit { list.deinitialize(count: 1); raw.deallocate(); storage.forEach { $0.deallocate() } }
}
