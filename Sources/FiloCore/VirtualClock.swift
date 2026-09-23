import CoreAudio
import Foundation

public struct ClockControlInspection: Codable {
    public let id: UInt32
    public let name: String
    public let classID: UInt32
    public let items: [String: String]?
    public let currentItem: UInt32?
    public let pitch: Float?
}

/// Adapter for the installed BlackHole adjustable clock, never an arbitrary pan control.
public final class VirtualClock {
    private let outputUID: String
    private let journalDirectory: URL
    private var journal: ExclusiveRecoveryJournal?
    private var lastPitchWrite: TimeInterval = -.infinity
    public private(set) var currentPitch: Float = 0.5
    public init(device: OutputDevice, journalDirectory: URL = ExclusiveRecoveryJournal.defaultDirectory) throws {
        guard device.uid.hasPrefix("BlackHole"), device.name.hasPrefix("BlackHole") else {
            throw AudioFailure("Clock-following currently requires an installed BlackHole virtual output.")
        }
        outputUID = device.uid; self.journalDirectory = journalDirectory
    }
    deinit { _ = restore() }

    private static func itemName(_ control: AudioObjectID, item: UInt32) throws -> String {
        var property = HAL.address(kAudioSelectorControlPropertyItemName)
        var result: Unmanaged<CFString>?, identifier = item
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try withUnsafePointer(to: &identifier) { qualifier in
            try withUnsafeMutablePointer(to: &result) { pointer in
                try HAL.check(AudioObjectGetPropertyData(control, &property, UInt32(MemoryLayout<UInt32>.size), qualifier, &size, pointer), "Read clock source name")
            }
        }
        guard let result else { throw AudioFailure("The virtual clock source has no name.") }
        return result.takeRetainedValue() as String
    }
    private static func inspectOnce(_ output: OutputDevice) throws -> [ClockControlInspection] {
        guard output.uid.hasPrefix("BlackHole"), output.name.hasPrefix("BlackHole"),
              try HAL.string(output.id, kAudioDevicePropertyDeviceUID) == output.uid else {
            throw AudioFailure("The BlackHole device changed.")
        }
        return try HAL.array(output.id, kAudioObjectPropertyControlList, seed: AudioObjectID(0)).map { id in
            let type = try HAL.value(id, kAudioObjectPropertyClass, default: UInt32(0))
            var items: [String: String]?
            if type == kAudioClockSourceControlClassID {
                items = [:]
                for item in try HAL.array(id, kAudioSelectorControlPropertyAvailableItems, seed: UInt32(0)) {
                    items?[String(item)] = try itemName(id, item: item)
                }
            }
            return ClockControlInspection(id: id, name: (try? HAL.string(id, kAudioObjectPropertyName)) ?? "", classID: type,
                items: items, currentItem: type == kAudioClockSourceControlClassID ? try HAL.value(id, kAudioSelectorControlPropertyCurrentItem, default: UInt32(0)) : nil,
                pitch: type == kAudioStereoPanControlClassID ? try HAL.value(id, kAudioStereoPanControlPropertyValue, default: Float(0.5)) : nil)
        }
    }
    public static func inspect(_ output: OutputDevice) throws -> [ClockControlInspection] {
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while true {
            do {
                guard let fresh = try SystemExclusiveRecoveryAccess.output(uid: output.uid) else { throw AudioFailure("BlackHole was disconnected.") }
                return try inspectOnce(fresh)
            } catch {
                // BlackHole destroys and recreates controls after a clock-source change.
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw error }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
    }
    private static func selector(_ controls: [ClockControlInspection]) throws -> (ClockControlInspection, String) {
        let selectors = controls.filter { $0.classID == kAudioClockSourceControlClassID }
        guard selectors.count == 1, let control = selectors.first, let item = control.currentItem,
              let name = control.items?[String(item)] else { throw AudioFailure("BlackHole's clock selector is missing or ambiguous.") }
        return (control, name)
    }
    private static func pitch(_ controls: [ClockControlInspection]) throws -> ClockControlInspection? {
        let matches = controls.filter { $0.classID == kAudioStereoPanControlClassID && ($0.name.isEmpty || $0.name.lowercased().contains("pitch")) }
        guard matches.count <= 1 else { throw AudioFailure("BlackHole's pitch control is ambiguous.") }
        return matches.first
    }
    static func readState(_ output: OutputDevice) throws -> RecoveryClockState {
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while true {
            let controls = try inspect(output), (_, name) = try selector(controls)
            if name != "Internal Adjustable" { return RecoveryClockState(selector: name, pitch: nil) }
            if let value = try pitch(controls)?.pitch { return RecoveryClockState(selector: name, pitch: value) }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw AudioFailure("The adjustable clock pitch did not appear.") }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
    static func writeSelector(_ name: String, device: OutputDevice) throws {
        let controls = try inspect(device), (control, current) = try selector(controls)
        if current == name { return }
        let matches = (control.items ?? [:]).filter { $0.value == name }
        guard matches.count == 1, let key = matches.first?.key, let item = UInt32(key) else {
            throw AudioFailure("The saved BlackHole clock source is no longer available.")
        }
        try HAL.set(control.id, kAudioSelectorControlPropertyCurrentItem, item)
        guard try readState(device).selector == name else { throw AudioFailure("BlackHole did not confirm its clock source.") }
    }
    static func writePitch(_ value: Float, device: OutputDevice) throws {
        let controls = try inspect(device), (_, name) = try selector(controls)
        guard name == "Internal Adjustable", let control = try pitch(controls) else {
            throw AudioFailure("The adjustable clock pitch control is unavailable.")
        }
        try HAL.set(control.id, kAudioStereoPanControlPropertyValue, value)
        guard try readState(device).pitch == value else { throw AudioFailure("BlackHole did not confirm its exact pitch setting.") }
    }

    public func acquire() throws {
        guard journal == nil else { throw AudioFailure("The virtual clock is already managed.") }
        let journal = try ExclusiveRecoveryJournal(resource: .init(kind: .clock, uid: outputUID), directory: journalDirectory)
        self.journal = journal
        do {
            _ = try journal.perform(.selector("Internal Adjustable"))
            _ = try setPitch(0.5)
        } catch {
            let recovery = restore()
            if recovery.isEmpty { throw error }
            throw AudioFailure(error.localizedDescription + " Recovery: " + recovery.joined(separator: " "))
        }
    }
    /// Coalesces requests to at most 10 writes/second; every applied value has a pending record first.
    @discardableResult public func setPitch(_ value: Float) throws -> Float {
        guard value.isFinite, value >= 0, value <= 1, let journal else { throw AudioFailure("Invalid virtual-clock adjustment.") }
        try journal.validate()
        if case .clock(let actual) = journal.confirmed, let pitch = actual.pitch { currentPitch = pitch }
        let now = ProcessInfo.processInfo.systemUptime
        guard value != currentPitch, now - lastPitchWrite >= 0.1 else { return currentPitch }
        guard case .clock(let actual) = try journal.perform(.pitch(value)), let pitch = actual.pitch else {
            throw AudioFailure("The virtual clock did not return an exact pitch.")
        }
        currentPitch = pitch; lastPitchWrite = now
        return currentPitch
    }
    public func validate() throws {
        guard let journal else { throw AudioFailure("The virtual clock is not managed.") }
        try journal.validate()
    }
    @discardableResult public func restore() -> [String] {
        let errors = journal?.restore() ?? []
        journal = nil; lastPitchWrite = -.infinity
        return errors
    }
}
