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
    public private(set) var outputUID: String?
    private var originalDefaultUID: String?
    private var originalRate: Double?
    private var lastRate: Double?
    private var changedDefault = false
    public init(access: DeviceAccess = SystemDeviceAccess()) { self.access = access }

    public func begin(output: OutputDevice) throws {
        guard outputUID == nil else { throw AudioFailure("An output is already connected.") }
        let devices = try access.devices()
        originalDefaultUID = devices.first { $0.id == (try? access.defaultOutput()) }?.uid
        originalRate = try access.rate(output.id)
        outputUID = output.uid
        do {
            if try access.defaultOutput() != output.id {
                try access.setDefaultOutput(output.id)
                changedDefault = true
            }
        } catch { outputUID = nil; throw error }
    }
    public func apply(rate: Double) throws {
        guard let uid = outputUID, let device = try access.devices().first(where: { $0.uid == uid }) else {
            throw AudioFailure("The selected output was disconnected.")
        }
        guard try access.defaultOutput() == device.id else {
            throw AudioFailure("The system output changed. Reconnect filo to manage this output again.")
        }
        let before = try access.rate(device.id)
        if let lastRate, abs(before - lastRate) > 0.01 {
            throw AudioFailure("The output rate was changed outside filo. Reconnect to continue.")
        }
        guard abs(before - rate) > 0.01 else { return }
        try access.setRate(device.id, rate)
        lastRate = rate
    }
    @discardableResult public func restore() -> [String] {
        defer { outputUID = nil; originalDefaultUID = nil; originalRate = nil; lastRate = nil; changedDefault = false }
        var errors: [String] = []
        do {
            let devices = try access.devices()
            guard let device = devices.first(where: { $0.uid == outputUID }) else { return errors }
            if let lastRate, let originalRate, abs(try access.rate(device.id) - lastRate) < 0.01 {
                do { try access.setRate(device.id, originalRate) } catch { errors.append(error.localizedDescription) }
            }
            if changedDefault, try access.defaultOutput() == device.id,
               let previous = devices.first(where: { $0.uid == originalDefaultUID }) {
                do { try access.setDefaultOutput(previous.id) } catch { errors.append(error.localizedDescription) }
            }
        } catch { errors.append(error.localizedDescription) }
        return errors
    }
}
