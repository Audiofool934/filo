import XCTest
import CoreAudio
@testable import FiloCore

private final class ControllerDevices: DeviceAccess {
    private static func output(id: UInt32, uid: String, rate: Double) -> OutputDevice {
        let stream = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                                mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                                mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        return OutputDevice(id: id, uid: uid, name: uid, rate: rate,
                            supportedRates: [44100, 48000, 96000, 192000], formats: [PCMFormat(stream)],
                            hogPID: -1, isDefault: id == 1, transport: 0)
    }
    var outputs = [ControllerDevices.output(id: 1, uid: "speakers", rate: 48000),
                   ControllerDevices.output(id: 2, uid: "dac", rate: 96000)]
    var current: UInt32 = 1
    var writes: [Double] = []
    let acceptedRates: [Double] = [44100, 48000, 96000, 192000]
    enum WriteFailure { case beforeChange, afterChange }
    var nextWriteFailure: WriteFailure?
    func devices() -> [OutputDevice] {
        outputs.map { var value = $0; value.isDefault = value.id == current; return value }
    }
    func defaultOutput() -> UInt32 { current }
    func setDefaultOutput(_ id: UInt32) { current = id }
    func rate(_ id: UInt32) throws -> Double {
        guard let output = outputs.first(where: { $0.id == id }) else { throw AudioFailure("Disconnected") }
        return output.rate
    }
    func setRate(_ id: UInt32, _ rate: Double) throws {
        guard let index = outputs.firstIndex(where: { $0.id == id }) else { throw AudioFailure("Disconnected") }
        guard acceptedRates.contains(rate) else { throw UnsupportedSampleRate(rate) }
        let failure = nextWriteFailure
        nextWriteFailure = nil
        if failure == .beforeChange { throw AudioFailure("The output did not confirm the requested rate") }
        outputs[index].rate = rate; writes.append(rate)
        if failure == .afterChange { throw AudioFailure("The output did not confirm the requested rate") }
    }
}

private final class ControllerReader: PlaybackReading {
    var onState: ((PlayerState) -> Void)?
    var requests = 0
    func start(source: MusicSource, executable: URL) {}
    func request() { requests += 1 }
    func stop() {}
}

private final class ControllerMonitor: DecoderObserving {
    var onFormat: ((SourceFormat) -> Void)?
    var onError: ((String) -> Void)?
    var startError: String?
    func start() throws { if let startError { throw AudioFailure(startError) } }
    func stop() {}
}

private final class ControllerProcessProbe {
    var calls = 0
    func processes() throws -> [AudioProcess] {
        calls += 1
        throw AudioFailure("Audio process enumeration unavailable")
    }
}

private final class ControllerFixture {
    let devices: ControllerDevices
    let reader: ControllerReader
    let monitor: ControllerMonitor
    let processProbe: ControllerProcessProbe
    let controller: ConnectionController
    var snapshot = ConnectionSnapshot()
    var snapshots: [ConnectionSnapshot] = []
    init() {
        let devices = ControllerDevices(), reader = ControllerReader()
        let monitor = ControllerMonitor(), processProbe = ControllerProcessProbe()
        self.devices = devices; self.reader = reader; self.monitor = monitor; self.processProbe = processProbe
        controller = ConnectionController(access: devices, monitorFactory: { _ in monitor },
                                          readerFactory: { _ in reader }, processList: processProbe.processes)
        controller.onSnapshot = { [weak self] in self?.snapshot = $0; self?.snapshots.append($0) }
    }
    func connect() {
        controller.connect(source: .appleMusic, outputUID: "dac", mode: .format, manualRate: nil,
                           executable: URL(fileURLWithPath: "/unused-fake-player"))
    }
    func send(_ state: PlayerState) {
        controller.queue.async { self.reader.onState?(state) }
    }
}

final class ConnectionControllerTests: XCTestCase {
    /// The marker follows controller work and all snapshots it enqueued on the main queue.
    private func drain(_ fixture: ControllerFixture) {
        let drained = expectation(description: "Controller and snapshots drained")
        fixture.controller.queue.async { DispatchQueue.main.async { drained.fulfill() } }
        wait(for: [drained], timeout: 5)
    }

    func testAutomaticLocalTracksMatchDownwardAndRestoreWithoutProcessDiscovery() throws {
        let fixture = ControllerFixture()
        defer { fixture.controller.shutdown() }
        fixture.connect(); drain(fixture)
        XCTAssertTrue(fixture.snapshot.connected)
        for (index, rate) in [192000.0, 44100.0, 48000.0].enumerated() {
            let state = PlayerState(playing: true, trackID: "track-\(index)", localRate: rate)
            fixture.send(state); drain(fixture)
            fixture.send(state); drain(fixture)
            fixture.controller.queue.async { fixture.controller.poll() }
            drain(fixture)
            XCTAssertTrue(fixture.snapshot.connected)
            XCTAssertNil(fixture.snapshot.error)
            XCTAssertEqual(fixture.snapshot.sourceFormat?.rate, rate)
            XCTAssertEqual(fixture.snapshot.output?.rate, rate)
            XCTAssertEqual(fixture.snapshot.title, "Format matched")
            XCTAssertEqual(try fixture.devices.rate(2), rate)
        }
        XCTAssertEqual(fixture.devices.writes, [192000, 44100, 48000])
        XCTAssertEqual(fixture.processProbe.calls, 0)
        fixture.controller.disconnect(); drain(fixture)
        XCTAssertFalse(fixture.snapshot.connected)
        XCTAssertEqual(fixture.devices.writes, [192000, 44100, 48000, 96000])
        XCTAssertEqual(try fixture.devices.rate(2), 96000)
        XCTAssertEqual(fixture.devices.current, 1)
    }

    func testExternalRateBeforeFirstMetadataIsPreservedEvenIfItMatchesTheSource() throws {
        for userRate in [44100.0, 48000.0] {
            let fixture = ControllerFixture()
            defer { fixture.controller.shutdown() }
            fixture.connect(); drain(fixture)
            fixture.controller.queue.async { fixture.devices.outputs[1].rate = userRate }
            fixture.send(PlayerState(playing: true, trackID: "first-track", localRate: 44100))
            drain(fixture)
            XCTAssertFalse(fixture.snapshot.connected)
            XCTAssertTrue(fixture.snapshot.error?.contains("outside filo") == true)
            XCTAssertEqual(try fixture.devices.rate(2), userRate)
            XCTAssertTrue(fixture.devices.writes.isEmpty)
            XCTAssertEqual(fixture.devices.current, 1)
            fixture.send(PlayerState(playing: true, trackID: "late-callback", localRate: 192000))
            drain(fixture)
            XCTAssertFalse(fixture.snapshot.connected)
            XCTAssertEqual(try fixture.devices.rate(2), userRate)
        }
    }

    func testDecoderStartupFailurePersistsAndLocalFileStillMatches() throws {
        let fixture = ControllerFixture()
        defer { fixture.controller.shutdown() }
        fixture.monitor.startError = "Decoder observation unavailable"
        fixture.connect(); drain(fixture)
        fixture.send(PlayerState(playing: true, trackID: "stream")); drain(fixture)
        fixture.controller.queue.async { fixture.controller.poll() }
        drain(fixture)
        XCTAssertTrue(fixture.snapshot.connected)
        XCTAssertEqual(fixture.snapshot.detectionError, "Decoder observation unavailable")
        XCTAssertEqual(fixture.snapshot.title, "Automatic detection unavailable")
        XCTAssertTrue(fixture.snapshot.needsAttention)
        XCTAssertTrue(fixture.devices.writes.isEmpty)
        fixture.controller.queue.async { fixture.monitor.onFormat?(SourceFormat(rate: 192000, evidence: .decoder)) }
        drain(fixture)
        XCTAssertNil(fixture.snapshot.sourceFormat)
        XCTAssertTrue(fixture.devices.writes.isEmpty)
        fixture.send(PlayerState(playing: true, trackID: "readable-file", localRate: 44100)); drain(fixture)
        XCTAssertTrue(fixture.snapshot.connected)
        XCTAssertEqual(fixture.snapshot.title, "Format matched")
        XCTAssertEqual(fixture.snapshot.sourceFormat?.evidence, .localFile)
        XCTAssertEqual(try fixture.devices.rate(2), 44100)
        XCTAssertFalse(fixture.snapshot.needsAttention)
    }

    func testDecoderRuntimeFailureClearsEvidenceAndRejectsLateCallbacks() throws {
        let fixture = ControllerFixture()
        defer { fixture.controller.shutdown() }
        fixture.connect(); drain(fixture)
        fixture.send(PlayerState(playing: true, trackID: "stream")); drain(fixture)
        fixture.controller.queue.async { fixture.monitor.onFormat?(SourceFormat(rate: 192000, evidence: .decoder)) }
        drain(fixture)
        XCTAssertEqual(fixture.snapshot.sourceFormat?.rate, 192000)
        fixture.controller.queue.async { fixture.monitor.onError?("Decoder observation stopped") }
        drain(fixture)
        fixture.controller.queue.async {
            fixture.controller.poll()
            fixture.monitor.onFormat?(SourceFormat(rate: 48000, evidence: .decoder))
        }
        drain(fixture)
        XCTAssertTrue(fixture.snapshot.connected)
        XCTAssertNil(fixture.snapshot.error)
        XCTAssertNil(fixture.snapshot.sourceFormat)
        XCTAssertEqual(fixture.snapshot.detectionError, "Decoder observation stopped")
        XCTAssertEqual(fixture.snapshot.title, "Automatic detection unavailable")
        XCTAssertTrue(fixture.snapshot.needsAttention)
        XCTAssertEqual(fixture.devices.writes, [192000])
        XCTAssertEqual(try fixture.devices.rate(2), 192000)
    }

    func testUnsupportedSourceKeepsPlaybackConnectedAndNextSupportedTrackResumesMatching() throws {
        let fixture = ControllerFixture()
        defer { fixture.controller.shutdown() }
        fixture.connect(); drain(fixture)
        fixture.send(PlayerState(playing: true, trackID: "unsupported-track", localRate: 88200))
        drain(fixture)
        fixture.controller.queue.async { fixture.controller.poll() }
        drain(fixture)
        XCTAssertTrue(fixture.snapshot.connected)
        XCTAssertNil(fixture.snapshot.error)
        XCTAssertEqual(fixture.snapshot.sourceFormat?.rate, 88200)
        XCTAssertEqual(fixture.snapshot.unsupportedRate, 88200)
        XCTAssertEqual(fixture.snapshot.title, "Source rate not supported")
        XCTAssertTrue(fixture.snapshot.needsAttention)
        XCTAssertTrue(fixture.devices.writes.isEmpty)
        XCTAssertEqual(try fixture.devices.rate(2), 96000)
        fixture.send(PlayerState(playing: true, trackID: "supported-track", localRate: 44100))
        drain(fixture)
        XCTAssertTrue(fixture.snapshot.connected)
        XCTAssertNil(fixture.snapshot.unsupportedRate)
        XCTAssertFalse(fixture.snapshot.needsAttention)
        XCTAssertEqual(fixture.snapshot.title, "Format matched")
        XCTAssertEqual(fixture.devices.writes, [44100])
        XCTAssertEqual(try fixture.devices.rate(2), 44100)
    }

    func testMenuRateCandidatesDoNotRejectAFormatTheDeviceAccepts() throws {
        let fixture = ControllerFixture()
        defer { fixture.controller.shutdown() }
        fixture.devices.outputs[1].supportedRates = [44100, 48000]
        fixture.connect(); drain(fixture)
        fixture.send(PlayerState(playing: true, trackID: "supported-unlisted-track", localRate: 192000))
        drain(fixture)
        XCTAssertTrue(fixture.snapshot.connected)
        XCTAssertNil(fixture.snapshot.unsupportedRate)
        XCTAssertEqual(fixture.snapshot.title, "Format matched")
        XCTAssertEqual(fixture.devices.writes, [192000])
        XCTAssertEqual(try fixture.devices.rate(2), 192000)
    }

    func testFailedWriteNeverReportsMatchedAndRestoresAnyAppliedChange() throws {
        for failure in [ControllerDevices.WriteFailure.beforeChange, .afterChange] {
            let fixture = ControllerFixture()
            defer { fixture.controller.shutdown() }
            fixture.connect(); drain(fixture)
            fixture.controller.queue.async { fixture.devices.nextWriteFailure = failure }
            fixture.send(PlayerState(playing: true, trackID: "first-track", localRate: 192000))
            drain(fixture)
            XCTAssertFalse(fixture.snapshot.connected)
            XCTAssertTrue(fixture.snapshot.error?.contains("did not confirm") == true)
            XCTAssertFalse(fixture.snapshots.contains { $0.title == "Format matched" })
            XCTAssertEqual(try fixture.devices.rate(2), 96000)
            XCTAssertEqual(fixture.devices.current, 1)
            XCTAssertEqual(fixture.devices.writes, failure == .beforeChange ? [] : [192000, 96000])
        }
    }
}
