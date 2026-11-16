import AppKit

// NotchActivity — a Dynamic Island–style home for live activities in the MacBook notch.
//
// The island is a borderless, non-activating panel anchored to the physical notch (a menu
// bar item can't do this: status items only get the strip right of the notch and are
// capped at menu-bar height). The status item is a small icon that also reserves menu-bar
// room for the island's right side. Nothing touches the display arrangement.
//
//   Geometry.swift         notch location, shared layout constants, island shape
//   Model.swift            presentation state machine, pages, hero slots, timer
//   Settings.swift         preferences, open at login
//   NowPlaying.swift       system-wide Now Playing, playback commands, artwork, demo tracks
//   SystemMonitors.swift   charging / low battery, output device, mute, screen unlock
//   CalendarMonitor.swift  next calendar event as a live activity
//   ExternalAPI.swift      notchactivity:// URL scheme (used by the `notch` CLI and Shortcuts)
//   Search.swift           app search + calculator
//   Views.swift            SwiftUI for every presentation
//   Components.swift       artwork, waveform, scrubber, buttons
//   SettingsView.swift     the Settings window
//   Controller.swift       panel, hover, alerts, AirDrop, menus, status item

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = MainActor.assumeIsolated { NotchController() }
app.delegate = controller
app.run()
