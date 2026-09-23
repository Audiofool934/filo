import CoreAudio
import Foundation

public enum AudioFormats {
    public static func equal(_ a: AudioStreamBasicDescription, _ b: AudioStreamBasicDescription) -> Bool {
        a.mSampleRate == b.mSampleRate && a.mFormatID == b.mFormatID && a.mFormatFlags == b.mFormatFlags
        && a.mBytesPerPacket == b.mBytesPerPacket && a.mFramesPerPacket == b.mFramesPerPacket
        && a.mBytesPerFrame == b.mBytesPerFrame && a.mChannelsPerFrame == b.mChannelsPerFrame
        && a.mBitsPerChannel == b.mBitsPerChannel
    }
    public static func setAndConfirm(_ object: AudioObjectID, _ property: AudioObjectPropertySelector,
                                     _ target: AudioStreamBasicDescription) throws {
        if equal(try HAL.value(object, property, default: AudioStreamBasicDescription()), target) { return }
        try HAL.set(object, property, target)
        let deadline = Date().addingTimeInterval(2)
        repeat {
            if equal(try HAL.value(object, property, default: AudioStreamBasicDescription()), target) { return }
            Thread.sleep(forTimeInterval: 0.01)
        } while Date() < deadline
        throw AudioFailure("The device did not confirm the requested PCM format.")
    }
    public static func integerCandidate(_ ranged: AudioStreamRangedDescription, rate: Double, minimumBits: UInt32) -> AudioStreamBasicDescription? {
        var f = ranged.mFormat
        guard rate >= ranged.mSampleRateRange.mMinimum, rate <= ranged.mSampleRateRange.mMaximum,
              f.mFormatID == kAudioFormatLinearPCM, f.mChannelsPerFrame == 2,
              f.mFormatFlags & kAudioFormatFlagIsFloat == 0,
              f.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              f.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0,
              f.mFormatFlags & kAudioFormatFlagIsNonMixable != 0,
              f.mFramesPerPacket == 1, [16, 24, 32].contains(f.mBitsPerChannel),
              f.mBitsPerChannel >= minimumBits else { return nil }
        let channelsPerBuffer: UInt32 = f.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0 ? 2 : 1
        guard f.mBytesPerFrame % channelsPerBuffer == 0,
              [2, 3, 4].contains(f.mBytesPerFrame / channelsPerBuffer),
              f.mBitsPerChannel <= f.mBytesPerFrame / channelsPerBuffer * 8,
              f.mBytesPerPacket == f.mBytesPerFrame else { return nil }
        f.mSampleRate = rate
        return f
    }
}

/// Owns hardware configuration only; the caller stops all IO before restoration.
public final class ExclusiveDevice {
    public private(set) var device: OutputDevice?
    public private(set) var stream: AudioObjectID = 0
    public private(set) var virtualFormat = AudioStreamBasicDescription()
    public private(set) var physicalFormat = AudioStreamBasicDescription()
    private var journal: ExclusiveRecoveryJournal?
    private let journalDirectory: URL
    public init(journalDirectory: URL = ExclusiveRecoveryJournal.defaultDirectory) { self.journalDirectory = journalDirectory }
    deinit { _ = restore() }

    public func acquire(output: OutputDevice, rate: Double, minimumBits: UInt32 = 24) throws {
        guard device == nil else { throw AudioFailure("An exclusive output is already prepared.") }
        guard [16, 24].contains(minimumBits),
              let current = try SystemExclusiveRecoveryAccess.output(uid: output.uid) else {
            throw AudioFailure("Unsupported source precision or disconnected output.")
        }
        guard try HAL.value(current.id, kAudioDevicePropertyHogMode, default: Int32(-1)) == -1 else {
            throw AudioFailure("The output is already exclusively owned. Stop its current session before connecting.")
        }
        device = current
        do {
            stream = try SystemExclusiveRecoveryAccess.stream(current)
            let journal = try ExclusiveRecoveryJournal(resource: .init(kind: .output, uid: current.uid), directory: journalDirectory)
            self.journal = journal
            _ = try journal.perform(.rate(rate))
            let physical = try HAL.array(stream, kAudioStreamPropertyAvailablePhysicalFormats, seed: AudioStreamRangedDescription())
                .compactMap { AudioFormats.integerCandidate($0, rate: rate, minimumBits: minimumBits) }
                .sorted { a, b in a.mBitsPerChannel == b.mBitsPerChannel ? a.mBytesPerFrame < b.mBytesPerFrame : a.mBitsPerChannel > b.mBitsPerChannel }
            let virtual = try HAL.array(stream, kAudioStreamPropertyAvailableVirtualFormats, seed: AudioStreamRangedDescription())
                .compactMap { AudioFormats.integerCandidate($0, rate: rate, minimumBits: minimumBits) }
            guard let chosen = physical.first(where: { p in virtual.contains { AudioFormats.equal(p, $0) } }) else {
                throw AudioFailure("This device does not advertise matching non-mixable integer callback and hardware formats.")
            }
            _ = try journal.perform(.physical(RecoveryPCMFormat(chosen)))
            _ = try journal.perform(.virtual(RecoveryPCMFormat(chosen)))
            virtualFormat = try HAL.value(stream, kAudioStreamPropertyVirtualFormat, default: AudioStreamBasicDescription())
            physicalFormat = try HAL.value(stream, kAudioStreamPropertyPhysicalFormat, default: AudioStreamBasicDescription())
            try validate()
        } catch {
            let recovery = restore()
            if recovery.isEmpty { throw error }
            throw AudioFailure(error.localizedDescription + " Recovery: " + recovery.joined(separator: " "))
        }
    }

    public func validate() throws {
        guard let device, try HAL.string(device.id, kAudioDevicePropertyDeviceUID) == device.uid,
              try HAL.value(device.id, kAudioDevicePropertyHogMode, default: Int32(-1)) == getpid(),
              try SystemExclusiveRecoveryAccess.stream(device) == stream, let journal else {
            throw AudioFailure("Exclusive output ownership or stream changed.")
        }
        try journal.validate()
    }

    @discardableResult public func restore() -> [String] {
        let errors = journal?.restore() ?? []
        journal = nil; device = nil; stream = 0
        return errors
    }
}
