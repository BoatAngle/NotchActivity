import Foundation

// notch — drive NotchActivity from the command line.
// Every command becomes a notchactivity:// URL, so anything this tool does, a script,
// a Shortcut, or another app can do by opening the same URL.

let usage = """
notch — show things in your MacBook's notch

USAGE
  notch alert <title> [value] [--icon SYMBOL] [--tint COLOR]
  notch start <id> <title> [--subtitle TEXT] [--icon SYMBOL] [--tint COLOR]
                           [--progress 0-1|spin] [--url URL] [--duration SECONDS]
  notch update <id> [--title TEXT] [--subtitle TEXT] [--progress 0-1|spin] [--icon SYMBOL] [--tint COLOR]
  notch end <id> [--ok [MESSAGE]] [--fail [MESSAGE]]
  notch run [--title TEXT] [--icon SYMBOL] [--tint COLOR] -- <command> [args...]
  notch timer <duration>          e.g. 90, 45s, 5m, 1h30m
  notch timer cancel
  notch music toggle|next|previous
  notch expand | collapse | search | settings
  notch page <number|home>        which page the expanded island shows
  notch preview <name>            charging, lowbattery, airpods, silent, unlocked, timerdone,
                                  track, event, activity, welcome

EXAMPLES
  notch alert "Deployed" "v2.1" --icon checkmark.seal.fill --tint green
  notch start render "Rendering" --subtitle "scene-04.blend" --icon cube.fill --progress 0
  notch update render --progress 0.6
  notch end render --ok "Rendered"
  notch run -- make build         # spinner while it runs, then a check mark or a cross

SYMBOL is an SF Symbol name. COLOR is a name (orange, green, purple…) or #RRGGBB.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("notch: \(message)\n".utf8))
    exit(64)
}

/// Opens a notchactivity:// URL without bringing anything to the front.
func send(_ action: String, _ params: [String: String] = [:]) {
    var components = URLComponents()
    components.scheme = "notchactivity"
    components.host = action
    if !params.isEmpty {
        components.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
    }
    // URLComponents leaves "+" alone, but query parsers read it as a space.
    components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    guard let url = components.url else { fail("could not build a URL for '\(action)'") }
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-g", url.absoluteString]
    do {
        try open.run()
        open.waitUntilExit()
    } catch {
        fail("could not run /usr/bin/open: \(error.localizedDescription)")
    }
    if open.terminationStatus != 0 {
        fail("NotchActivity doesn't seem to be installed (no app handles notchactivity:// links)")
    }
}

/// Splits arguments into positionals and --options. An option may have no value (`--ok`).
func parse(_ args: [String], flags valueless: Set<String> = []) -> (positionals: [String], options: [String: String]) {
    var positionals: [String] = []
    var options: [String: String] = [:]
    var i = 0
    while i < args.count {
        let arg = args[i]
        if arg.hasPrefix("--"), arg.count > 2 {
            let name = String(arg.dropFirst(2))
            if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                options[name] = args[i + 1]
                i += 2
            } else {
                guard valueless.contains(name) else { fail("--\(name) needs a value") }
                options[name] = ""
                i += 1
            }
        } else {
            positionals.append(arg)
            i += 1
        }
    }
    return (positionals, options)
}

func seconds(from text: String) -> Double? {
    if let plain = Double(text) { return plain }
    var total = 0.0, number = "", matched = false
    for ch in text.lowercased() {
        if ch.isNumber || ch == "." { number.append(ch); continue }
        guard let value = Double(number) else { return nil }
        switch ch {
        case "h": total += value * 3600
        case "m": total += value * 60
        case "s": total += value
        default: return nil
        }
        number = ""
        matched = true
    }
    return matched && number.isEmpty ? total : nil
}

func durationText(_ t: TimeInterval) -> String {
    let s = Int(t.rounded())
    if s >= 3600 { return "\(s / 3600)h \((s % 3600) / 60)m" }
    if s >= 60 { return "\(s / 60)m \(s % 60)s" }
    return String(format: "%.1fs", t)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { print(usage); exit(0) }
let rest = Array(arguments.dropFirst())
let activityKeys: Set<String> = ["title", "subtitle", "icon", "tint", "progress", "url", "duration"]

switch command {
case "help", "-h", "--help":
    print(usage)

case "alert":
    let (pos, opts) = parse(rest)
    guard let title = pos.first else { fail("alert needs a title") }
    var params = ["title": title]
    if pos.count > 1 { params["value"] = pos[1] }
    for key in ["icon", "tint"] { if let v = opts[key] { params[key] = v } }
    send("alert", params)

case "start", "update":
    let (pos, opts) = parse(rest)
    guard let id = pos.first else { fail("\(command) needs an id") }
    var params = ["id": id]
    if command == "start" {
        guard pos.count > 1 else { fail("start needs a title: notch start <id> <title>") }
        params["title"] = pos[1]
    }
    for (key, value) in opts {
        guard activityKeys.contains(key) else { fail("unknown option --\(key)") }
        params[key] = value
    }
    send("activity", params)

case "end":
    let (pos, opts) = parse(rest, flags: ["ok", "fail"])
    guard let id = pos.first else { fail("end needs an id") }
    var params = ["id": id]
    if let message = opts["ok"] {
        params["status"] = "success"
        if !message.isEmpty { params["message"] = message }
    } else if let message = opts["fail"] {
        params["status"] = "failure"
        if !message.isEmpty { params["message"] = message }
    }
    send("end", params)

case "run":
    guard let separator = rest.firstIndex(of: "--"), separator + 1 < rest.count else {
        fail("usage: notch run [--title TEXT] -- <command> [args...]")
    }
    let (_, opts) = parse(Array(rest[..<separator]))
    let cmd = Array(rest[(separator + 1)...])
    let name = URL(fileURLWithPath: cmd[0]).lastPathComponent
    let id = "run-\(getpid())"
    send("activity", [
        "id": id,
        "title": opts["title"] ?? name,
        "subtitle": String(cmd.joined(separator: " ").prefix(60)),
        "icon": opts["icon"] ?? "terminal.fill",
        "tint": opts["tint"] ?? "blue",
        "progress": "indeterminate",
    ])

    // Ctrl-C goes to the whole foreground process group; stay alive to report the result.
    // (A handler, unlike SIG_IGN, is reset in the child when it execs.)
    signal(SIGINT) { _ in }
    let started = Date()
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    child.arguments = cmd
    do { try child.run() } catch {
        send("end", ["id": id, "status": "failure", "message": "Couldn't start"])
        fail("could not run \(cmd[0]): \(error.localizedDescription)")
    }
    child.waitUntilExit()
    let status = child.terminationStatus
    if status == 0 {
        send("end", ["id": id, "status": "success", "message": "Done in " + durationText(Date().timeIntervalSince(started))])
    } else {
        send("end", ["id": id, "status": "failure", "message": "Exit code \(status)"])
    }
    exit(status)

case "timer":
    guard let arg = rest.first else { fail("timer needs a duration (5m, 90s, 1h30m) or 'cancel'") }
    if arg == "cancel" || arg == "toggle" {
        send("timer", ["action": arg])
    } else if let s = seconds(from: arg), s >= 1 {
        send("timer", ["seconds": String(Int(s.rounded()))])
    } else {
        fail("couldn't read '\(arg)' as a duration; try 5m, 90s or 1h30m")
    }

case "music":
    let action = rest.first ?? "toggle"
    guard ["toggle", "next", "previous", "prev", "stop"].contains(action) else { fail("music takes toggle, next or previous") }
    send("music", ["action": action])

case "expand", "collapse", "search", "settings":
    send(command)

case "page":
    guard let index = rest.first else { fail("page needs a number (1 = first) or 'home'") }
    send("page", ["index": index])

case "preview":
    guard let name = rest.first else { fail("preview needs a name; see 'notch help'") }
    send("preview", ["name": name])

default:
    fail("unknown command '\(command)'. Run 'notch help'.")
}
