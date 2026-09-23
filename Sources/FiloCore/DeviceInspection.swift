import CoreAudio
import Foundation

public struct StreamFormatRange: Codable {
    public let format: PCMFormat
    public let minimumRate: Double
    public let maximumRate: Double
    init(_ value: AudioStreamRangedDescription) {
        format = PCMFormat(value.mFormat)
        minimumRate = value.mSampleRateRange.mMinimum
        maximumRate = value.mSampleRateRange.mMaximum
    }
}

public struct OutputStreamInspection: Codable {
    public let stream: UInt32
    public let virtualFormat: PCMFormat
    public let physicalFormat: PCMFormat
    public let virtualFormats: [StreamFormatRange]
    public let physicalFormats: [StreamFormatRange]
}

public enum DeviceInspection {
    public static func outputStreams(_ device: OutputDevice) throws -> [OutputStreamInspection] {
        let streams = try HAL.array(device.id, kAudioDevicePropertyStreams, seed: AudioObjectID(0), scope: kAudioObjectPropertyScopeOutput)
        return try streams.map { stream in
            OutputStreamInspection(stream: stream,
                                   virtualFormat: PCMFormat(try HAL.value(stream, kAudioStreamPropertyVirtualFormat, default: AudioStreamBasicDescription())),
                                   physicalFormat: PCMFormat(try HAL.value(stream, kAudioStreamPropertyPhysicalFormat, default: AudioStreamBasicDescription())),
                                   virtualFormats: try HAL.array(stream, kAudioStreamPropertyAvailableVirtualFormats, seed: AudioStreamRangedDescription()).map(StreamFormatRange.init),
                                   physicalFormats: try HAL.array(stream, kAudioStreamPropertyAvailablePhysicalFormats, seed: AudioStreamRangedDescription()).map(StreamFormatRange.init))
        }
    }
}
