import XCTest
import CoreAudio
@testable import FiloCore

private func pcm(_ bits: UInt32, rate: Double = 48000, float: Bool = false, bytes: UInt32? = nil) -> PCMFormat {
    PCMFormat(AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: (float ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger) | kAudioFormatFlagIsPacked,
        mBytesPerPacket: bytes ?? ((bits + 7) / 8) * 2, mFramesPerPacket: 1,
        mBytesPerFrame: bytes ?? ((bits + 7) / 8) * 2, mChannelsPerFrame: 2, mBitsPerChannel: bits, mReserved: 0))
}

private final class FormatDevices: PhysicalFormatAccess {
    var current = pcm(32, rate: 96000)
    var route: UInt32 = 1
    var formatWrites: [PCMFormat] = []
    var rateWrites: [Double] = []
    var depths: [UInt32] = [16, 24, 32]
    var failNextFormat = false
    var failAfterFormat = false
    func devices() -> [OutputDevice] {
        [OutputDevice(id: 1, uid: "speakers", name: "Speakers", rate: 48000, supportedRates: [48000],
                      formats: [pcm(32, float: true)], hogPID: -1, isDefault: route == 1, transport: 0),
         OutputDevice(id: 2, uid: "dac", name: "DAC", rate: current.rate, supportedRates: [44100, 48000, 96000, 192000],
                      formats: [current], hogPID: -1, isDefault: route == 2, transport: 0)]
    }
    func defaultOutput() -> UInt32 { route }
    func setDefaultOutput(_ id: UInt32) { route = id }
    func rate(_ id: UInt32) -> Double { current.rate }
    func setRate(_ id: UInt32, _ rate: Double) { current = current.at(rate: rate); rateWrites.append(rate) }
    func physicalFormat(_ device: UInt32) -> PCMFormat { current }
    func physicalFormats(_ device: UInt32, rate: Double) -> [PCMFormat] { depths.map { pcm($0, rate: rate) } }
    func setPhysicalFormat(_ device: UInt32, _ format: PCMFormat) throws {
        if failNextFormat { failNextFormat = false; throw AudioFailure("format refused") }
        current = format; formatWrites.append(format)
        if failAfterFormat { failAfterFormat = false; throw AudioFailure("readback failed after write") }
    }
}

final class PhysicalFormatTests: XCTestCase {
    func testExclusiveRepresentationIsRejectedBeforeChangingRate() throws {
        let devices = FormatDevices()
        var description = devices.current.asbd
        description.mFormatFlags |= kAudioFormatFlagIsNonMixable
        devices.current = PCMFormat(description)
        let lease = DeviceLease(access: devices)
        try lease.begin(output: devices.devices()[1])
        XCTAssertThrowsError(try lease.apply(rate: 44100, sourceBits: 24))
        XCTAssertTrue(devices.rateWrites.isEmpty)
        XCTAssertTrue(devices.formatWrites.isEmpty)
        XCTAssertTrue(lease.restore().isEmpty)
    }
    func testExactIntegerDepthWinsAndDuplicateContainersDoNotChurn() {
        let packed = pcm(24), padded = pcm(24, bytes: 8)
        XCTAssertEqual(PhysicalFormatPolicy.select(sourceBits: 24, rate: 48000, current: padded,
                                                  available: [packed, pcm(32), padded]), padded)
        XCTAssertEqual(PhysicalFormatPolicy.select(sourceBits: 16, rate: 48000, current: pcm(32),
                                                  available: [pcm(32), pcm(24), pcm(16)]), pcm(16))
    }
    func testFloatContainerPrecisionIsNotItsWordSize() {
        let float = pcm(32, float: true)
        XCTAssertEqual(float.precisionBits, 24)
        XCTAssertEqual(PhysicalFormatPolicy.select(sourceBits: 24, rate: 48000, current: float, available: [float]), float)
        XCTAssertNil(PhysicalFormatPolicy.select(sourceBits: 32, rate: 48000, current: float, available: [float]))
        XCTAssertNil(PhysicalFormatPolicy.select(sourceBits: 24, rate: 48000, current: pcm(16), available: [pcm(16)]))
    }
    func testRateAndDepthTransitionsAreRestoredTogether() throws {
        let devices = FormatDevices()
        let connection = DeviceLease(access: devices)
        try connection.begin(output: devices.devices()[1])
        try connection.apply(rate: 44100, sourceBits: 16)
        try connection.apply(rate: 44100, sourceBits: 16)
        XCTAssertEqual(devices.current, pcm(16, rate: 44100))
        XCTAssertEqual(devices.formatWrites.count, 1)
        try connection.apply(rate: 192000, sourceBits: 24)
        XCTAssertEqual(devices.current, pcm(24, rate: 192000))
        XCTAssertTrue(connection.restore().isEmpty)
        XCTAssertEqual(devices.current, pcm(32, rate: 96000))
        XCTAssertEqual(devices.route, 1)
    }
    func testDepthOnlyChangeAlsoRestores() throws {
        let devices = FormatDevices(), original = pcm(32, rate: 96000)
        let lease = DeviceLease(access: devices)
        try lease.begin(output: devices.devices()[1])
        try lease.apply(rate: 96000, sourceBits: 24)
        XCTAssertTrue(devices.rateWrites.isEmpty)
        XCTAssertEqual(devices.current.bits, 24)
        XCTAssertTrue(lease.restore().isEmpty)
        XCTAssertEqual(devices.current, original)
    }
    func testUnknownDepthNeverChangesDeviceDepth() throws {
        let devices = FormatDevices()
        let connection = DeviceLease(access: devices)
        try connection.begin(output: devices.devices()[1])
        try connection.apply(rate: 44100, sourceBits: nil)
        XCTAssertEqual(devices.current.bits, 32)
        XCTAssertTrue(devices.formatWrites.isEmpty)
        XCTAssertTrue(connection.restore().isEmpty)
    }
    func testExternalBitDepthStopsOwnershipWithoutOverwritingTheUser() throws {
        let devices = FormatDevices()
        let lease = DeviceLease(access: devices)
        try lease.begin(output: devices.devices()[1])
        try lease.apply(rate: 44100, sourceBits: 16)
        devices.current = pcm(24, rate: 44100)
        XCTAssertThrowsError(try lease.apply(rate: 44100, sourceBits: 24))
        XCTAssertThrowsError(try lease.validateRepresentation(devices.devices()[1]))
        XCTAssertTrue(lease.restore().isEmpty)
        XCTAssertEqual(devices.current, pcm(24, rate: 44100))
    }
    func testUnknownOrUnsupportedPrecisionLeavesPlaybackAvailable() throws {
        let devices = FormatDevices()
        devices.current = pcm(16, rate: 96000); devices.depths = [16]
        let lease = DeviceLease(access: devices)
        try lease.begin(output: devices.devices()[1])
        try lease.apply(rate: 48000, sourceBits: 24)
        XCTAssertEqual(devices.current, pcm(16))
        XCTAssertTrue(devices.formatWrites.isEmpty)
        XCTAssertTrue(lease.restore().isEmpty)
    }
    func testPartialRestoreIsJournaledAndRetried() throws {
        let devices = FormatDevices()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let journal = folder.appendingPathComponent("lease.json")
        defer { try? FileManager.default.removeItem(at: folder) }
        let lease = DeviceLease(access: devices, journalURL: journal)
        try lease.begin(output: devices.devices()[1])
        try lease.apply(rate: 44100, sourceBits: 24)
        devices.failNextFormat = true
        XCTAssertFalse(lease.restore().isEmpty)
        XCTAssertEqual(devices.current, pcm(24, rate: 96000))
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
        XCTAssertTrue(DeviceLease(access: devices, journalURL: journal).recoverOrphaned().isEmpty)
        XCTAssertEqual(devices.current, pcm(32, rate: 96000))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }
    func testReadbackFailureAfterWritingStillRestores() throws {
        let devices = FormatDevices()
        let lease = DeviceLease(access: devices)
        try lease.begin(output: devices.devices()[1])
        devices.failAfterFormat = true
        XCTAssertThrowsError(try lease.apply(rate: 48000, sourceBits: 24))
        XCTAssertEqual(devices.current, pcm(24))
        XCTAssertTrue(lease.restore().isEmpty)
        XCTAssertEqual(devices.current, pcm(32, rate: 96000))
    }
}
