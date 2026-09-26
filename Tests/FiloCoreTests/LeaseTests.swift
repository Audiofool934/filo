import XCTest
@testable import FiloCore

private final class FakeDevices: DeviceAccess {
    var outputs = [OutputDevice(id: 1, uid: "speakers", name: "Speakers", rate: 48000, supportedRates: [44100, 48000], formats: [], hogPID: -1, isDefault: true, transport: 0),
                   OutputDevice(id: 2, uid: "dac", name: "DAC", rate: 192000, supportedRates: [44100, 48000, 192000], formats: [], hogPID: -1, isDefault: false, transport: 0)]
    var current: UInt32 = 1
    var writes: [Double] = []
    var failRate = false
    var failedDefaultReads = 0
    func devices() -> [OutputDevice] { outputs }
    func defaultOutput() throws -> UInt32 {
        if failedDefaultReads > 0 {
            failedDefaultReads -= 1
            throw AudioFailure("Could not read default output")
        }
        return current
    }
    func setDefaultOutput(_ id: UInt32) { current = id }
    func rate(_ id: UInt32) throws -> Double {
        guard let device = outputs.first(where: { $0.id == id }) else { throw AudioFailure("Disconnected") }
        return device.rate
    }
    func setRate(_ id: UInt32, _ rate: Double) throws {
        if failRate { throw AudioFailure("Refused") }
        guard let index = outputs.firstIndex(where: { $0.id == id }) else { throw AudioFailure("Disconnected") }
        outputs[index].rate = rate; writes.append(rate)
    }
}

final class LeaseTests: XCTestCase {
    func testStaleSelectionCannotRouteToReusedHardwareID() throws {
        let devices = FakeDevices()
        let selected = devices.outputs[1]
        devices.outputs[1].uid = "unrelated"
        let lease = DeviceLease(access: devices)
        XCTAssertThrowsError(try lease.begin(output: selected))
        XCTAssertNil(lease.outputUID)
        XCTAssertEqual(devices.current, 1)
        XCTAssertTrue(devices.writes.isEmpty)
    }
    func testBeginResolvesReconnectedSelectionByUID() throws {
        let devices = FakeDevices()
        let selected = devices.outputs[1]
        devices.outputs[1].uid = "unrelated"
        var reconnected = selected
        reconnected.id = 9
        reconnected.rate = 48000
        devices.outputs.append(reconnected)
        let lease = DeviceLease(access: devices)
        try lease.begin(output: selected)
        XCTAssertEqual(devices.current, 9)
        try lease.apply(rate: 44100)
        XCTAssertTrue(lease.restore().isEmpty)
        XCTAssertEqual(try devices.rate(9), 48000)
        XCTAssertEqual(try devices.rate(2), 192000)
        XCTAssertEqual(devices.current, 1)
    }
    func testUnreadableOriginalRoutePreventsConnection() throws {
        let devices = FakeDevices()
        devices.failedDefaultReads = 1
        let lease = DeviceLease(access: devices)
        XCTAssertThrowsError(try lease.begin(output: devices.outputs[1]))
        XCTAssertNil(lease.outputUID)
        XCTAssertEqual(devices.current, 1)
    }
    func testDoesNotOverwriteUserRateBeforeFirstWrite() throws {
        let devices = FakeDevices()
        let lease = DeviceLease(access: devices)
        try lease.begin(output: devices.outputs[1])
        devices.outputs[1].rate = 48000
        XCTAssertThrowsError(try lease.apply(rate: 44100))
        XCTAssertTrue(lease.restore().isEmpty)
        XCTAssertEqual(try devices.rate(2), 48000)
        XCTAssertTrue(devices.writes.isEmpty)
        XCTAssertEqual(devices.current, 1)
    }
    func testAlreadyMatchedRateDoesNotHideLaterExternalChange() throws {
        let devices = FakeDevices()
        let lease = DeviceLease(access: devices)
        try lease.begin(output: devices.outputs[1])
        try lease.apply(rate: 192000)
        devices.outputs[1].rate = 48000
        XCTAssertThrowsError(try lease.apply(rate: 48000))
        XCTAssertTrue(lease.restore().isEmpty)
        XCTAssertEqual(try devices.rate(2), 48000)
        XCTAssertTrue(devices.writes.isEmpty)
    }
    func testCrashRecoveryRestoresOnlyOrphanedOwnedChanges() throws {
        let devices = FakeDevices()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let journal = folder.appendingPathComponent("connection.json")
        defer { try? FileManager.default.removeItem(at: folder) }
        let lease = DeviceLease(access: devices, journalURL: journal)
        try lease.begin(output: devices.outputs[1]); try lease.apply(rate: 44100)
        XCTAssertFalse(DeviceLease(access: devices, journalURL: journal).recoverOrphaned().isEmpty)
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any])
        record["ownerPID"] = 0
        try JSONSerialization.data(withJSONObject: record).write(to: journal)
        XCTAssertTrue(DeviceLease(access: devices, journalURL: journal).recoverOrphaned().isEmpty)
        XCTAssertEqual(try devices.rate(2), 192000)
        XCTAssertEqual(devices.current, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }
    func testRestoresOwnedRateAndDefault() throws {
        let devices = FakeDevices()
        let owned = DeviceLease(access: devices)
        try owned.begin(output: devices.outputs[1])
        try owned.apply(rate: 44100)
        try owned.apply(rate: 44100)
        XCTAssertEqual(devices.writes, [44100])
        XCTAssertEqual(devices.current, 2)
        XCTAssertTrue(owned.restore().isEmpty)
        XCTAssertEqual(try devices.rate(2), 192000)
        XCTAssertEqual(devices.current, 1)
    }
    func testDoesNotOverwriteInterveningUserRateOrRoute() throws {
        let devices = FakeDevices()
        let owned = DeviceLease(access: devices)
        try owned.begin(output: devices.outputs[1]); try owned.apply(rate: 44100)
        devices.outputs[1].rate = 48000; devices.current = 1
        XCTAssertThrowsError(try owned.apply(rate: 192000))
        XCTAssertTrue(owned.restore().isEmpty)
        XCTAssertEqual(try devices.rate(2), 48000)
        XCTAssertEqual(devices.current, 1)
    }
    func testFailureDoesNotInventOwnership() throws {
        let devices = FakeDevices()
        let lease = DeviceLease(access: devices)
        try lease.begin(output: devices.outputs[1]); devices.failRate = true
        XCTAssertThrowsError(try lease.apply(rate: 44100))
        XCTAssertTrue(lease.restore().isEmpty)
        XCTAssertTrue(devices.writes.isEmpty)
        XCTAssertEqual(devices.current, 1)
    }
    func testFailedSecondSwitchStillRestoresFirstOwnedRate() throws {
        let devices = FakeDevices()
        let lease = DeviceLease(access: devices)
        try lease.begin(output: devices.outputs[1]); try lease.apply(rate: 44100)
        devices.failRate = true
        XCTAssertThrowsError(try lease.apply(rate: 48000))
        devices.failRate = false
        XCTAssertTrue(lease.restore().isEmpty)
        XCTAssertEqual(try devices.rate(2), 192000)
    }
    func testDisconnectAndIdReuseCannotChangeDifferentDevice() throws {
        let devices = FakeDevices()
        let owned = DeviceLease(access: devices)
        try owned.begin(output: devices.outputs[1]); try owned.apply(rate: 44100)
        devices.outputs[1].uid = "unrelated"
        XCTAssertThrowsError(try owned.apply(rate: 48000))
        XCTAssertFalse(owned.restore().isEmpty)
        XCTAssertEqual(devices.writes, [44100])
    }
    func testDisconnectedRecoveryRetainsJournalAndResolvesReconnectedUID() throws {
        let devices = FakeDevices()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let journal = folder.appendingPathComponent("connection.json")
        defer { try? FileManager.default.removeItem(at: folder) }
        let lease = DeviceLease(access: devices, journalURL: journal)
        try lease.begin(output: devices.outputs[1]); try lease.apply(rate: 44100)
        var detached = devices.outputs.removeLast()
        XCTAssertFalse(lease.restore().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
        detached.id = 9; devices.outputs.append(detached); devices.current = 9
        XCTAssertTrue(DeviceLease(access: devices, journalURL: journal).recoverOrphaned().isEmpty)
        XCTAssertEqual(try devices.rate(9), 192000)
        XCTAssertEqual(devices.current, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }
}
