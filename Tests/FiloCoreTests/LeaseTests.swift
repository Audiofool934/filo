import XCTest
@testable import FiloCore

private final class FakeDevices: DeviceAccess {
    var outputs = [OutputDevice(id: 1, uid: "speakers", name: "Speakers", rate: 48000, supportedRates: [44100, 48000], formats: [], hogPID: -1, isDefault: true, transport: 0),
                   OutputDevice(id: 2, uid: "dac", name: "DAC", rate: 192000, supportedRates: [44100, 48000, 192000], formats: [], hogPID: -1, isDefault: false, transport: 0)]
    var current: UInt32 = 1
    var writes: [Double] = []
    var failRate = false
    func devices() -> [OutputDevice] { outputs }
    func defaultOutput() -> UInt32 { current }
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
    func testDisconnectAndIdReuseCannotChangeDifferentDevice() throws {
        let devices = FakeDevices()
        let owned = DeviceLease(access: devices)
        try owned.begin(output: devices.outputs[1]); try owned.apply(rate: 44100)
        devices.outputs[1].uid = "unrelated"
        XCTAssertThrowsError(try owned.apply(rate: 48000))
        XCTAssertTrue(owned.restore().isEmpty)
        XCTAssertEqual(devices.writes, [44100])
    }
}
