import CoreAudio
import CryptoKit
import Darwin
import Foundation

public struct RecoveryPCMFormat: Codable, Equatable {
    public let rate: Double
    public let formatID, flags, bytesPerPacket, framesPerPacket, bytesPerFrame, channels, bits: UInt32
    public init(_ value: AudioStreamBasicDescription) {
        rate = value.mSampleRate; formatID = value.mFormatID; flags = value.mFormatFlags
        bytesPerPacket = value.mBytesPerPacket; framesPerPacket = value.mFramesPerPacket
        bytesPerFrame = value.mBytesPerFrame; channels = value.mChannelsPerFrame; bits = value.mBitsPerChannel
    }
    public var asbd: AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: rate, mFormatID: formatID, mFormatFlags: flags,
            mBytesPerPacket: bytesPerPacket, mFramesPerPacket: framesPerPacket, mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channels, mBitsPerChannel: bits, mReserved: 0)
    }
    func atRate(_ value: Double) -> Self { var f = asbd; f.mSampleRate = value; return Self(f) }
    var valid: Bool {
        rate.isFinite && rate >= 8_000 && rate <= 768_000 && formatID == kAudioFormatLinearPCM
        && channels == 2 && bits > 0 && bits <= 64 && framesPerPacket == 1
        && bytesPerFrame > 0 && bytesPerFrame <= 16 && bytesPerPacket == bytesPerFrame
    }
}

public struct RecoveryOutputState: Codable, Equatable {
    public var rate: Double
    public var physical, virtual: RecoveryPCMFormat
    public init(rate: Double, physical: RecoveryPCMFormat, virtual: RecoveryPCMFormat) {
        self.rate = rate; self.physical = physical; self.virtual = virtual
    }
}

public struct RecoveryClockState: Codable, Equatable {
    public var selector: String
    public var pitch: Float?
    public init(selector: String, pitch: Float?) { self.selector = selector; self.pitch = pitch }
}

public enum ExclusiveRecoveryState: Codable, Equatable {
    case output(RecoveryOutputState)
    case clock(RecoveryClockState)
    var valid: Bool {
        switch self {
        case .output(let v): return v.rate.isFinite && v.rate >= 8_000 && v.rate <= 768_000 && v.physical.valid && v.virtual.valid
        case .clock(let v): return !v.selector.isEmpty && v.selector.count <= 128 && (v.pitch.map { $0.isFinite && $0 >= 0 && $0 <= 1 } ?? true)
        }
    }
}

public struct ExclusiveRecoveryResource: Codable, Equatable {
    public enum Kind: String, Codable { case output, clock }
    public let kind: Kind
    public let uid: String
    public init(kind: Kind, uid: String) { self.kind = kind; self.uid = uid }
}

public enum ExclusiveRecoveryMutation: Codable, Equatable {
    case rate(Double)
    case physical(RecoveryPCMFormat)
    case virtual(RecoveryPCMFormat)
    case selector(String)
    case pitch(Float)
}

/// Every access resolves the persistent UID and current stream/control objects again.
public protocol ExclusiveRecoveryAccess: AnyObject {
    func read(_ resource: ExclusiveRecoveryResource) throws -> ExclusiveRecoveryState?
    func acquireOwnership(_ resource: ExclusiveRecoveryResource) throws
    func releaseOwnership(_ resource: ExclusiveRecoveryResource) throws
    func apply(_ mutation: ExclusiveRecoveryMutation, to resource: ExclusiveRecoveryResource) throws
}

private final class RecoveryCoordinator {
    private final class Weak { weak var value: RecoveryCoordinator?; init(_ value: RecoveryCoordinator) { self.value = value } }
    private static let registryLock = NSLock()
    private static var registry: [String: Weak] = [:]
    let directory: URL
    let ownerToken = UUID().uuidString
    private let descriptor: Int32
    private let mutex = NSRecursiveLock()
    var active = Set<String>()
    static func shared(_ directory: URL) throws -> RecoveryCoordinator {
        registryLock.lock(); defer { registryLock.unlock() }
        let key = directory.standardizedFileURL.path
        if let value = registry[key]?.value { return value }
        let value = try RecoveryCoordinator(directory)
        registry[key] = Weak(value)
        return value
    }
    private init(_ directory: URL) throws {
        self.directory = directory.standardizedFileURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFDIR else {
            throw AudioFailure("The recovery directory must be owned by this user and cannot be a symbolic link.")
        }
        descriptor = open(directory.appendingPathComponent("session.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw AudioFailure("Could not open the exclusive recovery lock.") }
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw AudioFailure("Another filo process owns exclusive audio recovery, or the lock file is invalid.")
        }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
    func locked<T>(_ body: () throws -> T) rethrows -> T { mutex.lock(); defer { mutex.unlock() }; return try body() }
    func url(for resource: ExclusiveRecoveryResource) -> URL {
        let key = Data("\(resource.kind.rawValue):\(resource.uid)".utf8)
        let name = SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".json")
    }
    /// Atomic for process crashes; deliberately no per-tick fsync or power-loss guarantee.
    func save(_ data: Data, at url: URL) throws {
        guard data.count <= 32_768 else { throw AudioFailure("The recovery record exceeds its size limit.") }
        let temporary = directory.appendingPathComponent(".pending-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AudioFailure("Could not prepare the recovery record.") }
        defer { close(fd); unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw AudioFailure("Could not write the recovery record.") }
                offset += written
            }
        }
        guard rename(temporary.path, url.path) == 0 else { throw AudioFailure("Could not commit the recovery record.") }
    }
    func data(at url: URL) throws -> Data {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0 && info.st_size <= 32_768 else { throw AudioFailure("The saved recovery record is invalid.") }
        return try Data(contentsOf: url)
    }
}

/// Coupled output state is restored as a group, never by independently matching sibling fields.
public final class ExclusiveRecoveryJournal {
    private struct Pending: Codable {
        let before: ExclusiveRecoveryState
        let mutation: ExclusiveRecoveryMutation
        let anticipated: [ExclusiveRecoveryState]
    }
    private struct Record: Codable {
        let version: Int
        var ownerPID: Int32
        var ownerToken: String
        let resource: ExclusiveRecoveryResource
        let original: ExclusiveRecoveryState
        var confirmed: ExclusiveRecoveryState
        var pending: Pending?
    }
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("filo/exclusive-recovery", isDirectory: true)
    }
    private let coordinator: RecoveryCoordinator
    private let access: ExclusiveRecoveryAccess
    private let url: URL
    private var record: Record
    private var finished = false
    private var isRestoring = false
    private var registeredActive = false
    public var original: ExclusiveRecoveryState { record.original }
    public var confirmed: ExclusiveRecoveryState { record.confirmed }

    public init(resource: ExclusiveRecoveryResource,
                access: ExclusiveRecoveryAccess = SystemExclusiveRecoveryAccess(),
                directory: URL = defaultDirectory) throws {
        coordinator = try RecoveryCoordinator.shared(directory); self.access = access
        url = coordinator.url(for: resource)
        guard !resource.uid.isEmpty, resource.uid.count <= 1_024,
              let state = try access.read(resource), state.valid else { throw AudioFailure("The recovery target is missing or unsupported.") }
        record = Record(version: 1, ownerPID: getpid(), ownerToken: coordinator.ownerToken,
                        resource: resource, original: state, confirmed: state, pending: nil)
        try coordinator.locked {
            guard !coordinator.active.contains(url.standardizedFileURL.path), !FileManager.default.fileExists(atPath: url.path) else {
                throw AudioFailure("This audio device has an active or unresolved recovery record. Recover it before connecting.")
            }
            try persist()
            coordinator.active.insert(url.standardizedFileURL.path)
            registeredActive = true
        }
        do { try access.acquireOwnership(resource) }
        catch { _ = restore(); throw error }
    }
    private init(record: Record, coordinator: RecoveryCoordinator, access: ExclusiveRecoveryAccess, url: URL) {
        self.record = record; self.coordinator = coordinator; self.access = access; self.url = url
    }
    deinit { if registeredActive { _ = coordinator.locked { coordinator.active.remove(url.standardizedFileURL.path) } } }
    private func persist() throws { try coordinator.save(JSONEncoder().encode(record), at: url) }

    private static func anticipated(_ change: ExclusiveRecoveryMutation, from state: ExclusiveRecoveryState) throws -> [ExclusiveRecoveryState] {
        switch (state, change) {
        case (.output(let before), .rate(let rate)):
            guard rate.isFinite, rate >= 8_000, rate <= 768_000 else { throw AudioFailure("Invalid recovery rate.") }
            // Drivers can publish the three coupled rate updates at different times.
            return [before.rate, rate].flatMap { nominal in
                [before.physical, before.physical.atRate(rate)].flatMap { physical in
                    [before.virtual, before.virtual.atRate(rate), before.physical, before.physical.atRate(rate)].map { virtual in
                        .output(RecoveryOutputState(rate: nominal, physical: physical, virtual: virtual))
                    }
                }
            }
        case (.output(let before), .physical(let target)):
            guard target.valid else { throw AudioFailure("Invalid recovery physical format.") }
            let physicalOptions = [before.physical, target]
            let virtualOptions = [before.virtual, before.virtual.atRate(target.rate), target]
            return physicalOptions.flatMap { physical in virtualOptions.flatMap { virtual in
                [before.rate, target.rate].map { .output(RecoveryOutputState(rate: $0, physical: physical, virtual: virtual)) }
            } }
        case (.output(let before), .virtual(let target)):
            guard target.valid else { throw AudioFailure("Invalid recovery virtual format.") }
            return [before.virtual, target].flatMap { virtual in
                [before.physical, before.physical.atRate(target.rate)].flatMap { physical in
                    [before.rate, target.rate].map { .output(RecoveryOutputState(rate: $0, physical: physical, virtual: virtual)) }
                }
            }
        case (.clock(let before), .selector(let selector)):
            guard !selector.isEmpty, selector.count <= 128 else { throw AudioFailure("Invalid clock selector.") }
            // BlackHole's pitch value is not observable while the adjustable clock is hidden.
            // A newly exposed pitch is not adopted here; the adapter separately records its exact readback.
            return [.clock(before), .clock(RecoveryClockState(selector: selector, pitch: before.pitch)),
                    .clock(RecoveryClockState(selector: selector, pitch: nil))]
        case (.clock(let before), .pitch(let pitch)):
            guard pitch.isFinite, pitch >= 0, pitch <= 1 else { throw AudioFailure("Invalid recovery pitch.") }
            return [.clock(before), .clock(RecoveryClockState(selector: before.selector, pitch: pitch))]
        default: throw AudioFailure("The recovery mutation does not match its resource.")
        }
    }

    private func matchesOwned(_ state: ExclusiveRecoveryState) -> Bool {
        if state == record.confirmed { return true }
        if let pending = record.pending {
            if state == pending.before || pending.anticipated.contains(state) { return true }
            // Selecting BlackHole's adjustable clock materializes a pre-existing pitch control.
            // Only the selector is owned at this stage; no pitch mutation has happened yet.
            if case .selector(let selected) = pending.mutation,
               case .clock(let before) = pending.before, before.pitch == nil,
               case .clock(let actual) = state, actual.selector == selected { return true }
        }
        return false
    }

    @discardableResult public func perform(_ mutation: ExclusiveRecoveryMutation) throws -> ExclusiveRecoveryState {
        try coordinator.locked {
            guard !finished, let before = try access.read(record.resource), matchesOwned(before) else {
                throw AudioFailure("Audio configuration changed outside filo; the recovery lease no longer owns it.")
            }
            var alternatives = try Self.anticipated(mutation, from: before).reduce(into: [ExclusiveRecoveryState]()) {
                if !$0.contains($1) { $0.append($1) }
            }
            // Restoring a mixable physical format can also restore the driver's original float callback format.
            // Persist this exact whole-group result before writing, including the write/readback crash window.
            if isRestoring, !alternatives.contains(record.original) { alternatives.append(record.original) }
            record.pending = Pending(before: before, mutation: mutation, anticipated: alternatives)
            try persist()
            try access.apply(mutation, to: record.resource)
            guard let after = try access.read(record.resource), after.valid, matchesOwned(after) else {
                throw AudioFailure("The hardware changed to an unrecognized state; its recovery record was retained.")
            }
            record.confirmed = after
            record.pending = nil
            try persist()
            return after
        }
    }

    public func validate() throws {
        try coordinator.locked {
            guard !finished, let actual = try access.read(record.resource), actual == record.confirmed else {
                throw AudioFailure("The exclusive audio configuration changed outside filo.")
            }
        }
    }

    /// Caller stops all IO first. Failures and missing devices retain the exact pending record.
    @discardableResult public func restore() -> [String] {
        coordinator.locked {
            if finished { return [] }
            var errors: [String] = []
            do {
                guard let current = try access.read(record.resource) else {
                    return ["Audio recovery is deferred until the device reconnects."]
                }
                if current == record.original {
                    try access.releaseOwnership(record.resource)
                    try complete(); return []
                }
                guard matchesOwned(current) else {
                    // A different actor's change terminates ownership; never retry it later.
                    try access.releaseOwnership(record.resource)
                    try complete()
                    return ["Preserved audio configuration changed outside filo."]
                }
                try access.acquireOwnership(record.resource)
                isRestoring = true
                defer { isRestoring = false }
                // Rate first, physical second, virtual last: restoring rate last can reset virtual format.
                switch record.original {
                case .output(let original):
                    _ = try perform(.rate(original.rate))
                    _ = try perform(.physical(original.physical))
                    _ = try perform(.virtual(original.virtual))
                case .clock(let original):
                    if let pitch = original.pitch { _ = try perform(.pitch(pitch)) }
                    _ = try perform(.selector(original.selector))
                }
                guard try access.read(record.resource) == record.original else {
                    throw AudioFailure("The complete original audio configuration was not restored.")
                }
                try access.releaseOwnership(record.resource)
                try complete()
            } catch {
                errors.append(error.localizedDescription)
                do { try access.releaseOwnership(record.resource) } catch { errors.append(error.localizedDescription) }
            }
            return errors
        }
    }
    private func complete() throws {
        try FileManager.default.removeItem(at: url)
        if registeredActive { coordinator.active.remove(url.standardizedFileURL.path); registeredActive = false }
        finished = true
    }

    public static func recoverOrphaned(access: ExclusiveRecoveryAccess = SystemExclusiveRecoveryAccess(),
                                       directory: URL = defaultDirectory) -> [String] {
        do {
            let coordinator = try RecoveryCoordinator.shared(directory)
            return try coordinator.locked {
                let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                guard urls.count <= 64 else { throw AudioFailure("There are too many unresolved audio recovery records.") }
                var errors: [String] = []
                for url in urls where !coordinator.active.contains(url.standardizedFileURL.path) {
                    do {
                        let record = try JSONDecoder().decode(Record.self, from: coordinator.data(at: url))
                        guard record.version == 1, !record.resource.uid.isEmpty, record.resource.uid.count <= 1_024,
                              record.original.valid, record.confirmed.valid,
                              record.pending.map({ $0.before.valid && $0.anticipated.count <= 32 && $0.anticipated.allSatisfy(\.valid) }) ?? true
                        else { throw AudioFailure("The saved exclusive audio record is invalid.") }
                        guard coordinator.url(for: record.resource).standardizedFileURL.path == url.standardizedFileURL.path else {
                            throw AudioFailure("The saved exclusive audio record does not match its persistent device UID.")
                        }
                        let journal = ExclusiveRecoveryJournal(record: record, coordinator: coordinator, access: access, url: url)
                        errors += journal.restore()
                    } catch { errors.append(error.localizedDescription) }
                }
                return errors
            }
        } catch { return [error.localizedDescription] }
    }
}

public final class SystemExclusiveRecoveryAccess: ExclusiveRecoveryAccess {
    public init() {}
    static func output(uid: String) throws -> OutputDevice? { try HAL.outputDevices().first { $0.uid == uid } }
    static func stream(_ output: OutputDevice) throws -> AudioObjectID {
        let streams = try HAL.array(output.id, kAudioDevicePropertyStreams, seed: AudioObjectID(0), scope: kAudioObjectPropertyScopeOutput)
        guard streams.count == 1 else { throw AudioFailure("Recovery requires the same single stereo output stream.") }
        return streams[0]
    }
    public func read(_ resource: ExclusiveRecoveryResource) throws -> ExclusiveRecoveryState? {
        guard let device = try Self.output(uid: resource.uid) else { return nil }
        switch resource.kind {
        case .output:
            let stream = try Self.stream(device)
            return .output(RecoveryOutputState(rate: try HAL.rate(device.id),
                physical: RecoveryPCMFormat(try HAL.value(stream, kAudioStreamPropertyPhysicalFormat, default: AudioStreamBasicDescription())),
                virtual: RecoveryPCMFormat(try HAL.value(stream, kAudioStreamPropertyVirtualFormat, default: AudioStreamBasicDescription()))))
        case .clock: return .clock(try VirtualClock.readState(device))
        }
    }
    public func acquireOwnership(_ resource: ExclusiveRecoveryResource) throws {
        guard resource.kind == .output else { return }
        guard let device = try Self.output(uid: resource.uid) else { throw AudioFailure("The recovery output is disconnected.") }
        let owner = try HAL.value(device.id, kAudioDevicePropertyHogMode, default: Int32(-1))
        if owner == getpid() { return }
        guard owner == -1 else { throw AudioFailure("The output belongs to another process; recovery is deferred.") }
        try HAL.set(device.id, kAudioDevicePropertyHogMode, getpid())
        guard try HAL.value(device.id, kAudioDevicePropertyHogMode, default: Int32(-1)) == getpid() else {
            throw AudioFailure("Recovery could not acquire the output.")
        }
    }
    public func releaseOwnership(_ resource: ExclusiveRecoveryResource) throws {
        guard resource.kind == .output, let device = try Self.output(uid: resource.uid) else { return }
        if try HAL.value(device.id, kAudioDevicePropertyHogMode, default: Int32(-1)) == getpid() {
            try HAL.set(device.id, kAudioDevicePropertyHogMode, Int32(-1))
        }
    }
    public func apply(_ mutation: ExclusiveRecoveryMutation, to resource: ExclusiveRecoveryResource) throws {
        guard let device = try Self.output(uid: resource.uid) else { throw AudioFailure("The recovery device is disconnected.") }
        if resource.kind == .output {
            guard try HAL.value(device.id, kAudioDevicePropertyHogMode, default: Int32(-1)) == getpid() else {
                throw AudioFailure("The output no longer belongs to this process.")
            }
        }
        switch mutation {
        case .rate(let rate): try HAL.setRate(device.id, to: rate)
        case .physical(let format): try AudioFormats.setAndConfirm(try Self.stream(device), kAudioStreamPropertyPhysicalFormat, format.asbd)
        case .virtual(let format): try AudioFormats.setAndConfirm(try Self.stream(device), kAudioStreamPropertyVirtualFormat, format.asbd)
        case .selector(let selector): try VirtualClock.writeSelector(selector, device: device)
        case .pitch(let pitch): try VirtualClock.writePitch(pitch, device: device)
        }
    }
}
