import CoreAudio
import Foundation

/// The shared playback path negotiates only advertised stereo PCM formats.
public protocol PhysicalFormatAccess: DeviceAccess {
    func physicalFormat(_ device: UInt32) throws -> PCMFormat
    func physicalFormats(_ device: UInt32, rate: Double) throws -> [PCMFormat]
    func setPhysicalFormat(_ device: UInt32, _ format: PCMFormat) throws
}

extension PCMFormat {
    public var precisionBits: UInt32 {
        guard formatID == kAudioFormatLinearPCM else { return 0 }
        if flags & kAudioFormatFlagIsFloat != 0 { return bits == 32 ? 24 : (bits == 64 ? 53 : 0) }
        return bits
    }
    var asbd: AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: rate, mFormatID: formatID, mFormatFlags: flags,
            mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channels, mBitsPerChannel: bits, mReserved: 0)
    }
    func at(rate: Double) -> PCMFormat { var value = asbd; value.mSampleRate = rate; return PCMFormat(value) }
    func sameRepresentation(as other: PCMFormat) -> Bool {
        channels == other.channels && bits == other.bits && bytesPerFrame == other.bytesPerFrame
        && flags == other.flags && formatID == other.formatID
    }
    var isSharedStereoPCM: Bool {
        let samples = flags & kAudioFormatFlagIsNonInterleaved == 0 ? channels : 1
        return formatID == kAudioFormatLinearPCM && channels == 2 && bits > 0 && bits <= 64
            && flags & kAudioFormatFlagIsNonMixable == 0 && precisionBits > 0
            && bytesPerFrame >= samples * ((bits + 7) / 8) && bytesPerFrame <= samples * 8
    }
}

enum PhysicalFormatPolicy {
    static func select(sourceBits: Int, rate: Double, current: PCMFormat, available: [PCMFormat]) -> PCMFormat? {
        guard (1...32).contains(sourceBits), rate.isFinite, rate > 0 else { return nil }
        let candidates = available.filter {
            $0.isSharedStereoPCM && abs($0.rate - rate) < 0.01 && $0.precisionBits >= sourceBits
        }
        // Exact integer precision first, then the smallest adequate representation.
        // Keep an already selected equivalent format to avoid gratuitous container changes.
        func rank(_ value: PCMFormat) -> [Int] {
            let integer = value.flags & kAudioFormatFlagIsFloat == 0
            return [integer && value.bits == sourceBits ? 0 : 1, Int(value.precisionBits),
                    value.sameRepresentation(as: current) ? 0 : 1, integer ? 0 : 1, Int(value.bytesPerFrame)]
        }
        return candidates.min { rank($0).lexicographicallyPrecedes(rank($1)) }
    }
}

extension SystemDeviceAccess: PhysicalFormatAccess {
    private func outputStream(_ device: UInt32) throws -> UInt32 {
        let streams = try HAL.array(device, kAudioDevicePropertyStreams, seed: UInt32(0), scope: kAudioObjectPropertyScopeOutput)
        guard streams.count == 1 else { throw AudioFailure("Format matching requires one stereo output stream.") }
        return streams[0]
    }
    public func physicalFormat(_ device: UInt32) throws -> PCMFormat {
        PCMFormat(try HAL.value(outputStream(device), kAudioStreamPropertyPhysicalFormat, default: AudioStreamBasicDescription()))
    }
    public func physicalFormats(_ device: UInt32, rate: Double) throws -> [PCMFormat] {
        try HAL.array(outputStream(device), kAudioStreamPropertyAvailablePhysicalFormats, seed: AudioStreamRangedDescription())
            .filter { rate >= $0.mSampleRateRange.mMinimum && rate <= $0.mSampleRateRange.mMaximum }
            .map { var format = $0.mFormat; format.mSampleRate = rate; return PCMFormat(format) }
    }
    public func setPhysicalFormat(_ device: UInt32, _ format: PCMFormat) throws {
        guard format.isSharedStereoPCM, try physicalFormats(device, rate: format.rate).contains(format) else {
            throw AudioFailure("The output does not advertise this shared PCM format.")
        }
        if try physicalFormat(device) == format { return }
        let stream = try outputStream(device)
        try HAL.set(stream, kAudioStreamPropertyPhysicalFormat, format.asbd)
        for _ in 0..<100 {
            let actual = try physicalFormat(device)
            if actual.sameRepresentation(as: format), abs(actual.rate - format.rate) < 0.01 { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw AudioFailure("The output did not confirm the selected PCM format.")
    }
}
