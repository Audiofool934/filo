import AVFoundation
import CoreAudio
import CryptoKit
import Darwin
import Foundation
import FiloPCM

// Task-only diagnostic. This file is compiled with the existing ReferencePCM and HAL sources.
private func emit(_ fields: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}

private func silentWAV() -> Data {
    let frames = 22_050, byteCount = frames * 6
    var data = Data()
    func u16(_ value: UInt16) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }
    func u32(_ value: UInt32) {
        for shift in stride(from: 0, through: 24, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }
    data.append(contentsOf: "RIFF".utf8); u32(UInt32(36 + byteCount))
    data.append(contentsOf: "WAVEfmt ".utf8); u32(16)
    u16(1); u16(2); u32(44_100); u32(44_100 * 6); u16(6); u16(24)
    data.append(contentsOf: "data".utf8); u32(UInt32(byteCount))
    data.append(Data(repeating: 0, count: byteCount))
    return data
}

private final class ReferencePlayer: NSObject, AVAudioPlayerDelegate {
    let reference: AVAudioPlayer
    let silence: AVAudioPlayer
    let mode: String
    let digest: String
    let startedAt: TimeInterval
    var ready = false
    var started = false
    var completed = false
    var completionSucceeded: Bool?
    var stopped = false
    var failed = false

    init(mode: String, enableRate: Bool, startedAt: TimeInterval) throws {
        self.mode = mode; self.startedAt = startedAt
        let work = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent()
        let name = mode == "alac" ? "filo-reference-44100-24.m4a" : "filo-reference-44100-24.wav"
        let url = work.appendingPathComponent("reference-server").appendingPathComponent(name)
        let pcm = try ReferencePCM.load(from: url, maximumFrames: 220_500)
        guard pcm.sampleRate == 44_100, pcm.bits == 24, pcm.frameCount == 220_500,
              pcm.sourceFormat == (mode == "alac" ? "ALAC" : "integer PCM") else {
            throw AudioFailure("The fixed reference must be the original 5-second 44.1 kHz stereo 24-bit fixture.")
        }
        for index in pcm.samples.indices {
            guard pcm.samples[index] == filo_test_sample(UInt64(index / 2), UInt32(index % 2), 24) else {
                throw AudioFailure("The fixed reference differs from the original filo test sample sequence at sample \(index).")
            }
        }
        let bytes = try Data(contentsOf: url)
        let dataDigest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard dataDigest == pcm.fileSHA256 else { throw AudioFailure("The reference changed after validation.") }
        digest = dataDigest
        reference = try AVAudioPlayer(data: bytes, fileTypeHint: mode == "alac" ? AVFileType.m4a.rawValue : AVFileType.wav.rawValue)
        silence = try AVAudioPlayer(data: silentWAV(), fileTypeHint: AVFileType.wav.rawValue)
        super.init()
        for player in [reference, silence] {
            player.delegate = self
            player.volume = 1; player.pan = 0; player.enableRate = false; player.rate = 1
        }
        reference.enableRate = enableRate
        reference.numberOfLoops = 0
        silence.numberOfLoops = -1
        guard reference.prepareToPlay(), silence.prepareToPlay(), silence.play() else {
            throw AudioFailure("AVAudioPlayer could not prepare the reference and start the silent readiness stream.")
        }
    }

    func publishStatus() {
        var fields: [String: Any] = [
            "event": "status", "pid": ProcessInfo.processInfo.processIdentifier,
            "mode": mode, "ready": ready, "started": started, "completed": completed,
            "playing": reference.isPlaying, "currentTime": reference.currentTime,
            "duration": reference.duration, "silencePlaying": silence.isPlaying,
            "elapsed": ProcessInfo.processInfo.systemUptime - startedAt
        ]
        if let completionSucceeded { fields["completionSucceeded"] = completionSucceeded }
        emit(fields)
    }

    func propertyReadback(_ player: AVAudioPlayer) -> [String: Any] {
        ["volume": player.volume, "pan": player.pan,
         "enableRate": player.enableRate, "rate": player.rate,
         "numberOfLoops": player.numberOfLoops,
         "sampleRate": player.format.sampleRate,
         "channelCount": player.format.channelCount]
    }

    func command(_ value: String) {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "GO":
            guard ready, !started else {
                emit(["event": "error", "error": "GO requires readiness and can be accepted only once."])
                return
            }
            reference.currentTime = 0
            guard reference.play() else { fail("AVAudioPlayer refused to start the reference."); return }
            started = true
            emit(["event": "goAccepted", "pid": ProcessInfo.processInfo.processIdentifier,
                  "mode": mode, "currentTime": reference.currentTime, "duration": reference.duration])
        case "STATUS": publishStatus()
        case "STOP": stop(reason: "command")
        case "": break
        default: emit(["event": "error", "error": "Accepted commands are GO, STATUS, and STOP."])
        }
    }

    func stop(reason: String) {
        guard !stopped else { return }
        reference.stop(); silence.stop(); stopped = true
        emit(["event": "stopped", "reason": reason, "completed": completed])
    }

    func fail(_ message: String) {
        failed = true
        emit(["event": "error", "error": message])
        stop(reason: "error")
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === reference else { fail("The looping silence player ended unexpectedly."); return }
        completed = true; completionSucceeded = flag
        publishStatus()
        if !flag { fail("The reference did not finish successfully.") }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        fail(error?.localizedDescription ?? "AVAudioPlayer reported a decode error.")
    }
}

@main
private enum Main {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--help"] || arguments == ["-h"] {
            print("""
            Usage: work/av-reference-player [--mode alac|wav] [--enable-rate]
            Default: alac. Only the fixed original 5-second 44100/24 stereo fixture is accepted.
            --enable-rate enables rate processing for the reference player only, retaining rate 1.
            The separate silence player always keeps rate processing disabled.
            The reference is decoded with ReferencePCM and checked against every filo_test_sample.
            Startup plays only an in-memory all-zero WAV, using a separate looping AVAudioPlayer.
            Wait for JSON event ready, then send GO followed by a newline to play the reference once.
            STATUS reports currentTime, duration, started, completed, and completionSucceeded when known.
            STOP stops both players and exits. EOF also stops. Normal deadline: 29.5 s; hard limit: 30 s.
            All stdout events are newline-delimited JSON: ready, goAccepted, status, stopped, error.
            ready includes pid, mode, referenceSHA256, sampleRate, bits, frames, halOutputActive.
            ready.referencePlayer and ready.silencePlayer read back volume, pan, enableRate, rate,
            numberOfLoops, sampleRate, and channelCount from each AVAudioPlayer.
            No output-device changes, files written, audio capture, or network access occur.
            --help does not initialize a player, inspect devices, or read the fixture.
            """)
            return
        }
        let enableRate = arguments.contains("--enable-rate")
        let modeArguments = arguments.filter { $0 != "--enable-rate" }
        let mode: String
        guard arguments.count - modeArguments.count <= 1 else {
            emit(["event": "error", "error": "--enable-rate may be specified only once."]); exit(2)
        }
        if modeArguments.isEmpty { mode = "alac" }
        else if modeArguments.count == 2, modeArguments[0] == "--mode", ["alac", "wav"].contains(modeArguments[1]) { mode = modeArguments[1] }
        else { emit(["event": "error", "error": "Usage: work/av-reference-player [--mode alac|wav] [--enable-rate]"]); exit(2) }

        let startedAt = ProcessInfo.processInfo.systemUptime
        signal(SIGALRM) { _ in _exit(124) }
        alarm(30)
        defer { alarm(0) }
        do {
            let player = try ReferencePlayer(mode: mode, enableRate: enableRate, startedAt: startedAt)
            defer { player.reference.stop(); player.silence.stop() }
            let flags = fcntl(STDIN_FILENO, F_GETFL)
            guard flags >= 0, fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw AudioFailure("Could not configure nonblocking command input.")
            }
            defer { _ = fcntl(STDIN_FILENO, F_SETFL, flags) }
            var pending = Data(), bytes = [UInt8](repeating: 0, count: 512)
            while !player.stopped {
                let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
                if elapsed >= 29.5 { player.stop(reason: "deadline"); break }
                if !player.ready {
                    let active = try HAL.processes().contains { $0.pid == ProcessInfo.processInfo.processIdentifier && $0.running }
                    if active, player.silence.isPlaying {
                        player.ready = true
                        emit(["event": "ready", "pid": ProcessInfo.processInfo.processIdentifier,
                              "mode": mode, "referenceSHA256": player.digest, "sampleRate": 44_100,
                              "bits": 24, "frames": 220_500, "halOutputActive": true,
                              "silencePlaying": true, "deadlineSeconds": 30,
                              "referencePlayer": player.propertyReadback(player.reference),
                              "silencePlayer": player.propertyReadback(player.silence)])
                    } else if elapsed >= 8 { player.fail("The silent player did not establish active HAL output within 8 seconds."); break }
                }
                let count = read(STDIN_FILENO, &bytes, bytes.count)
                if count > 0 {
                    pending.append(contentsOf: bytes.prefix(count))
                    if pending.count > 4096 { player.fail("The command input exceeded its size limit."); break }
                    while let newline = pending.firstIndex(of: 10) {
                        let line = String(decoding: pending[..<newline], as: UTF8.self)
                        pending.removeSubrange(...newline)
                        player.command(line)
                        if player.stopped { break }
                    }
                } else if count == 0 { player.stop(reason: "stdinEOF") }
                else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { player.fail("Could not read commands from stdin.") }
                if !player.stopped { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            }
            if player.failed { exit(1) }
        } catch {
            emit(["event": "error", "error": error.localizedDescription])
            exit(1)
        }
    }
}
