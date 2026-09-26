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
    private var changedDefault = false
    public init(access: DeviceAccess = SystemDeviceAccess(), journalURL: URL? = nil) {
        self.access = access; self.journalURL = journalURL
    }

    private func persist(ownerPID: Int32 = getpid()) throws {
        guard let journalURL, let outputUID else { return }
        let record = Record(ownerPID: ownerPID, outputUID: outputUID, originalDefaultUID: originalDefaultUID,
                            originalRate: originalRate, lastRate: lastRate, changedDefault: changedDefault)
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
        if let expectedRate = lastRate ?? originalRate, abs(before - expectedRate) > 0.01 {
            throw AudioFailure("The output rate was changed outside filo. Reconnect to continue.")
        }
        guard abs(before - rate) > 0.01 else { return }
        let previousOwnedRate = lastRate
        lastRate = rate
        do { try persist() } catch { lastRate = previousOwnedRate; throw error }
        do { try access.setRate(device.id, rate) }
        catch {
            // A failed write may have changed the hardware before readback failed.
            // Keep the new recovery target only if it may actually have taken effect.
            if let actual = try? access.rate(device.id), abs(actual - before) < 0.01 {
                lastRate = previousOwnedRate
                try? persist()
            }
            throw error
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
        }
        do {
            let devices = try access.devices()
            guard outputUID != nil else { return errors }
            guard let device = devices.first(where: { $0.uid == outputUID }) else {
                errors.append("The managed output is disconnected. Its recovery record is retained until it returns.")
                return errors
            }
            if let lastRate, let originalRate, abs(try access.rate(device.id) - lastRate) < 0.01 {
                do { try access.setRate(device.id, originalRate) } catch { errors.append(error.localizedDescription) }
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
