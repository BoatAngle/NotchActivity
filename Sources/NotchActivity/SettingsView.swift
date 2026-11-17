import SwiftUI

struct SettingsView: View {
    let model: IslandModel
    let showWelcome: () -> Void

    var body: some View {
        let s = model.settings
        Form {
            Section("General") {
                Toggle("Open at Login", isOn: s.launchAtLoginBinding)
                if let error = s.loginItemError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Toggle("Open when the pointer rests on the notch", isOn: s.binding(.expandOnHover))
                Toggle("Hide while an app is full screen", isOn: s.binding(.hideInFullScreen))
                Toggle("Haptic feedback", isOn: s.binding(.haptics))
            }

            Section {
                Picker("Source", selection: Binding(get: { model.music.setting },
                                                    set: { model.music.setSetting($0) })) {
                    Text("Any app").tag(MusicController.Setting.automatic)
                    Text("Demo tracks").tag(MusicController.Setting.demo)
                }
                Toggle("Preview new tracks", isOn: s.binding(.trackPeek))
                Toggle("Hide after 10 minutes paused", isOn: s.binding(.hidePausedMusic))
                Toggle("Find album artwork online", isOn: s.binding(.onlineArtwork))
            } header: {
                Text("Now Playing")
            } footer: {
                footnote(nowPlayingFootnote)
            }

            Section {
                Toggle("Show upcoming events", isOn: s.binding(.calendar))
                if s[.calendar], model.calendar.denied {
                    Text("Calendar access is turned off for NotchActivity in System Settings › Privacy & Security › Calendars.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Calendar")
            } footer: {
                footnote("Your next event appears 15 minutes before it starts, with a Join button for video calls.")
            }

            Section("Alerts") {
                Toggle("Charging and low battery", isOn: s.binding(.alertPower))
                Toggle("Headphones and speakers connecting", isOn: s.binding(.alertAudio))
                Toggle("Silent Mode", isOn: s.binding(.alertMute))
                Toggle("Unlocking this Mac", isOn: s.binding(.alertUnlock))
            }

            Section {
                LabeledContent("Version", value: version)
                Button("Show Welcome Again", action: showWelcome)
            }
        }
        .formStyle(.grouped)
        .frame(width: 470)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var nowPlayingFootnote: String {
        switch model.music.backend {
        case .system:
            "Shows media from any app, including Safari and Chrome. Artwork is looked up in the iTunes catalog by artist and title; turn that off to show the app's icon instead."
        case .scripts:
            "System-wide Now Playing isn't available on this macOS version, so NotchActivity is following Music and Spotify directly."
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        return (info?["CFBundleShortVersionString"] as? String) ?? "dev"
    }
}
