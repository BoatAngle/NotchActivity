import AppKit
import ServiceManagement
import SwiftUI

/// User preferences, stored in UserDefaults. One observable dictionary keeps the views,
/// the Settings window and the controller in sync.
@MainActor @Observable
final class AppSettings {
    enum Key: String, CaseIterable {
        case expandOnHover, haptics, trackPeek, onlineArtwork, hidePausedMusic
        case calendar
        case alertPower, alertAudio, alertMute, alertUnlock
        case hasOnboarded
    }

    static let defaults: [Key: Bool] = [
        .expandOnHover: true, .haptics: true, .trackPeek: true, .onlineArtwork: true,
        .hidePausedMusic: true, .calendar: false,
        .alertPower: true, .alertAudio: true, .alertMute: true, .alertUnlock: true,
        .hasOnboarded: false,
    ]

    private var values: [Key: Bool] = [:]
    private(set) var launchAtLogin = false
    private(set) var loginItemError: String?
    @ObservationIgnored var onChange: ((Key) -> Void)?

    init() {
        let d = UserDefaults.standard
        for key in Key.allCases {
            values[key] = d.object(forKey: key.rawValue) as? Bool ?? Self.defaults[key] ?? false
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    subscript(key: Key) -> Bool {
        get { values[key] ?? false }
        set {
            guard values[key] != newValue else { return }
            values[key] = newValue
            UserDefaults.standard.set(newValue, forKey: key.rawValue)
            onChange?(key)
        }
    }

    func binding(_ key: Key) -> Binding<Bool> {
        Binding(get: { self[key] }, set: { self[key] = $0 })
    }

    var launchAtLoginBinding: Binding<Bool> {
        Binding(get: { self.launchAtLogin }, set: { self.setLaunchAtLogin($0) })
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
