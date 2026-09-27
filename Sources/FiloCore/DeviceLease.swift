import Foundation
import CoreAudio

public protocol DeviceAccess: AnyObject {
    func devices() throws -> [OutputDevice]
    func defaultOutput() throws -> UInt32
    func setDefaultOutput(_ id: UInt32) throws
    func rate(_ id: UInt32) throws -> Double
    func setRate(_ id: UInt32, _ rate: Double) throws
}

public final class SystemDeviceAccess: DeviceAccess {
    public init() {}
    public func devices() throws -> [OutputDevice] { try HAL.outputDevices() }
    public func defaultOutput() throws -> UInt32 { try HAL.defaultOutput() }
    public func setDefaultOutput(_ id: UInt32) throws {
        try HAL.set(HAL.system, kAudioHardwarePropertyDefaultOutputDevice, id)
        guard try HAL.defaultOutput() == id else { throw AudioFailure("The default output did not change.") }
    }
    public func rate(_ id: UInt32) throws -> Double { try HAL.rate(id) }
    public func setRate(_ id: UInt32, _ rate: Double) throws { try HAL.setRate(id, to: rate) }
}

/// A lease never restores over a user or another app's intervening change.
/// Hardware IDs are resolved from persistent UIDs each time, including after reconnect.
public final class DeviceLease {
    private let access: DeviceAccess
    private let journalURL: URL?
    private struct Record: Codable {
        var ownerPID: Int32
        var outputUID: String
        var originalDefaultUID: String?
        var originalRate: Double?
        var lastRate: Double?
        var originalFormat: PCMFormat?
        var lastFormat: PCMFormat?
        var changedDefault: Bool
    }
    public static var defaultJournalURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("filo", isDirectory: true).appendingPathComponent("connection.json")
    }
    public private(set) var outputUID: String?
    private var originalDefaultUID: String?
    private var originalRate: Double?
    private var lastRate: Double?
    private var originalFormat: PCMFormat?
    private var lastFormat: PCMFormat?
    private var lastSourceBits: Int?
    private var lastDepthMatch: PCMFormat?
    private var changedDefault = false
    public init(access: DeviceAccess = SystemDeviceAccess(), journalURL: URL? = nil) {
        self.access = access; self.journalURL = journalURL
    }

    private func persist(ownerPID: Int32 = getpid()) throws {
        guard let journalURL, let outputUID else { return }
        let record = Record(ownerPID: ownerPID, outputUID: outputUID, originalDefaultUID: originalDefaultUID,
                            originalRate: originalRate, lastRate: lastRate,
                            originalFormat: originalFormat, lastFormat: lastFormat, changedDefault: changedDefault)
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(record).write(to: journalURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
    }

    /// After a crash, recover only a dead owner's changes that still match actual hardware state.
    @discardableResult public func recoverOrphaned() -> [String] {
        guard outputUID == nil, let journalURL, FileManager.default.fileExists(atPath: journalURL.path) else { return [] }
        do {
            let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: journalURL))
            if record.ownerPID > 0, kill(record.ownerPID, 0) == 0 || errno == EPERM { return ["Another filo connection may be active. Quit it before connecting here."] }
            guard record.originalRate.map({ $0.isFinite && $0 > 0 && $0 <= 768000 }) ?? true,
                  record.lastRate.map({ $0.isFinite && $0 > 0 && $0 <= 768000 }) ?? true else {
                return ["The saved output recovery record is invalid."]
            }
            outputUID = record.outputUID; originalDefaultUID = record.originalDefaultUID
            originalRate = record.originalRate; lastRate = record.lastRate; changedDefault = record.changedDefault
            originalFormat = record.originalFormat; lastFormat = record.lastFormat
            return restore()
        } catch { return ["Could not read the previous connection's recovery record: \(error.localizedDescription)"] }
    }

    public func begin(output: OutputDevice) throws {
        guard outputUID == nil else { throw AudioFailure("An output is already connected.") }
        let recoveryErrors = recoverOrphaned()
        guard recoveryErrors.isEmpty else { throw AudioFailure(recoveryErrors.joined(separator: " ")) }
        let devices = try access.devices()
        guard let device = devices.first(where: { $0.uid == output.uid }) else {
            throw AudioFailure("The selected output was disconnected.")
        }
        let originalDefaultID = try access.defaultOutput()
        originalDefaultUID = devices.first { $0.id == originalDefaultID }?.uid
        originalRate = try access.rate(device.id)
        originalFormat = try (access as? PhysicalFormatAccess)?.physicalFormat(device.id)
        outputUID = device.uid
        do {
            if originalDefaultID != device.id {
                changedDefault = true
                try persist()
                try access.setDefaultOutput(device.id)
            }
            try persist()
        } catch { _ = restore(); throw error }
    }
    public func apply(rate: Double) throws {
        guard let uid = outputUID, let device = try access.devices().first(where: { $0.uid == uid }) else {
            throw AudioFailure("The selected output was disconnected.")
        }
        guard try access.defaultOutput() == device.id else {
            throw AudioFailure("The system output changed. Reconnect filo to manage this output again.")
        }
        let before = try access.rate(device.id)
        let formats = access as? PhysicalFormatAccess
        let beforeFormat = try formats?.physicalFormat(device.id)
        if beforeFormat.map({ $0.flags & kAudioFormatFlagIsNonMixable != 0 }) == true {
            throw AudioFailure("The output is using an exclusive format. Release it before matching shared playback.")
        }
        if let expected = lastFormat ?? originalFormat, let actual = beforeFormat,
           !actual.sameRepresentation(as: expected) {
            throw AudioFailure("The output format was changed outside filo. Reconnect to continue.")
        }
        if let expectedRate = lastRate ?? originalRate, abs(before - expectedRate) > 0.01 {
            throw AudioFailure("The output rate was changed outside filo. Reconnect to continue.")
        }
        guard abs(before - rate) > 0.01 else { return }
        let previousOwnedRate = lastRate
        let previousOwnedFormat = lastFormat
        lastRate = rate
        lastFormat = beforeFormat?.at(rate: rate)
        do { try persist() } catch { lastRate = previousOwnedRate; lastFormat = previousOwnedFormat; throw error }
        do {
            try access.setRate(device.id, rate)
            if let formats { lastFormat = try formats.physicalFormat(device.id); try persist() }
        }
        catch {
            // A failed write may have changed the hardware before readback failed.
            // Keep the new recovery target only if it may actually have taken effect.
            if let actual = try? access.rate(device.id), abs(actual - before) < 0.01 {
                lastRate = previousOwnedRate
                lastFormat = previousOwnedFormat
                try? persist()
            }
            throw error
        }
    }
    public func apply(rate: Double, sourceBits: Int?) throws {
        try apply(rate: rate)
        guard let sourceBits, let formats = access as? PhysicalFormatAccess,
              let device = try access.devices().first(where: { $0.uid == outputUID }) else { return }
        let current = try formats.physicalFormat(device.id)
        if lastSourceBits == sourceBits, lastDepthMatch == current { return }
        let available = try formats.physicalFormats(device.id, rate: rate)
        guard let target = PhysicalFormatPolicy.select(sourceBits: sourceBits, rate: rate, current: current, available: available) else {
            // Preserve playback and report limited precision from actual readback in the controller.
            lastSourceBits = nil; return
        }
        guard target != current else { lastSourceBits = sourceBits; lastDepthMatch = current; return }
        let previous = lastFormat
        lastFormat = target
        do { try persist() } catch { lastFormat = previous; throw error }
        do {
            try formats.setPhysicalFormat(device.id, target)
            lastSourceBits = sourceBits
            lastDepthMatch = target
        } catch {
            if let actual = try? formats.physicalFormat(device.id), actual == current {
                lastFormat = previous; try? persist()
            }
            throw error
        }
    }
    /// Used with fresh hardware snapshots, so an external bit-depth change is respected too.
    func validateRepresentation(_ device: OutputDevice) throws {
        if let expected = lastFormat ?? originalFormat, let actual = device.formats.first,
           !actual.sameRepresentation(as: expected) {
            throw AudioFailure("The output format changed outside filo. Your new format has been preserved.")
        }
    }
    @discardableResult public func restore() -> [String] {
        var errors: [String] = []
        let ownsJournal = outputUID != nil
        defer {
            if ownsJournal, let journalURL {
                if errors.isEmpty { try? FileManager.default.removeItem(at: journalURL) }
                else { try? persist(ownerPID: 0) }
            }
            outputUID = nil; originalDefaultUID = nil; originalRate = nil; lastRate = nil; changedDefault = false
            originalFormat = nil; lastFormat = nil; lastSourceBits = nil; lastDepthMatch = nil
        }
        do {
            let devices = try access.devices()
            guard outputUID != nil else { return errors }
            guard let device = devices.first(where: { $0.uid == outputUID }) else {
                errors.append("The managed output is disconnected. Its recovery record is retained until it returns.")
                return errors
            }
            let actualRate = try access.rate(device.id)
            let formats = access as? PhysicalFormatAccess
            let actualFormat = try formats?.physicalFormat(device.id)
            let expectedFormat = lastFormat ?? originalFormat
            let ownsFormat = expectedFormat == nil || actualFormat.map { $0.sameRepresentation(as: expectedFormat!) } == true
            let ownsRate = (lastRate ?? originalRate).map { abs(actualRate - $0) < 0.01 } == true
            if ownsFormat, ownsRate {
                do {
                    if let lastRate, let originalRate, abs(lastRate - originalRate) > 0.01 {
                        let previousFormat = self.lastFormat
                        self.lastRate = originalRate
                        self.lastFormat = actualFormat?.at(rate: originalRate)
                        do { try persist() } catch {
                            self.lastRate = lastRate; self.lastFormat = previousFormat; throw error
                        }
                        do { try access.setRate(device.id, originalRate) }
                        catch {
                            if let actual = try? access.rate(device.id), abs(actual - lastRate) < 0.01 {
                                self.lastRate = lastRate; self.lastFormat = previousFormat; try? persist()
                            }
                            throw error
                        }
                        if let formats { self.lastFormat = try formats.physicalFormat(device.id); try persist() }
                    }
                    if let originalFormat, let formats, lastFormat != nil,
                       try formats.physicalFormat(device.id) != originalFormat {
                        try formats.setPhysicalFormat(device.id, originalFormat)
                    }
                } catch { errors.append(error.localizedDescription) }
            }
            if changedDefault, try access.defaultOutput() == device.id {
                if let previous = devices.first(where: { $0.uid == originalDefaultUID }) {
                    do { try access.setDefaultOutput(previous.id) } catch { errors.append(error.localizedDescription) }
                } else if originalDefaultUID != nil {
                    errors.append("The previous output is disconnected. Route recovery will be retried when it returns.")
                }
            }
        } catch { errors.append(error.localizedDescription) }
        return errors
    }
}
