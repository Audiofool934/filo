import Foundation
import CoreAudio

/// Property callbacks replace idle polling. All registration and delivery use the controller queue.
final class HardwareMonitor {
    private struct Key: Hashable { let object: UInt32; let selector: UInt32; let scope: UInt32 }
    private let queue: DispatchQueue
    private let changed: () -> Void
    private var listeners: [Key: AudioObjectPropertyListenerBlock] = [:]
    private var pending: DispatchWorkItem?
    private var stopped = false
    init(queue: DispatchQueue, changed: @escaping () -> Void) {
        self.queue = queue; self.changed = changed
    }
    func watch(_ devices: [OutputDevice]) {
        guard !stopped else { return }
        var keys: Set<Key> = [
            Key(object: HAL.system, selector: kAudioHardwarePropertyDevices, scope: kAudioObjectPropertyScopeGlobal),
            Key(object: HAL.system, selector: kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        ]
        for device in devices {
            for selector in [kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyDeviceIsAlive] {
                keys.insert(Key(object: device.id, selector: selector, scope: kAudioObjectPropertyScopeGlobal))
            }
            keys.insert(Key(object: device.id, selector: kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput))
            let streams = (try? HAL.array(device.id, kAudioDevicePropertyStreams, seed: UInt32(0), scope: kAudioObjectPropertyScopeOutput)) ?? []
            for stream in streams {
                keys.insert(Key(object: stream, selector: kAudioStreamPropertyPhysicalFormat, scope: kAudioObjectPropertyScopeGlobal))
            }
        }
        for key in Set(listeners.keys).subtracting(keys) { remove(key) }
        for key in keys where listeners[key] == nil {
            var address = HAL.address(key.selector, scope: key.scope)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.schedule() }
            if AudioObjectAddPropertyListenerBlock(key.object, &address, queue, block) == noErr { listeners[key] = block }
        }
    }
    private func schedule() {
        guard !stopped, pending == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            self.pending = nil; self.changed()
        }
        pending = work
        queue.asyncAfter(deadline: .now() + .milliseconds(100), execute: work)
    }
    private func remove(_ key: Key) {
        guard let block = listeners.removeValue(forKey: key) else { return }
        var address = HAL.address(key.selector, scope: key.scope)
        AudioObjectRemovePropertyListenerBlock(key.object, &address, queue, block)
    }
    func stop() {
        stopped = true; pending?.cancel(); pending = nil
        for key in Array(listeners.keys) { remove(key) }
    }
    deinit { stop() }
}
