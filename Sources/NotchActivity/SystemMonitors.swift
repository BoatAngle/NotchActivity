import AppKit
import CoreAudio
import IOKit.ps
import SwiftUI

// MARK: - Power (charging + low battery)

struct PowerSnapshot: Equatable {
    var hasBattery = false
    var percent = 100
    var onAC = true
    var charging = false
}

@MainActor @Observable
final class PowerMonitor {
    private(set) var state = PowerSnapshot()
    @ObservationIgnored var onChange: ((PowerSnapshot, PowerSnapshot) -> Void)?
    @ObservationIgnored private var source: CFRunLoopSource?

    var symbol: String {
        if state.onAC { return "battery.100percent.bolt" }
        switch state.percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    var tint: Color {
        if state.onAC { return .green }
        return state.percent <= 20 ? .red : .white
    }

    func start() {
        state = Self.read()
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.refresh() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
            source = src
        }
    }

    func refresh() {
        let old = state
        let new = Self.read()
        guard new != old else { return }
        state = new
        onChange?(old, new)
    }

    nonisolated static func read() -> PowerSnapshot {
        var snap = PowerSnapshot()
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return snap }
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  (desc["Type"] as? String) == "InternalBattery" else { continue }
            snap.hasBattery = true
            let cur = desc["Current Capacity"] as? Int ?? 0
            let max = desc["Max Capacity"] as? Int ?? 100
            snap.percent = max > 0 ? Int((Double(cur) / Double(max) * 100).rounded()) : cur
            snap.onAC = (desc["Power Source State"] as? String) == "AC Power"
            snap.charging = desc["Is Charging"] as? Bool ?? false
        }
        return snap
    }
}

// MARK: - Audio output (AirPods / headphones connecting, Silent Mode)

struct OutputDevice: Equatable {
    var id: AudioObjectID = 0
    var name = "Speakers"
    var symbol = "speaker.wave.2.fill"
    var isExternal = false
}

@MainActor @Observable
final class AudioMonitor {
    private(set) var device = OutputDevice()
    private(set) var muted = false
    @ObservationIgnored var onDeviceChange: ((OutputDevice) -> Void)?
    @ObservationIgnored var onMuteChange: ((Bool) -> Void)?
    @ObservationIgnored private var muteListener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var muteListenerDevice: AudioObjectID = 0

    func start() {
        device = Self.currentDevice()
        muted = Self.isMuted(device.id)
        listenForMute(on: device.id)

        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.defaultDeviceChanged() }
        }
    }

    private func defaultDeviceChanged() {
        let new = Self.currentDevice()
        guard new.id != device.id else { return }
        device = new
        muted = Self.isMuted(new.id)   // a new device brings its own mute state: not a "Silent Mode" event
        listenForMute(on: new.id)
        onDeviceChange?(new)
    }

    private func listenForMute(on id: AudioObjectID) {
        var addr = Self.muteAddress
        if let old = muteListener {
            AudioObjectRemovePropertyListenerBlock(muteListenerDevice, &addr, .main, old)
            muteListener = nil
        }
        guard id != 0, AudioObjectHasProperty(id, &addr) else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let m = Self.isMuted(self.device.id)
                guard m != self.muted else { return }
                self.muted = m
                self.onMuteChange?(m)
            }
        }
        if AudioObjectAddPropertyListenerBlock(id, &addr, .main, block) == noErr {
            muteListener = block
            muteListenerDevice = id
        }
    }

    // MARK: CoreAudio reads

    nonisolated static let muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    nonisolated static func isMuted(_ id: AudioObjectID) -> Bool {
        var addr = muteAddress
        guard id != 0, AudioObjectHasProperty(id, &addr) else { return false }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr && value != 0
    }

    nonisolated static func currentDevice() -> OutputDevice {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var id: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
              id != 0 else { return OutputDevice() }

        var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var cfName: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let name = withUnsafeMutablePointer(to: &cfName) { ptr -> String in
            guard AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, ptr) == noErr,
                  let v = ptr.pointee else { return "Speakers" }
            return v.takeRetainedValue() as String
        }

        var tAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                               mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var tSize = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(id, &tAddr, 0, nil, &tSize, &transport)

        let lower = name.lowercased()
        let symbol: String
        var external = true
        if lower.contains("airpods max") { symbol = "airpods.max" }
        else if lower.contains("airpods pro") { symbol = "airpods.pro" }
        else if lower.contains("airpods") { symbol = "airpods" }
        else if lower.contains("beats") { symbol = "beats.headphones" }
        else {
            switch transport {
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: symbol = "headphones"
            case kAudioDeviceTransportTypeAirPlay: symbol = "airplayaudio"
            case kAudioDeviceTransportTypeUSB: symbol = "hifispeaker.fill"
            case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: symbol = "tv"
            default:
                symbol = "laptopcomputer"
                external = false
            }
        }
        return OutputDevice(id: id, name: name, symbol: symbol, isExternal: external)
    }
}

// MARK: - Screen lock

/// Reports when the Mac is unlocked (Touch ID, Apple Watch, or password).
@MainActor
final class ScreenLockMonitor {
    var onUnlock: (() -> Void)?
    private var observer: NSObjectProtocol?

    func start() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onUnlock?() }
        }
    }
}
