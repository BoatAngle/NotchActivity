import AppKit
import OSLog
import SwiftUI

let nowPlayingLog = Logger(subsystem: "com.harrisonbraun.notchactivity", category: "NowPlaying")

// Now Playing has three backends:
//
//   system   Whatever macOS considers "now playing" — Music, Spotify, Podcasts, a YouTube tab
//            in Safari or Chrome, anything. Read through /usr/bin/osascript (see
//            SystemNowPlaying); needs no permission prompts.
//   scripts  Fallback if the system route is unavailable: Apple Music and Spotify over
//            Apple Events (asks for Automation access once per app).
//   demo     Built-in sample tracks.

struct TrackInfo: Equatable {
    var id: String
    var title: String
    var artist: String
    var album = ""
    var duration: TimeInterval          // 0 = unknown (live streams)
    var position: TimeInterval
    var sampledAt: Date
    var isPlaying: Bool
    var rate: Double = 1
    var appBundleID: String?            // nil = demo
    var appName: String
    var artwork: NSImage?
    var colors: [Color]

    var isDemo: Bool { appBundleID == nil }
    var hasDuration: Bool { duration > 1 }

    /// Position extrapolated from the last sample, so progress moves smoothly between updates.
    func position(at now: Date) -> TimeInterval {
        guard isPlaying else { return position }
        let p = max(0, position + now.timeIntervalSince(sampledAt) * (rate > 0 ? rate : 1))
        return hasDuration ? min(duration, p) : p
    }
}

/// What a backend reports, before artwork and colors are attached.
struct RawTrack: Equatable {
    var isPlaying: Bool
    var title: String
    var artist: String
    var album = ""
    var duration: TimeInterval
    var position: TimeInterval
    var sampledAt = Date()
    var rate: Double = 1
    var bundleID: String
    var appName: String
    var storeID: String?
    var artworkURL: String?

    var id: String { "\(bundleID)|\(title)|\(artist)|\(album)" }
}

// MARK: - Controller

@MainActor @Observable
final class MusicController {
    enum Setting: String { case automatic, demo }
    enum Backend: String { case system, scripts }

    private(set) var setting: Setting
    private(set) var backend: Backend = .system
    private(set) var track: TrackInfo?
    /// Scripts backend only: the app macOS refused Automation access to.
    private(set) var deniedApp: String?

    /// A different track started playing (not fired for pause/resume or the first load).
    @ObservationIgnored var onTrackChange: ((TrackInfo) -> Void)?
    @ObservationIgnored var allowOnlineArtwork: () -> Bool = { true }
    /// Seconds a paused track stays on the island; nil keeps it until the player quits.
    @ObservationIgnored var pausedTimeout: () -> TimeInterval? = { 600 }

    @ObservationIgnored private let demo = DemoPlayer()
    @ObservationIgnored private let system = SystemNowPlaying()
    @ObservationIgnored private let bridge = ScriptBridge()
    @ObservationIgnored private lazy var artwork = ArtworkResolver(bridge: bridge)
    @ObservationIgnored private var tickTimer: Timer?
    @ObservationIgnored private var lastRaw: RawTrack?
    @ObservationIgnored private var pausedSince: Date?
    @ObservationIgnored private var polling = false
    @ObservationIgnored private var hasLoadedOnce = false

    init() {
        setting = Setting(rawValue: UserDefaults.standard.string(forKey: "musicSource") ?? "") ?? .automatic
    }

    func start() {
        system.onUpdate = { [weak self] raw in
            guard let self else { return }
            self.lastRaw = raw
            self.apply(raw)
        }
        system.onUnavailable = { [weak self] in
            nowPlayingLog.notice("System Now Playing unavailable; falling back to Music/Spotify scripting")
            self?.backend = .scripts
        }
        if setting == .automatic { system.start() }

        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t
        tick()
    }

    func shutdown() { system.stop() }

    func setSetting(_ s: Setting) {
        guard s != setting else { return }
        setting = s
        UserDefaults.standard.set(s.rawValue, forKey: "musicSource")
        lastRaw = nil
        pausedSince = nil
        hasLoadedOnce = false
        if s == .automatic, backend == .system { system.start() } else { system.stop() }
        if s == .automatic { setTrack(nil) }
        tick()
    }

    private func tick() {
        switch setting {
        case .demo:
            setTrack(demo.snapshot())
        case .automatic:
            switch backend {
            case .system: apply(lastRaw)      // re-evaluates the paused timeout
            case .scripts: pollPlayers()
            }
        }
    }

    private func apply(_ raw: RawTrack?) {
        guard setting == .automatic else { return }
        guard let raw, !raw.title.isEmpty else {
            pausedSince = nil
            setTrack(nil)
            return
        }
        if raw.isPlaying { pausedSince = nil } else if pausedSince == nil { pausedSince = Date() }
        if let limit = pausedTimeout(), let since = pausedSince, Date().timeIntervalSince(since) > limit {
            setTrack(nil)
            return
        }

        let id = raw.id
        let cached = artwork.cached(id)
        setTrack(TrackInfo(id: id, title: raw.title, artist: raw.artist, album: raw.album,
                           duration: max(0, raw.duration), position: raw.position, sampledAt: raw.sampledAt,
                           isPlaying: raw.isPlaying, rate: raw.rate,
                           appBundleID: raw.bundleID, appName: raw.appName,
                           artwork: cached?.image, colors: cached?.colors ?? AppIcons.colors(for: raw.bundleID)))
        artwork.resolve(raw, allowOnline: allowOnlineArtwork()) { [weak self] image, colors in
            guard let self, self.track?.id == id else { return }
            self.track?.artwork = image
            self.track?.colors = colors
        }
    }

    private func setTrack(_ new: TrackInfo?) {
        let old = track
        if new != old { track = new }
        if let new, new.id != old?.id, new.isPlaying, hasLoadedOnce { onTrackChange?(new) }
        if new != nil { hasLoadedOnce = true }
    }

    // MARK: Controls

    func togglePlay() {
        guard let t = track else { return }
        if t.isDemo { demo.toggle(); tick(); return }
        // Optimistic: flip now, then reconcile with what the player actually reports.
        track?.position = t.position(at: Date())
        track?.sampledAt = Date()
        track?.isPlaying.toggle()
        perform(.toggle, script: "playpause", for: t)
        reconcileSoon()
    }

    func next() {
        guard let t = track else { return }
        if t.isDemo { demo.next(); tick(); return }
        perform(.next, script: "next track", for: t)
    }

    /// Like Music: more than 3s in restarts the song, otherwise goes back a track.
    func previous() {
        guard let t = track else { return }
        if t.isDemo { demo.previous(); tick(); return }
        if t.position(at: Date()) > 3, t.hasDuration {
            seek(to: 0)
        } else {
            perform(.previous, script: "previous track", for: t)
        }
    }

    func stop() {
        guard let t = track else { return }
        if t.isDemo { demo.stop(); tick(); return }
        track?.isPlaying = false
        track?.position = 0
        perform(.pause, script: "pause", for: t)
        seek(to: 0)
        reconcileSoon()
    }

    func seek(to seconds: TimeInterval) {
        guard let t = track, t.hasDuration else { return }
        let target = min(max(0, seconds), t.duration)
        track?.position = target
        track?.sampledAt = Date()
        if t.isDemo { demo.seek(to: target); return }
        switch backend {
        case .system: MediaRemote.seek(to: target)
        case .scripts: runScript(String(format: "set player position to %.2f", target), for: t)
        }
    }

    func openSourceApp() {
        guard let id = track?.appBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func perform(_ command: MediaRemote.Command, script: String, for t: TrackInfo) {
        switch backend {
        case .system: MediaRemote.send(command)
        case .scripts: runScript(script, for: t)
        }
    }

    private func reconcileSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.setting == .automatic, self.backend == .system else { return }
                self.apply(self.lastRaw)
            }
        }
    }

    // MARK: Scripts backend (fallback)

    private func runScript(_ command: String, for t: TrackInfo) {
        guard let id = t.appBundleID else { return }
        let bridge = self.bridge
        bridge.queue.async { [weak self] in
            _ = bridge.run("tell application id \"\(id)\"\n\(command)\nend tell")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                MainActor.assumeIsolated { self?.pollPlayers() }
            }
        }
    }

    private func pollPlayers() {
        let running = ScriptBridge.players.filter {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
        }
        guard !running.isEmpty else { apply(nil); return }
        guard !polling else { return }
        polling = true
        let bridge = self.bridge
        bridge.queue.async { [weak self] in
            let results = running.map { ($0, bridge.state(of: $0)) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.polling = false
                    self.deniedApp = results.first(where: { if case .denied = $0.1 { true } else { false } })
                        .map { AppIcons.name(for: $0.0) }
                    let tracks = results.compactMap { r -> RawTrack? in
                        if case .track(let raw) = r.1 { return raw }
                        return nil
                    }
                    // Prefer whatever is actually playing; otherwise the paused one.
                    self.apply(tracks.first(where: \.isPlaying) ?? tracks.first)
                }
            }
        }
    }
}

// MARK: - System Now Playing

/// Streams macOS's system-wide Now Playing state.
///
/// Since macOS 15.4 the MediaRemote framework only answers Apple-signed processes, so the
/// read side runs inside `/usr/bin/osascript` (JavaScript for Automation): a small script
/// polls `MRNowPlayingRequest` twice a second and prints a JSON line whenever something
/// changes. This is a private interface; if a macOS update removes it the reader reports
/// `onUnavailable` and the app falls back to scripting Music and Spotify.
@MainActor
final class SystemNowPlaying {
    var onUpdate: ((RawTrack?) -> Void)?
    var onUnavailable: (() -> Void)?

    private var process: Process?
    private var buffer = Data()
    private var launchedAt = Date()
    private var quickFailures = 0
    private var running = false
    private var recycleTimer: Timer?

    func start() {
        guard !running else { return }
        running = true
        quickFailures = 0
        launch()
        // The helper is long-lived script code; recycle it now and then to keep it small.
        let t = Timer(timeInterval: 30 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.process?.terminate() }
        }
        RunLoop.main.add(t, forMode: .common)
        recycleTimer = t
    }

    func stop() {
        running = false
        recycleTimer?.invalidate()
        recycleTimer = nil
        process?.terminate()
        process = nil
    }

    private func launch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-l", "JavaScript", "-e", Self.script]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.consume(data) } }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.exited(proc) } }
        }
        buffer.removeAll()
        launchedAt = Date()
        do {
            try p.run()
            process = p
        } catch {
            nowPlayingLog.error("Could not start osascript: \(error.localizedDescription, privacy: .public)")
            fail()
        }
    }

    private func exited(_ proc: Process) {
        guard proc === process else { return }
        process = nil
        guard running else { return }
        if Date().timeIntervalSince(launchedAt) < 5 { quickFailures += 1 } else { quickFailures = 0 }
        if quickFailures >= 3 { fail(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated { if self?.running == true, self?.process == nil { self?.launch() } }
        }
    }

    private func fail() {
        running = false
        recycleTimer?.invalidate()
        process = nil
        onUnavailable?()
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if obj["fatal"] != nil {
                nowPlayingLog.error("System Now Playing: \(String(describing: obj["fatal"]), privacy: .public)")
                process?.terminate()
                fail()
                return
            }
            onUpdate?(Self.parse(obj))
        }
    }

    private static func parse(_ o: [String: Any]) -> RawTrack? {
        guard let title = o["title"] as? String, !title.isEmpty else { return nil }
        // Browsers play media in helper processes; the parent is the app the user knows.
        let bundle = (o["parent"] as? String) ?? (o["bundle"] as? String) ?? ""
        let received = Date()
        var sampledAt = received
        if let ts = o["timestamp"] as? Double {
            let d = Date(timeIntervalSince1970: ts)
            if d <= received, received.timeIntervalSince(d) < 86_400 { sampledAt = d }
        }
        let rate = o["rate"] as? Double ?? 0
        let storeID = (o["storeID"] as? NSNumber).map { $0.stringValue }
        return RawTrack(isPlaying: o["playing"] as? Bool ?? (rate > 0),
                        title: title,
                        artist: o["artist"] as? String ?? "",
                        album: o["album"] as? String ?? "",
                        duration: o["duration"] as? Double ?? 0,
                        position: o["elapsed"] as? Double ?? 0,
                        sampledAt: sampledAt,
                        rate: rate > 0 ? rate : 1,
                        bundleID: bundle,
                        appName: AppIcons.name(for: bundle, fallback: o["app"] as? String),
                        storeID: storeID == "0" ? nil : storeID)
    }

    private static let script = #"""
    function run() {
      ObjC.import('Foundation');
      ObjC.import('unistd');
      const out = $.NSFileHandle.fileHandleWithStandardOutput;
      const emit = o => out.writeData($(JSON.stringify(o) + '\n').dataUsingEncoding($.NSUTF8StringEncoding));
      $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/').load;
      const Req = $.NSClassFromString('MRNowPlayingRequest');
      if (!Req || (Req.isNil && Req.isNil())) { emit({ fatal: 'MRNowPlayingRequest is not available' }); return; }
      const str = v => (v.isNil() ? null : ObjC.unwrap(v));
      let last = '', errors = 0;
      while ($.getppid() !== 1) {
        let o = {};
        try {
          const path = Req.localNowPlayingPlayerPath;
          const client = path.isNil() ? null : path.client;
          if (client && !client.isNil()) {
            o.bundle = str(client.bundleIdentifier);
            o.parent = str(client.parentApplicationBundleIdentifier);
            o.app = str(client.displayName);
          }
          const item = Req.localNowPlayingItem;
          if (!item.isNil()) {
            const info = item.nowPlayingInfo;
            const get = k => { const v = info.valueForKey('kMRMediaRemoteNowPlayingInfo' + k); return v.isNil() ? null : ObjC.unwrap(v); };
            o.title = get('Title'); o.artist = get('Artist'); o.album = get('Album');
            o.duration = get('Duration'); o.elapsed = get('ElapsedTime'); o.rate = get('PlaybackRate');
            o.storeID = get('iTunesStoreIdentifier');
            const ts = info.valueForKey('kMRMediaRemoteNowPlayingInfoTimestamp');
            o.timestamp = ts.isNil() ? null : ts.timeIntervalSince1970;
          }
          o.playing = Req.localIsPlaying ? true : false;
          errors = 0;
        } catch (e) {
          if (++errors > 20) { emit({ fatal: String(e) }); return; }
          delay(0.5);
          continue;
        }
        const line = JSON.stringify(o);
        if (line !== last) { emit(o); last = line; }
        delay(0.5);
      }
    }
    """#
}

/// Playback commands go straight to MediaRemote: unlike reading, sending commands still
/// works from an ordinary process.
enum MediaRemote {
    enum Command: UInt32 {
        case play = 0, pause = 1, toggle = 2, stop = 3, next = 4, previous = 5
    }

    private typealias SendCommand = @convention(c) (UInt32, CFDictionary?) -> Bool
    private typealias SetElapsed = @convention(c) (Double) -> Void

    private static let bundle: CFBundle? = CFBundleCreate(
        kCFAllocatorDefault,
        URL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework") as CFURL)

    private static func function<T>(_ name: String, as type: T.Type) -> T? {
        guard let bundle, let pointer = CFBundleGetFunctionPointerForName(bundle, name as CFString) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    @discardableResult
    static func send(_ command: Command) -> Bool {
        function("MRMediaRemoteSendCommand", as: SendCommand.self)?(command.rawValue, nil) ?? false
    }

    static func seek(to seconds: TimeInterval) {
        function("MRMediaRemoteSetElapsedTime", as: SetElapsed.self)?(seconds)
    }
}

// MARK: - Apple Events bridge (runs only on its own serial queue)

enum PlayerState {
    case idle
    case track(RawTrack)
    case denied
    case failed
}

final class ScriptBridge: @unchecked Sendable {
    static let music = "com.apple.Music"
    static let spotify = "com.spotify.client"
    static let players = [music, spotify]

    let queue = DispatchQueue(label: "notchactivity.applescript", qos: .userInitiated)
    private var compiled: [String: NSAppleScript] = [:]

    func run(_ source: String) -> Result<NSAppleEventDescriptor, NSError> {
        dispatchPrecondition(condition: .onQueue(queue))
        let script: NSAppleScript
        if let s = compiled[source] {
            script = s
        } else {
            guard let s = NSAppleScript(source: "with timeout of 3 seconds\n\(source)\nend timeout") else {
                return .failure(NSError(domain: "ScriptBridge", code: -1))
            }
            compiled[source] = s
            script = s
        }
        var info: NSDictionary?
        let result = script.executeAndReturnError(&info)
        if let info {
            let code = (info[NSAppleScript.errorNumber] as? Int) ?? -1
            let message = info[NSAppleScript.errorMessage] as? String ?? ""
            nowPlayingLog.error("AppleScript error \(code, privacy: .public): \(message, privacy: .public)")
            return .failure(NSError(domain: "AppleScript", code: code, userInfo: [NSLocalizedDescriptionKey: message]))
        }
        return .success(result)
    }

    /// Whether this app may already send Apple Events to `bundleID`. Never shows the consent prompt.
    func automationPermitted(_ bundleID: String) -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false) == noErr
    }

    // Note: `st` is a reserved word in AppleScript (as in "1st"), hence `pState`.
    func state(of bundleID: String) -> PlayerState {
        let source: String
        if bundleID == Self.music {
            source = """
            tell application id "com.apple.Music"
                set pState to (player state as text)
                if pState is "stopped" then return {pState}
                try
                    set t to current track
                    return {pState, (name of t), (artist of t), (album of t), (duration of t), player position, ""}
                on error
                    return {"stopped"}
                end try
            end tell
            """
        } else {
            source = """
            tell application id "com.spotify.client"
                set pState to (player state as text)
                if pState is "stopped" then return {pState}
                set t to current track
                return {pState, (name of t), (artist of t), (album of t), ((duration of t) / 1000), player position, (artwork url of t)}
            end tell
            """
        }
        switch run(source) {
        case .failure(let e):
            return e.code == -1743 ? .denied : .failed   // -1743: Automation access declined
        case .success(let d):
            guard d.numberOfItems >= 6, let state = d.atIndex(1)?.stringValue else { return .idle }
            let url = d.atIndex(7)?.stringValue ?? ""
            return .track(RawTrack(isPlaying: state == "playing",
                                   title: d.atIndex(2)?.stringValue ?? "",
                                   artist: d.atIndex(3)?.stringValue ?? "",
                                   album: d.atIndex(4)?.stringValue ?? "",
                                   duration: d.atIndex(5)?.doubleValue ?? 0,
                                   position: d.atIndex(6)?.doubleValue ?? 0,
                                   bundleID: bundleID,
                                   appName: AppIcons.name(for: bundleID),
                                   artworkURL: url.isEmpty ? nil : url))
        }
    }

    func musicArtwork() -> Data? {
        let source = """
        tell application id "com.apple.Music"
            try
                return raw data of artwork 1 of current track
            end try
            try
                return data of artwork 1 of current track
            end try
        end tell
        return missing value
        """
        if case .success(let d) = run(source), d.descriptorType != typeNull, !d.data.isEmpty { return d.data }
        return nil
    }
}

// MARK: - Artwork

/// Finds cover art for a track:
///   1. Apple Music via Apple Events, only if Automation access was already granted (never prompts)
///   2. a URL supplied by the player (Spotify, scripts backend)
///   3. the public iTunes catalog — by store ID, else by "artist title" for music apps
///   4. nothing: the island shows the source app's icon instead
@MainActor
final class ArtworkResolver {
    private enum State {
        case loading
        case done(NSImage?, [Color])
    }

    private var states: [String: State] = [:]
    private var order: [String] = []
    private let bridge: ScriptBridge
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        return URLSession(configuration: config)
    }()

    init(bridge: ScriptBridge) { self.bridge = bridge }

    func cached(_ id: String) -> (image: NSImage, colors: [Color])? {
        if case .done(let image?, let colors) = states[id] { return (image, colors) }
        return nil
    }

    func resolve(_ raw: RawTrack, allowOnline: Bool, completion: @escaping (NSImage, [Color]) -> Void) {
        let id = raw.id
        guard states[id] == nil else { return }
        states[id] = .loading
        order.append(id)
        if order.count > 60, let evict = order.first {
            order.removeFirst()
            states[evict] = nil
        }
        Task { [weak self] in
            guard let self else { return }
            let data = await self.fetch(raw, allowOnline: allowOnline)
            if let data, let image = NSImage(data: data), image.isValid {
                let colors = accentColors(of: image)
                self.states[id] = .done(image, colors)
                completion(image, colors)
            } else {
                self.states[id] = .done(nil, [])
            }
        }
    }

    private func fetch(_ raw: RawTrack, allowOnline: Bool) async -> Data? {
        if raw.bundleID == ScriptBridge.music, let data = await localMusicArtwork() {
            nowPlayingLog.info("Artwork: from Music (\(data.count) bytes)")
            return data
        }
        if let s = raw.artworkURL, let url = URL(string: s), let data = await download(url) { return data }
        guard allowOnline else { return nil }
        if let storeID = raw.storeID {
            if let url = await catalogArtwork(query: "lookup?id=\(storeID)&entity=song", matchingArtist: nil),
               let data = await download(url) {
                nowPlayingLog.info("Artwork: catalog lookup by store ID (\(data.count) bytes)")
                return data
            }
            nowPlayingLog.info("Artwork: catalog lookup by store ID found nothing")
        }
        guard !raw.artist.isEmpty, !AppIcons.isBrowser(raw.bundleID) else { return nil }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        guard let term = "\(raw.artist) \(raw.title)".addingPercentEncoding(withAllowedCharacters: allowed),
              let url = await catalogArtwork(query: "search?term=\(term)&media=music&entity=song&limit=5",
                                             matchingArtist: raw.artist) else { return nil }
        return await download(url)
    }

    private func localMusicArtwork() async -> Data? {
        let bridge = self.bridge
        return await withCheckedContinuation { continuation in
            bridge.queue.async {
                let permitted = bridge.automationPermitted(ScriptBridge.music)
                nowPlayingLog.info("Artwork: Automation access to Music \(permitted ? "granted" : "not granted", privacy: .public)")
                continuation.resume(returning: permitted ? bridge.musicArtwork() : nil)
            }
        }
    }

    private func catalogArtwork(query: String, matchingArtist artist: String?) async -> URL? {
        guard let url = URL(string: "https://itunes.apple.com/" + query),
              let data = await download(url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return nil }
        let wanted = artist?.lowercased()
        for result in results {
            guard let art = result["artworkUrl100"] as? String else { continue }
            if let wanted {
                let found = (result["artistName"] as? String ?? "").lowercased()
                guard !found.isEmpty, found.contains(wanted) || wanted.contains(found) else { continue }
            }
            return URL(string: art.replacingOccurrences(of: "100x100", with: "600x600"))
        }
        return nil
    }

    private func download(_ url: URL) async -> Data? {
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return nil }
            return data
        } catch {
            nowPlayingLog.info("Artwork: \(url.host ?? "", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

/// App names, icons and icon-derived colors, for sources that have no cover art.
@MainActor
enum AppIcons {
    private static var icons: [String: NSImage] = [:]
    private static var palettes: [String: [Color]] = [:]

    nonisolated static func url(for bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    nonisolated static func name(for bundleID: String, fallback: String? = nil) -> String {
        if let url = url(for: bundleID) {
            let name = FileManager.default.displayName(atPath: url.path)
            return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        }
        return fallback ?? "Now Playing"
    }

    static func icon(for bundleID: String) -> NSImage? {
        if let i = icons[bundleID] { return i }
        guard let url = url(for: bundleID) else { return nil }
        let i = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleID] = i
        return i
    }

    static func colors(for bundleID: String) -> [Color] {
        if let c = palettes[bundleID] { return c }
        let c = icon(for: bundleID).map { accentColors(of: $0) } ?? [.white.opacity(0.9), .white.opacity(0.6)]
        palettes[bundleID] = c
        return c
    }

    nonisolated static func isBrowser(_ bundleID: String) -> Bool {
        ["com.apple.Safari", "com.apple.WebKit", "com.google.Chrome", "org.mozilla.firefox",
         "com.microsoft.edgemac", "company.thebrowser.Browser", "com.brave.Browser",
         "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "org.chromium.Chromium"]
            .contains { bundleID.hasPrefix($0) }
    }
}

// MARK: - Demo player (wall-clock based, so it can't drift)

struct DemoTrack {
    let title: String
    let artist: String
    let duration: TimeInterval
    let colors: [Color]

    static let catalog: [DemoTrack] = [
        DemoTrack(title: "Golden Gate", artist: "Bay Sound", duration: 214,
                  colors: [Color(red: 1.00, green: 0.58, blue: 0.24), Color(red: 0.91, green: 0.19, blue: 0.45)]),
        DemoTrack(title: "Notch Overdrive", artist: "Apple Silicon", duration: 187,
                  colors: [Color(red: 0.36, green: 0.50, blue: 1.00), Color(red: 0.66, green: 0.26, blue: 0.96)]),
        DemoTrack(title: "Liquid Glass", artist: "SF Symbols", duration: 243,
                  colors: [Color(red: 0.22, green: 0.86, blue: 0.74), Color(red: 0.13, green: 0.44, blue: 0.95)]),
    ]
}

@MainActor
final class DemoPlayer {
    private var index = 0
    private var startedAt = Date()          // wall-clock time the current track would have started
    private var pausedPosition: TimeInterval?

    private var track: DemoTrack { DemoTrack.catalog[index] }

    private func position(at now: Date) -> TimeInterval {
        pausedPosition ?? now.timeIntervalSince(startedAt)
    }

    func snapshot() -> TrackInfo {
        let now = Date()
        if pausedPosition == nil, position(at: now) >= track.duration { next() }
        // Anchor the sample to the track's start so equal states compare equal between ticks.
        return TrackInfo(id: "demo-\(index)", title: track.title, artist: track.artist, album: "Demo",
                         duration: track.duration, position: pausedPosition ?? 0,
                         sampledAt: pausedPosition == nil ? startedAt : .distantPast,
                         isPlaying: pausedPosition == nil, appBundleID: nil, appName: "Now Playing",
                         artwork: nil, colors: track.colors)
    }

    func toggle() {
        if let p = pausedPosition {
            startedAt = Date().addingTimeInterval(-p)
            pausedPosition = nil
        } else {
            pausedPosition = position(at: Date())
        }
    }

    func next() {
        index = (index + 1) % DemoTrack.catalog.count
        startedAt = Date()
        pausedPosition = nil
    }

    func previous() {
        if position(at: Date()) > 3 { seek(to: 0); return }
        index = (index - 1 + DemoTrack.catalog.count) % DemoTrack.catalog.count
        startedAt = Date()
        pausedPosition = nil
    }

    func stop() {
        pausedPosition = 0
    }

    func seek(to seconds: TimeInterval) {
        if pausedPosition != nil {
            pausedPosition = seconds
        } else {
            startedAt = Date().addingTimeInterval(-seconds)
        }
    }
}

// MARK: - Artwork colors

/// Two vivid colors pulled from an image, brightened enough to read on black
/// (used for the waveform and the artwork glow).
func accentColors(of image: NSImage) -> [Color] {
    let fallback = DemoTrack.catalog[0].colors
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return fallback }
    let side = 12
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    guard let ctx = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8,
                              bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return fallback }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))

    var candidates: [(score: Double, h: Double, s: Double, b: Double)] = []
    for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] > 128 {
        let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
        let mx = max(r, g, b), mn = min(r, g, b)
        guard mx > 0.12 else { continue }
        let sat = (mx - mn) / mx
        var hue = 0.0
        if mx != mn {
            if mx == r { hue = (g - b) / (mx - mn) }
            else if mx == g { hue = 2 + (b - r) / (mx - mn) }
            else { hue = 4 + (r - g) / (mx - mn) }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        candidates.append((sat * 0.7 + mx * 0.3, hue, sat, mx))
    }
    candidates.sort { $0.score > $1.score }
    guard let first = candidates.first else { return fallback }
    let second = candidates.first(where: { abs($0.h - first.h) > 0.06 }) ?? first

    func color(_ c: (score: Double, h: Double, s: Double, b: Double), shift: Double = 0) -> Color {
        // Low-saturation art (greys) still gets a soft, readable tint.
        Color(hue: c.h, saturation: max(0.35, min(c.s, 0.85)), brightness: max(0.8, c.b) - shift)
    }
    return [color(first), color(second, shift: 0.1)]
}
