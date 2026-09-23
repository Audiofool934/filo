import CoreAudio
import Darwin
import Foundation
import XCTest
@testable import FiloCore

/// The fake models coupled driver changes and failure windows without touching audio hardware.
final class ExclusiveRecoveryJournalTests: XCTestCase {
    private let output = ExclusiveRecoveryResource(kind: .output, uid: "test-dac-persistent-uid")
    private let clock = ExclusiveRecoveryResource(kind: .clock, uid: "BlackHole-test-persistent-uid")

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("filo-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }
    private func records(_ directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
    }
    private func format(_ rate: Double, flags: UInt32) -> RecoveryPCMFormat {
        RecoveryPCMFormat(AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: flags, mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0))
    }
    private var initial: ExclusiveRecoveryState {
        .output(RecoveryOutputState(rate: 192_000, physical: format(192_000, flags: 12), virtual: format(192_000, flags: 9)))
    }
    private func prepare(_ journal: ExclusiveRecoveryJournal) throws {
        try journal.perform(.rate(44_100))
        try journal.perform(.physical(format(44_100, flags: 76)))
        try journal.perform(.virtual(format(44_100, flags: 76)))
    }

    func testCrashBetweenWriteAndConfirmationRestoresCoupledState() throws {
        let directory = try temporaryDirectory(), fake = FakeRecoveryAccess(uid: output.uid, state: initial)
        var journal: ExclusiveRecoveryJournal? = try ExclusiveRecoveryJournal(resource: output, access: fake, directory: directory)
        fake.failAfterNextWrite = true
        fake.beforeWrite = {
            let saved = try Data(contentsOf: self.records(directory).first!)
            XCTAssertTrue(String(decoding: saved, as: UTF8.self).contains("\"pending\""))
        }
        XCTAssertThrowsError(try journal!.perform(.rate(44_100)))
        XCTAssertNotEqual(fake.state, initial)
        journal = nil
        fake.owner = .none // A process exit releases Hog Mode, while the persisted pending intent survives.
        XCTAssertEqual(ExclusiveRecoveryJournal.recoverOrphaned(access: fake, directory: directory), [])
        XCTAssertEqual(fake.state, initial)
        XCTAssertTrue(try records(directory).isEmpty)
    }

    func testPhysicalRestoreMayAlsoRestoreOriginalFloatVirtualFormat() throws {
        let directory = try temporaryDirectory(), fake = FakeRecoveryAccess(uid: output.uid, state: initial)
        let journal = try ExclusiveRecoveryJournal(resource: output, access: fake, directory: directory)
        try prepare(journal)
        fake.writes.removeAll()
        XCTAssertTrue(journal.restore().isEmpty)
        XCTAssertEqual(fake.state, initial)
        XCTAssertEqual(fake.writes, [.rate(192_000), .physical(format(192_000, flags: 12)), .virtual(format(192_000, flags: 9))])
        XCTAssertEqual(fake.owner, .none)
        XCTAssertTrue(try records(directory).isEmpty)
    }

    func testRestoreCrashAfterPhysicalCouplingRecognizesWholeOriginalState() throws {
        let directory = try temporaryDirectory(), fake = FakeRecoveryAccess(uid: output.uid, state: initial)
        var journal: ExclusiveRecoveryJournal? = try ExclusiveRecoveryJournal(resource: output, access: fake, directory: directory)
        try prepare(journal!)
        fake.failAfterMutation = .physical(format(192_000, flags: 12))
        XCTAssertFalse(journal!.restore().isEmpty)
        XCTAssertEqual(fake.state, initial)
        XCTAssertEqual(try records(directory).count, 1)
        journal = nil
        XCTAssertEqual(ExclusiveRecoveryJournal.recoverOrphaned(access: fake, directory: directory), [])
        XCTAssertEqual(fake.state, initial)
        XCTAssertTrue(try records(directory).isEmpty)
    }

    func testFailureBeforeHardwareWriteRetainsPriorOwnedState() throws {
        let directory = try temporaryDirectory(), fake = FakeRecoveryAccess(uid: output.uid, state: initial)
        var journal: ExclusiveRecoveryJournal? = try ExclusiveRecoveryJournal(resource: output, access: fake, directory: directory)
        try prepare(journal!)
        fake.failBeforeNextWrite = true
        XCTAssertThrowsError(try journal!.perform(.rate(48_000)))
        journal = nil; fake.owner = .none
        XCTAssertEqual(ExclusiveRecoveryJournal.recoverOrphaned(access: fake, directory: directory), [])
        XCTAssertEqual(fake.state, initial)
    }

    func testExternalOutputChangePreservesEntireCoupledGroup() throws {
        let directory = try temporaryDirectory(), fake = FakeRecoveryAccess(uid: output.uid, state: initial)
        let journal = try ExclusiveRecoveryJournal(resource: output, access: fake, directory: directory)
        try prepare(journal)
        guard case .output(var changed) = fake.state else { return XCTFail("Expected output state") }
        changed.virtual = format(44_100, flags: 9)
        fake.state = .output(changed)
        let externalState = fake.state, writeCount = fake.writes.count
        XCTAssertThrowsError(try journal.validate())
        XCTAssertFalse(journal.restore().isEmpty)
        XCTAssertEqual(fake.state, externalState)
        XCTAssertEqual(fake.writes.count, writeCount)
        XCTAssertTrue(try records(directory).isEmpty)
    }

    func testExternalPitchPreservesSelectorAndPitch() throws {
        let directory = try temporaryDirectory()
        let fake = FakeRecoveryAccess(uid: clock.uid, state: .clock(.init(selector: "Internal Fixed", pitch: nil)))
        let journal = try ExclusiveRecoveryJournal(resource: clock, access: fake, directory: directory)
        try journal.perform(.selector("Internal Adjustable"))
        try journal.perform(.pitch(0.51))
        fake.state = .clock(.init(selector: "Internal Adjustable", pitch: 0.6))
        let writeCount = fake.writes.count
        XCTAssertFalse(journal.restore().isEmpty)
        XCTAssertEqual(fake.state, .clock(.init(selector: "Internal Adjustable", pitch: 0.6)))
        XCTAssertEqual(fake.writes.count, writeCount)
        XCTAssertTrue(try records(directory).isEmpty)
    }

    func testClockSelectorCrashWithNewlyMaterializedPitchIsRecoverable() throws {
        let directory = try temporaryDirectory()
        let initial = ExclusiveRecoveryState.clock(.init(selector: "Internal Fixed", pitch: nil))
        let fake = FakeRecoveryAccess(uid: clock.uid, state: initial)
        fake.hiddenPitch = 0.57
        var journal: ExclusiveRecoveryJournal? = try ExclusiveRecoveryJournal(resource: clock, access: fake, directory: directory)
        fake.failAfterNextWrite = true
        XCTAssertThrowsError(try journal!.perform(.selector("Internal Adjustable")))
        journal = nil
        XCTAssertEqual(ExclusiveRecoveryJournal.recoverOrphaned(access: fake, directory: directory), [])
        XCTAssertEqual(fake.state, initial)
    }

    func testMissingDeviceDefersAndReconnectResolvesUIDToNewDeviceID() throws {
        let directory = try temporaryDirectory(), fake = FakeRecoveryAccess(uid: output.uid, state: initial)
        var journal: ExclusiveRecoveryJournal? = try ExclusiveRecoveryJournal(resource: output, access: fake, directory: directory)
        try prepare(journal!)
        journal = nil; fake.owner = .none; fake.present = false
        let writesBefore = fake.writes.count
        XCTAssertFalse(ExclusiveRecoveryJournal.recoverOrphaned(access: fake, directory: directory).isEmpty)
        XCTAssertEqual(try records(directory).count, 1)
        XCTAssertEqual(fake.writes.count, writesBefore)
        fake.present = true; fake.deviceID = 700
        fake.appliedDeviceIDs.removeAll()
        XCTAssertEqual(ExclusiveRecoveryJournal.recoverOrphaned(access: fake, directory: directory), [])
        XCTAssertEqual(fake.state, initial)
        XCTAssertEqual(fake.appliedDeviceIDs, [700, 700, 700])
        XCTAssertTrue(try records(directory).isEmpty)
    }

    func testForeignOwnerDefersWithoutWritesAndLaterRecovers() throws {
        let directory = try temporaryDirectory(), fake = FakeRecoveryAccess(uid: output.uid, state: initial)
        var journal: ExclusiveRecoveryJournal? = try ExclusiveRecoveryJournal(resource: output, access: fake, directory: directory)
        try prepare(journal!)
        journal = nil; fake.owner = .foreign
        let writeCount = fake.writes.count
        XCTAssertFalse(ExclusiveRecoveryJournal.recoverOrphaned(access: fake, directory: directory).isEmpty)
        XCTAssertEqual(fake.writes.count, writeCount)
        XCTAssertEqual(fake.owner, .foreign)
        XCTAssertEqual(try records(directory).count, 1)
        fake.owner = .none
        XCTAssertEqual(ExclusiveRecoveryJournal.recoverOrphaned(access: fake, directory: directory), [])
        XCTAssertEqual(fake.state, initial)
    }

    func testLockContentionRefusesBeforeReadingOrMutatingHardware() throws {
        let directory = try temporaryDirectory(), fake = FakeRecoveryAccess(uid: output.uid, state: initial)
        let descriptor = open(directory.appendingPathComponent("session.lock").path, O_RDWR | O_CREAT, 0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        XCTAssertThrowsError(try ExclusiveRecoveryJournal(resource: output, access: fake, directory: directory))
        XCTAssertEqual(fake.readCount, 0)
        XCTAssertTrue(fake.writes.isEmpty)
        XCTAssertTrue(try records(directory).isEmpty)
    }

    func testActiveRecordCannotBeReplacedAndFilesArePrivate() throws {
        let directory = try temporaryDirectory(), fake = FakeRecoveryAccess(uid: output.uid, state: initial)
        let journal = try ExclusiveRecoveryJournal(resource: output, access: fake, directory: directory)
        let url = try XCTUnwrap(records(directory).first)
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try ExclusiveRecoveryJournal(resource: output, access: fake, directory: directory))
        XCTAssertEqual(try Data(contentsOf: url), before)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertFalse(url.lastPathComponent.contains(output.uid))
        XCTAssertEqual(ExclusiveRecoveryJournal.recoverOrphaned(access: fake, directory: directory), [])
        XCTAssertEqual(try records(directory).count, 1) // Same-process recovery must skip active leases.
        XCTAssertTrue(journal.restore().isEmpty)
    }
}

private final class FakeRecoveryAccess: ExclusiveRecoveryAccess {
    enum Owner { case none, ours, foreign }
    let uid: String
    var state: ExclusiveRecoveryState
    var present = true, deviceID: UInt32 = 100
    var owner = Owner.none
    var writes: [ExclusiveRecoveryMutation] = [], appliedDeviceIDs: [UInt32] = []
    var readCount = 0
    var hiddenPitch: Float = 0.5
    var failBeforeNextWrite = false, failAfterNextWrite = false
    var failAfterMutation: ExclusiveRecoveryMutation?
    var beforeWrite: (() throws -> Void)?
    init(uid: String, state: ExclusiveRecoveryState) { self.uid = uid; self.state = state }
    func read(_ resource: ExclusiveRecoveryResource) throws -> ExclusiveRecoveryState? {
        readCount += 1
        return present && resource.uid == uid ? state : nil
    }
    func acquireOwnership(_ resource: ExclusiveRecoveryResource) throws {
        guard resource.kind == .output else { return }
        guard present, resource.uid == uid, owner != .foreign else { throw AudioFailure("Fake device is unavailable or owned externally") }
        owner = .ours
    }
    func releaseOwnership(_ resource: ExclusiveRecoveryResource) throws {
        if resource.kind == .output, owner == .ours { owner = .none }
    }
    func apply(_ mutation: ExclusiveRecoveryMutation, to resource: ExclusiveRecoveryResource) throws {
        guard present, resource.uid == uid, resource.kind != .output || owner == .ours else { throw AudioFailure("Fake device is unavailable") }
        try beforeWrite?()
        if failBeforeNextWrite { failBeforeNextWrite = false; throw AudioFailure("Simulated failure before hardware write") }
        writes.append(mutation); appliedDeviceIDs.append(deviceID)
        switch (state, mutation) {
        case (.output(var value), .rate(let rate)):
            value.rate = rate; value.physical = value.physical.atRate(rate); value.virtual = value.physical
            state = .output(value)
        case (.output(var value), .physical(let format)):
            value.physical = format; value.rate = format.rate; value.virtual = format
            if format.flags == 12 {
                var floating = format.asbd; floating.mFormatFlags = 9
                value.virtual = RecoveryPCMFormat(floating)
            }
            state = .output(value)
        case (.output(var value), .virtual(let format)):
            value.virtual = format; state = .output(value)
        case (.clock, .selector(let selector)):
            state = .clock(.init(selector: selector, pitch: selector == "Internal Adjustable" ? hiddenPitch : nil))
        case (.clock(var value), .pitch(let pitch)):
            guard value.selector == "Internal Adjustable" else { throw AudioFailure("Fake pitch control is hidden") }
            value.pitch = pitch; hiddenPitch = pitch; state = .clock(value)
        default: throw AudioFailure("Invalid fake mutation")
        }
        if failAfterNextWrite || failAfterMutation == mutation {
            failAfterNextWrite = false; failAfterMutation = nil
            throw AudioFailure("Simulated process interruption after hardware write and before confirmation")
        }
    }
}
