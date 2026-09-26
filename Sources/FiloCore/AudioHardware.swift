import Foundation
import CoreAudio

public struct AudioFailure: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct UnsupportedSampleRate: LocalizedError {
    public let rate: Double
    public init(_ rate: Double) { self.rate = rate }
    public var errorDescription: String? { "The selected output does not support \(rate / 1000) kHz." }
}

public struct PCMFormat: Codable, Equatable {
    public let rate: Double
    public let channels: UInt32
    public let bits: UInt32
    public let bytesPerFrame: UInt32
    public let flags: UInt32
    public let formatID: UInt32
    public init(_ asbd: AudioStreamBasicDescription) {
        rate = asbd.mSampleRate; channels = asbd.mChannelsPerFrame
        bits = asbd.mBitsPerChannel; bytesPerFrame = asbd.mBytesPerFrame
        flags = asbd.mFormatFlags; formatID = asbd.mFormatID
    }
    public var isFloatStereo: Bool {
        formatID == kAudioFormatLinearPCM && channels == 2 && bits == 32
        && flags & kAudioFormatFlagIsFloat != 0 && flags & kAudioFormatFlagIsBigEndian == 0
        && bytesPerFrame == (flags & kAudioFormatFlagIsNonInterleaved != 0 ? 4 : 8)
    }
}

public struct OutputDevice: Codable, Identifiable, Equatable {
    public var id: UInt32
    public var uid: String
    public var name: String
    public var rate: Double
    public var supportedRates: [Double]
    public var formats: [PCMFormat]
    public var hogPID: Int32?
    public var isDefault: Bool
    public var transport: UInt32
}

public struct AudioProcess: Codable, Identifiable {
    public var id: UInt32
    public var pid: Int32
    public var bundleID: String
    public var running: Bool
    public var devices: [UInt32]
}

public enum HAL {
    public static let system = AudioObjectID(kAudioObjectSystemObject)
    public static func address(_ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    public static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw AudioFailure("\(operation) failed (CoreAudio \(status)).") }
    }
    public static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                 default initial: T, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
        var a = address(selector, scope: scope), value = initial
        var size = UInt32(MemoryLayout<T>.size)
        try withUnsafeMutablePointer(to: &value) { pointer in
            try check(AudioObjectGetPropertyData(object, &a, 0, nil, &size, pointer), "Read \(selector)")
        }
        guard size == MemoryLayout<T>.size else { throw AudioFailure("Unexpected CoreAudio property size.") }
        return value
    }
    public static func array<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                 seed: T, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [T] {
        var a = address(selector, scope: scope), size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size), "Read property size")
        guard size % UInt32(MemoryLayout<T>.stride) == 0 else { throw AudioFailure("Malformed property array.") }
        guard size > 0 else { return [] }
        var result = [T](repeating: seed, count: Int(size) / MemoryLayout<T>.stride)
        try result.withUnsafeMutableBytes { raw in
            try check(AudioObjectGetPropertyData(object, &a, 0, nil, &size, raw.baseAddress!), "Read property array")
        }
        return Array(result.prefix(Int(size) / MemoryLayout<T>.stride))
    }
    public static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var a = address(selector), size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        try withUnsafeMutablePointer(to: &value) { pointer in
            try check(AudioObjectGetPropertyData(object, &a, 0, nil, &size, pointer), "Read name")
        }
        guard let value else { throw AudioFailure("Missing CoreAudio name.") }
        return value.takeRetainedValue() as String
    }
    public static func set<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                               _ value: T, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws {
        var a = address(selector, scope: scope), v = value, writable: DarwinBoolean = false
        try check(AudioObjectIsPropertySettable(object, &a, &writable), "Check device access")
        guard writable.boolValue else { throw AudioFailure("This device property is read-only.") }
        try withUnsafePointer(to: &v) { pointer in
            try check(AudioObjectSetPropertyData(object, &a, 0, nil, UInt32(MemoryLayout<T>.size), pointer), "Configure device")
        }
    }
    public static func defaultOutput() throws -> AudioObjectID {
        try value(system, kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(0))
    }
    public static func rate(_ id: AudioObjectID) throws -> Double {
        try value(id, kAudioDevicePropertyNominalSampleRate, default: Double(0))
    }
    public static func streamFormat(_ id: AudioObjectID, scope: AudioObjectPropertyScope) throws -> AudioStreamBasicDescription {
        try value(id, kAudioDevicePropertyStreamFormat, default: AudioStreamBasicDescription(), scope: scope)
    }
    public static func bufferChannels(_ id: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [UInt32] {
        var a = address(kAudioDevicePropertyStreamConfiguration, scope: scope), size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size), "Read channel layout")
        guard size >= MemoryLayout<AudioBufferList>.size else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        try check(AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw), "Read channel layout")
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).map(\.mNumberChannels)
    }
    public static func outputDevices() throws -> [OutputDevice] {
        let current = try defaultOutput()
        let ids = try array(system, kAudioHardwarePropertyDevices, seed: AudioObjectID(0))
        return ids.compactMap { id in
            guard let streams = try? array(id, kAudioDevicePropertyStreams, seed: AudioObjectID(0), scope: kAudioObjectPropertyScopeOutput),
                  !streams.isEmpty,
                  let uid = try? string(id, kAudioDevicePropertyDeviceUID),
                  !uid.hasPrefix("filo."),
                  let name = try? string(id, kAudioObjectPropertyName),
                  let rate = try? rate(id) else { return nil }
            let ranges = (try? array(id, kAudioDevicePropertyAvailableNominalSampleRates, seed: AudioValueRange())) ?? []
            let conventional: [Double] = [8000, 16000, 22050, 32000, 44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000, 705600, 768000]
            let candidates = conventional + ranges.flatMap { [$0.mMinimum, $0.mMaximum] }
            let rates = Set(candidates.filter { r in ranges.contains { r >= $0.mMinimum && r <= $0.mMaximum } }).sorted()
            let formats = streams.compactMap { try? value($0, kAudioStreamPropertyPhysicalFormat, default: AudioStreamBasicDescription()) }.map(PCMFormat.init)
            return OutputDevice(id: id, uid: uid, name: name, rate: rate, supportedRates: rates, formats: formats,
                                hogPID: try? value(id, kAudioDevicePropertyHogMode, default: Int32(-1)),
                                isDefault: id == current,
                                transport: (try? value(id, kAudioDevicePropertyTransportType, default: UInt32(0))) ?? 0)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public static func processes() throws -> [AudioProcess] {
        try array(system, kAudioHardwarePropertyProcessObjectList, seed: AudioObjectID(0)).compactMap { id in
            guard let pid = try? value(id, kAudioProcessPropertyPID, default: Int32(0)) else { return nil }
            return AudioProcess(id: id, pid: pid,
                                bundleID: (try? string(id, kAudioProcessPropertyBundleID)) ?? "",
                                running: (try? value(id, kAudioProcessPropertyIsRunningOutput, default: UInt32(0))) == 1,
                                devices: (try? array(id, kAudioProcessPropertyDevices, seed: AudioObjectID(0))) ?? [])
        }
    }
    public static func setRate(_ id: AudioObjectID, to target: Double) throws {
        guard target.isFinite && target > 0 else { throw AudioFailure("Invalid sample rate.") }
        let ranges = try array(id, kAudioDevicePropertyAvailableNominalSampleRates, seed: AudioValueRange())
        guard ranges.contains(where: { target >= $0.mMinimum && target <= $0.mMaximum }) else {
            throw UnsupportedSampleRate(target)
        }
        if abs(try rate(id) - target) < 0.01 { return }
        try set(id, kAudioDevicePropertyNominalSampleRate, target)
        for _ in 0..<100 {
            if abs(try rate(id) - target) < 0.01 { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw AudioFailure("The output did not confirm \(Int(target)) Hz.")
    }
}
