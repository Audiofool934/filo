import AppKit
import SwiftUI
import FiloCore

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--player-helper",
   let source = MusicSource(rawValue: CommandLine.arguments[2]) {
    PlayerHelper.run(source: source)
    exit(0)
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
