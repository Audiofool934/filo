import XCTest
import CoreAudio
import FiloPCM
@testable import FiloCore

final class PCMTests: XCTestCase {
    func testInterleavedCopyPreservesAllBits() {
        let words: [UInt32] = [0, 0x80000000, 0x3f7fffff, 0xbf800000, 1, 0x00800000, 0x7fc00001, 0x7f800000]
        var input = words.map(Float.init(bitPattern:))
        var output = [Float](repeating: 0, count: input.count)
        let byteCount = UInt32(input.count * 4)
        input.withUnsafeMutableBytes { src in
            output.withUnsafeMutableBytes { dst in
                var inList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: byteCount, mData: src.baseAddress))
                var outList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: byteCount, mData: dst.baseAddress))
                XCTAssertTrue(filo_copy(&inList, &outList))
            }
        }
        XCTAssertEqual(output.map(\.bitPattern), words)
    }
    func testMismatchedBufferLengthsProduceSilenceAndFailure() {
        var input: [Float] = [0.5, -0.5]
        var output: [Float] = [1, 1, 1, 1]
        input.withUnsafeMutableBytes { src in
            output.withUnsafeMutableBytes { dst in
                var inList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: 8, mData: src.baseAddress))
                var outList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: 16, mData: dst.baseAddress))
                XCTAssertFalse(filo_copy(&inList, &outList))
            }
        }
        XCTAssertEqual(output, [0, 0, 0, 0])
    }
    func testPlanarInterleavedRoundTripKeepsChannelOrder() {
        let frames = 31
        var source = (0..<(frames * 2)).map { filo_test_sample(UInt64($0 / 2), UInt32($0 % 2), 24) }
        var destination = [Float](repeating: 0, count: source.count)
        let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        left.initialize(repeating: 0, count: frames); right.initialize(repeating: 0, count: frames)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.stride,
                                                  alignment: MemoryLayout<AudioBufferList>.alignment)
        let ptr = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        ptr.initialize(to: AudioBufferList(mNumberBuffers: 2, mBuffers: AudioBuffer()))
        let planar = UnsafeMutableAudioBufferListPointer(ptr)
        planar[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: left)
        planar[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: right)
        defer { ptr.deinitialize(count: 1); raw.deallocate(); left.deinitialize(count: frames); left.deallocate(); right.deinitialize(count: frames); right.deallocate() }
        source.withUnsafeMutableBytes { src in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: src.baseAddress))
            XCTAssertTrue(filo_copy(&list, ptr))
        }
        destination.withUnsafeMutableBytes { dst in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: dst.baseAddress))
            XCTAssertTrue(filo_copy(ptr, &list))
        }
        XCTAssertEqual(destination, source)
    }
    func testVerifierRejectsGainChangesDropsRepeatsAndChannelSwaps() {
        for bits: UInt32 in [16, 24] {
            let samples = (0..<4096).map { filo_test_sample(UInt64($0 / 2 + 123), UInt32($0 % 2), bits) }
            XCTAssertTrue(PCMVerification.compare([0, 0, 0, 0] + samples, bits: bits, maximumSourceFrames: 500).exact)
            var dropped = samples; dropped.removeSubrange(1000..<1002)
            var repeated = samples; repeated.insert(contentsOf: samples[1000..<1002], at: 1000)
            var swapped = samples
            for i in stride(from: 0, to: swapped.count, by: 2) { swapped.swapAt(i, i + 1) }
            for corrupted in [samples.map { $0 * 0.5 }, dropped, repeated, swapped] {
                XCTAssertFalse(PCMVerification.compare(corrupted, bits: bits, maximumSourceFrames: 500).exact)
            }
            XCTAssertFalse(PCMVerification.compare([Float](repeating: 0, count: 4096), bits: bits, maximumSourceFrames: 500).exact)
        }
    }
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
