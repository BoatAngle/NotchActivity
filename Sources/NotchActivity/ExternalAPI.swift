import AppKit
import SwiftUI

// The island's public interface: other apps, shell scripts and Shortcuts drive it with URLs.
// The `notch` command-line tool is a thin wrapper around these.
//
//   notchactivity://activity?id=build&title=Building&subtitle=MyApp&icon=hammer.fill&tint=orange&progress=0.4
//   notchactivity://activity?id=build&progress=0.8                 (update: only the fields given)
//   notchactivity://end?id=build&status=success&message=Done       (status: success | failure)
//   notchactivity://alert?title=Deployed&value=v2.1&icon=checkmark.seal.fill&tint=green
//   notchactivity://timer?seconds=300        notchactivity://timer?action=cancel
//   notchactivity://music?action=toggle      (toggle | next | previous)
//   notchactivity://expand   collapse   search   settings
//   notchactivity://page?index=2             (which page the expanded island shows; "home" = last)
//   notchactivity://preview?name=charging    (samples: charging, lowbattery, airpods, silent,
//                                             unlocked, timerdone, track, event, activity, welcome)
//
// `progress` is 0...1 (or "40%"), or "indeterminate" for a spinner. `tint` is a color name
// or #RRGGBB. `icon` is an SF Symbol name. `url` (http/https) adds an Open button.

extension NotchController {
    static let urlScheme = "notchactivity"
    private static let maxCustomActivities = 6

    func handle(url: URL) {
        guard url.scheme?.lowercased() == Self.urlScheme else { return }
        let action = (url.host ?? "").lowercased()
        var q: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            q[item.name.lowercased()] = String((item.value ?? "").prefix(200))
        }

        switch action {
        case "activity", "start", "update":
            upsertActivity(q)
        case "end", "finish":
            finishActivity(q)
        case "alert":
            guard let title = q["title"], !title.isEmpty else { return }
            let tint = q["tint"].flatMap { Color(islandName: $0) } ?? .white
            showAlert(IslandAlert(icon: symbol(q["icon"], default: "bell.fill"), title: title,
                                  value: q["value"] ?? q["subtitle"] ?? "", tint: tint,
                                  valueTint: tint == .white ? .white.opacity(0.6) : tint), force: true)
        case "timer":
            if q["action"] == "cancel" {
                withAnimation(Island.morph) { model.timer.cancel() }
            } else if q["action"] == "toggle" {
                model.timer.toggle()
            } else if let seconds = (q["seconds"].flatMap(Double.init) ?? q["minutes"].flatMap(Double.init).map { $0 * 60 }),
                      seconds >= 1, seconds <= 24 * 3600 {
                startTimer(seconds: seconds)
            }
        case "music":
            switch q["action"] ?? "toggle" {
            case "next": model.music.next()
            case "previous", "prev": model.music.previous()
            case "stop": model.music.stop()
            default: model.music.togglePlay()
            }
        case "expand":
            withAnimation(Island.morph) { model.pinned = true }
        case "collapse":
            if model.welcoming { finishWelcome() }
            withAnimation(Island.morph) { model.pinned = false; model.hovering = false }
        case "page":
            // 1-based index, or "home" for the last page.
            let count = model.pages.count
            let index = q["index"] == "home" ? count - 1 : (q["index"].flatMap(Int.init) ?? 1) - 1
            model.selectPage(index)
        case "preview":
            let name = (q["name"] ?? "").lowercased()
            if name == "welcome" {
                showWelcome()
            } else if let index = Self.previewNames.firstIndex(of: name) {
                runPreview(index)
            }
        case "search":
            beginSearch()
        case "settings":
            if q["action"] == "close" {
                NSApp.windows.first { $0.title.hasSuffix("Settings") }?.close()
            } else {
                openSettings(activate: q["activate"] != "0")
            }
        default:
            break
        }
    }

    private func symbol(_ name: String?, default fallback: String) -> String {
        guard let name, !name.isEmpty,
              NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil else { return fallback }
        return name
    }

    private func upsertActivity(_ q: [String: String]) {
        let id = String((q["id"] ?? "default").prefix(64))
        let isNew = model.custom(id) == nil
        var activity = model.custom(id) ?? CustomActivity(id: id, title: q["title"] ?? "Activity")

        if let title = q["title"], !title.isEmpty { activity.title = title }
        if let subtitle = q["subtitle"] { activity.subtitle = subtitle }
        if q["icon"] != nil { activity.icon = symbol(q["icon"], default: activity.icon) }
        if let tint = q["tint"].flatMap({ Color(islandName: $0) }) { activity.tint = tint }
        if let raw = q["progress"]?.lowercased() {
            if ["indeterminate", "spin", "spinner"].contains(raw) {
                activity.progress = nil
                activity.indeterminate = true
            } else if ["none", "off", ""].contains(raw) {
                activity.progress = nil
                activity.indeterminate = false
            } else if var value = Double(raw.replacingOccurrences(of: "%", with: "")) {
                if raw.hasSuffix("%") || value > 1 { value /= 100 }
                activity.progress = min(1, max(0, value))
                activity.indeterminate = false
            }
        }
        if let raw = q["url"], let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            activity.url = url
        }
        if let seconds = q["duration"].flatMap(Double.init), seconds > 0 {
            customExpiry[id] = Date().addingTimeInterval(seconds)
        }

        if isNew {
            withAnimation(Island.pop) {
                if model.customs.count >= Self.maxCustomActivities { model.customs.removeFirst() }
                model.customs.append(activity)
                model.promote(.custom(id))
            }
            if model.presentation == .compact || model.presentation == .idle {
                let value = activity.progress.map { "\(Int(($0 * 100).rounded()))%" } ?? activity.subtitle
                showAlert(IslandAlert(icon: activity.icon, title: activity.title, value: value, tint: activity.tint,
                                      valueTint: .white.opacity(0.6), duration: 2.2, tag: "activity:\(id)"), force: true)
            }
        } else if let index = model.customs.firstIndex(where: { $0.id == id }) {
            withAnimation(Island.settle) { model.customs[index] = activity }
        }
    }

    private func finishActivity(_ q: [String: String]) {
        let id = String((q["id"] ?? "default").prefix(64))
        guard let activity = model.custom(id) else { return }
        endCustomActivity(id)
        cancelAlerts(tagged: "activity:\(id)")   // don't make a quick result wait behind its own "started" preview
        switch q["status"]?.lowercased() {
        case "success", "ok", "done":
            showAlert(IslandAlert(icon: "checkmark.circle.fill", title: activity.title,
                                  value: q["message"] ?? "Done", tint: .green), force: true)
        case "failure", "fail", "failed", "error":
            showAlert(IslandAlert(icon: "xmark.circle.fill", title: activity.title,
                                  value: q["message"] ?? "Failed", tint: .red), force: true)
        default:
            break
        }
    }
}
