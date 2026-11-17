import AppKit
import SwiftUI

// MARK: - Panel

final class NotchPanel: NSPanel {
    /// Only true while the search field is up; otherwise the island never takes keyboard focus.
    var allowsKey = false

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3) // above the menu bar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        // ignoresMouseEvents is deliberately left at its default: fully transparent
        // pixels stay click-through, so only the black island itself catches clicks.
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

final class IslandHostingView<Content: View>: NSHostingView<Content> {
    var onRightClick: ((NSEvent) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func rightMouseDown(with event: NSEvent) {
        if let onRightClick { onRightClick(event) } else { super.rightMouseDown(with: event) }
    }
}

final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [URL] = []
    func add(_ url: URL) { lock.lock(); items.append(url); lock.unlock() }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return items }
}

// MARK: - Controller

@MainActor
final class NotchController: NSObject, NSApplicationDelegate, NSMenuDelegate, IslandActions {
    let model = IslandModel()
    let panel = NotchPanel()
    var hosting: IslandHostingView<IslandRoot>!
    var statusItem: NSStatusItem!
    var customExpiry: [String: Date] = [:]

    private let lockMonitor = ScreenLockMonitor()
    private var settingsWindow: NSWindow?
    private var ready = false
    private var pendingURLs: [URL] = []
    private var timers: [Timer] = []
    private var monitors: [Any] = []
    private var enterWork: DispatchWorkItem?
    private var exitWork: DispatchWorkItem?
    private var alertQueue: [IslandAlert] = []
    private var alertWork: DispatchWorkItem?
    private var lastDragChangeCount = NSPasteboard(name: .drag).changeCount
    private var scrollAccumulator: CGFloat = 0
    private var scrollLocked = false
    private var reservedLength: CGFloat = -1
    private var reservationFits = true
    private var previewTimer: Timer?
    private var obscurer = Obscurer.none
    private var presentationObserver: NSKeyValueObservation?
    private var coverCheckCountdown = 0
    private var spaceCheckPhase = false

    /// Why the island is currently out of the way (see FullScreen.swift).
    private enum Obscurer: String {
        case none
        case fullScreenSpace = "full-screen Space"      // native full screen or Split View
        case coveringWindow = "window covering the display"   // borderless full screen
    }

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.actions = self
        let settings = model.settings
        hosting = IslandHostingView(rootView: IslandRoot(model: model))
        hosting.sizingOptions = []
        hosting.onRightClick = { [weak self] event in self?.showContextMenu(event) }
        panel.contentView = hosting
        panel.appearance = NSAppearance(named: .darkAqua)

        buildStatusItem()
        layoutForScreens()

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(screensChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        ws.addObserver(self, selector: #selector(screensChanged), name: NSWorkspace.didWakeNotification, object: nil)
        // Full screen comes and goes with the frontmost app and with the menu bar being hidden.
        ws.addObserver(self, selector: #selector(frontmostAppChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        presentationObserver = NSApp.observe(\.currentSystemPresentationOptions) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateObscured() } }
        }

        settings.onChange = { [weak self] key in self?.settingChanged(key) }

        model.music.allowOnlineArtwork = { settings[.onlineArtwork] }
        model.music.pausedTimeout = { settings[.hidePausedMusic] ? 600 : nil }
        model.music.onTrackChange = { [weak self] track in self?.trackChanged(track) }
        model.music.start()

        model.power.onChange = { [weak self] old, new in self?.powerChanged(old, new) }
        model.power.start()
        model.audio.onDeviceChange = { [weak self] device in self?.outputChanged(device) }
        model.audio.onMuteChange = { [weak self] muted in self?.muteChanged(muted) }
        model.audio.start()
        lockMonitor.onUnlock = { [weak self] in self?.unlocked() }
        lockMonitor.start()
        if settings[.calendar] { model.calendar.setEnabled(true, prompt: false) }

        addTimer(every: 0.5) { [weak self] in self?.clockTick() }
        addTimer(every: 0.1) { [weak self] in self?.pointerTick() }

        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHover() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.updateHover() }
            return event
        }) { monitors.append(m) }
        // A click anywhere else closes search, like Spotlight.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.endSearch() }
        }) { monitors.append(m) }
        // Two-finger swipe on the expanded island flips between live activities.
        if let m = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleScroll(event) }
            return event
        }) { monitors.append(m) }

        if !settings[.hasOnboarded] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                MainActor.assumeIsolated { self?.showWelcome() }
            }
        }

        ready = true
        pendingURLs.forEach(handle(url:))
        pendingURLs.removeAll()
        NSLog("NotchActivity: started, notch=%@", model.hasNotch ? "\(model.geometry.notchWidth)x\(model.geometry.notchHeight)" : "none")
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.music.shutdown()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if ready { urls.forEach(handle(url:)) } else { pendingURLs += urls }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()   // launching the app again is how people look for its window
        return false
    }

    private func addTimer(every interval: TimeInterval, _ block: @escaping @MainActor () -> Void) {
        let t = Timer(timeInterval: interval, repeats: true) { _ in MainActor.assumeIsolated { block() } }
        t.tolerance = interval * 0.2
        RunLoop.main.add(t, forMode: .common)
        timers.append(t)
    }

    private func settingChanged(_ key: AppSettings.Key) {
        switch key {
        case .calendar:
            let on = model.settings[.calendar]
            model.calendar.setEnabled(on, prompt: true) { [weak self] granted in
                // Leave the switch on if access was denied earlier, so Settings can explain why.
                if on, !granted, self?.model.calendar.denied == false { self?.model.settings[.calendar] = false }
            }
        case .hideInFullScreen:
            updateObscured()
        default:
            break
        }
    }

    // MARK: Placement

    @objc func screensChanged() {
        reservationFits = true   // a different menu bar may have room again
        layoutForScreens()
    }

    @objc func frontmostAppChanged() {
        updateObscured()
        // The new app's windows may still be animating into place.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated { self?.updateObscured() }
        }
    }

    // MARK: Stepping aside for full screen

    /// Works out whether something full screen has taken over the notched display, and gets
    /// the island out of the way (or brings it back).
    ///
    /// The Space check is cheap and runs several times a second, so the island is gone before
    /// a full-screen transition finishes. Listing windows costs more: `checkWindows` is false
    /// on the fast path, which then only re-checks a covering window it already knows about.
    func updateObscured(checkWindows: Bool = true) {
        var new = Obscurer.none
        if model.settings[.hideInFullScreen], model.hasNotch, !model.hiddenByUser {
            let g = model.geometry
            if FullScreenDetector.isFullScreenSpace(displayID: g.displayID, menuBarHeight: g.notchHeight) {
                new = .fullScreenSpace
            } else if checkWindows || obscurer == .coveringWindow,
                      FullScreenDetector.frontmostAppCovers(displayID: g.displayID) {
                new = .coveringWindow
            }
        }
        guard new != obscurer else { return }
        obscurer = new
        model.obscured = new != .none
        if new == .none {
            islandLog.notice("Island showing again")
        } else {
            islandLog.notice("Island hidden: \(new.rawValue, privacy: .public)")
        }

        if model.obscured {
            // Nothing queued should pop out when the island comes back.
            alertQueue.removeAll()
            dismissAlert()
            enterWork?.cancel(); enterWork = nil
            model.hovering = false
            if model.searching { endSearch() }
        }
        applyPanelVisibility()
    }

    private func applyPanelVisibility() {
        if !model.hasNotch || model.hiddenByUser || obscurer != .none {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    func layoutForScreens() {
        if let g = NotchGeometry.find() {
            model.geometry = g
            model.hasNotch = true
            let size = model.windowSize
            panel.setFrame(NSRect(x: (g.midX - size.width / 2).rounded(), y: g.top - size.height,
                                  width: size.width, height: size.height), display: true)
        } else {
            // No notched display (e.g. lid closed on an external): don't float an island
            // in the middle of a notch-less menu bar.
            model.hasNotch = false
        }
        updateObscured()          // decide first, so the panel is never ordered in over full screen
        applyPanelVisibility()
        updateStatusReservation(force: true)
    }

    /// Global rect of the island body as currently drawn (shoulders included).
    func islandRect() -> NSRect {
        let g = model.geometry, s = model.bodySize
        return NSRect(x: g.midX - s.width / 2 - Island.shoulder, y: g.top - s.height,
                      width: s.width + 2 * Island.shoulder, height: s.height)
    }

    // MARK: Ticks

    private func clockTick() {
        let now = Date()
        model.now = now
        if model.timer.finishIfDue(at: now) { timerFinished() }
        model.calendar.refresh(now: now)
        for (id, expiry) in customExpiry where now >= expiry { endCustomActivity(id) }
        updateStatusReservation()
        // Backstop: a window can cover the screen without any notification firing.
        coverCheckCountdown -= 1
        if coverCheckCountdown <= 0 {
            coverCheckCountdown = 2
            updateObscured()
        }
    }

    private func pointerTick() {
        updateHover()
        detectFileDrag()
        // Every 0.2s: has the notched display gone into (or out of) a full-screen Space?
        spaceCheckPhase.toggle()
        if spaceCheckPhase { updateObscured(checkWindows: false) }
    }

    // MARK: Hover

    func updateHover() {
        let p = model.presentation
        guard p != .hidden, p != .search, p != .drop, p != .welcome else { return }
        var zone = islandRect()
        switch p {
        case .expanded: zone = zone.insetBy(dx: -10, dy: -10)
        case .idle: zone = zone.insetBy(dx: -8, dy: 0)
        default: break
        }
        zone.size.height += 6   // include the very top row of pixels
        let inside = zone.contains(NSEvent.mouseLocation)

        if inside {
            exitWork?.cancel(); exitWork = nil
            guard !model.hovering, enterWork == nil, model.settings[.expandOnHover] else { return }
            // A short dwell, so sweeping across the menu bar doesn't pop the island open.
            let w = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.enterWork = nil; self?.setHovering(true) }
            }
            enterWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: w)
        } else {
            enterWork?.cancel(); enterWork = nil
            guard model.hovering, exitWork == nil else { return }
            let w = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.exitWork = nil; self?.setHovering(false) }
            }
            exitWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
        }
    }

    private func setHovering(_ value: Bool) {
        guard model.hovering != value else { return }
        withAnimation(value ? Island.morph : Island.settle) {
            model.hovering = value
            if !value, !model.pinned { model.pageIndex = 0 }
        }
        if value { haptic() }
    }

    private func handleScroll(_ e: NSEvent) {
        guard model.presentation == .expanded, model.pages.count > 1,
              islandRect().contains(NSEvent.mouseLocation), e.momentumPhase == [] else { return }
        if e.phase == .began { scrollAccumulator = 0; scrollLocked = false }
        if !scrollLocked {
            scrollAccumulator += e.scrollingDeltaX
            if abs(scrollAccumulator) > 45 {
                let count = model.pages.count
                let step = scrollAccumulator < 0 ? 1 : -1
                model.selectPage((model.pageIndex + step + count) % count)
                scrollLocked = true
                haptic()
            }
        }
        if e.phase == .ended || e.phase == .cancelled { scrollAccumulator = 0; scrollLocked = false }
    }

    private func haptic() {
        guard model.settings[.haptics] else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    // MARK: AirDrop (drag files to the notch)

    private func detectFileDrag() {
        let pb = NSPasteboard(name: .drag)
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            lastDragChangeCount = pb.changeCount
            if model.dropTargeting {
                withAnimation(Island.morph) { model.dropTargeting = false; model.dropHighlighted = false }
            }
            return
        }
        guard ![.hidden, .search, .welcome].contains(model.presentation),
              pb.changeCount != lastDragChangeCount,
              pb.types?.contains(.fileURL) == true else { return }
        let mouse = NSEvent.mouseLocation, g = model.geometry
        let reach: CGFloat = model.dropTargeting ? g.notchHeight + 140 : g.notchHeight + 50
        let near = abs(mouse.x - g.midX) < model.expandedWidth / 2 + 24 && mouse.y > g.top - reach
        guard near != model.dropTargeting else { return }
        withAnimation(Island.pop) { model.dropTargeting = near }
        if near { haptic() }
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let box = URLBox()
        let group = DispatchGroup()
        for p in providers where p.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { box.add(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                withAnimation(Island.morph) { self.model.dropTargeting = false; self.model.dropHighlighted = false }
                self.airDrop(box.urls)
            }
        }
        return true
    }

    private func airDrop(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            showAlert(IslandAlert(icon: "dot.radiowaves.left.and.right", title: "AirDrop", value: "Unavailable",
                                  tint: Color(red: 0.35, green: 0.68, blue: 1), valueTint: .white.opacity(0.55)),
                      force: true)
            return
        }
        NSApp.activate()
        service.perform(withItems: urls)
    }

    func pickFilesForAirDrop() {
        setHovering(false)
        NSApp.activate()
        let open = NSOpenPanel()
        open.allowsMultipleSelection = true
        open.canChooseDirectories = true
        open.prompt = "AirDrop"
        open.message = "Choose files to send with AirDrop"
        open.begin { [weak self] response in
            MainActor.assumeIsolated {
                if response == .OK { self?.airDrop(open.urls) }
            }
        }
    }

    // MARK: Search

    func beginSearch() {
        guard model.hasNotch, !model.hiddenByUser, !model.obscured else { return }
        model.search.reset()
        model.search.prepare()
        withAnimation(Island.morph) { model.searching = true }
        panel.allowsKey = true
        panel.makeKeyAndOrderFront(nil)   // non-activating: the app you were in stays frontmost
    }

    func endSearch() {
        guard model.searching else { return }
        withAnimation(Island.settle) {
            model.searching = false
            model.hovering = islandRect().contains(NSEvent.mouseLocation)
        }
        panel.allowsKey = false
        // Hand keyboard focus back to whatever the user was typing in.
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    func activateSearchResult(_ index: Int?) {
        let copied = model.search.activate(index)
        endSearch()
        if let value = copied {
            showAlert(IslandAlert(icon: "doc.on.clipboard.fill", title: "Copied", value: value, tint: .orange,
                                  valueTint: .white), force: true)
        }
    }

    // MARK: Other actions

    func openSiri() {
        setHovering(false)
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Siri.app"),
                                           configuration: NSWorkspace.OpenConfiguration())
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func startTimer(seconds: TimeInterval) {
        withAnimation(Island.pop) {
            model.timer.start(seconds)
            model.promote(.timer)
            model.pageIndex = 0
        }
    }

    private func timerFinished() {
        NSSound(named: "Glass")?.play()
        showAlert(IslandAlert(icon: "timer", title: "Timer", value: "Done", tint: .orange), force: true)
    }

    func endCustomActivity(_ id: String) {
        customExpiry[id] = nil
        guard model.custom(id) != nil else { return }
        withAnimation(Island.morph) {
            model.customs.removeAll { $0.id == id }
            model.priority.removeAll { $0 == .custom(id) }
        }
    }

    func openSettings() { openSettings(activate: true) }

    func openSettings(activate: Bool) {
        withAnimation(Island.settle) { model.hovering = false }
        if settingsWindow == nil {
            let view = SettingsView(model: model) { [weak self] in self?.showWelcome() }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "NotchActivity Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        if activate {
            NSApp.activate()
            settingsWindow?.makeKeyAndOrderFront(nil)
        } else {
            settingsWindow?.orderFrontRegardless()
        }
    }

    func showWelcome() {
        guard model.hasNotch else { return }
        if model.hiddenByUser { model.hiddenByUser = false; layoutForScreens() }
        dismissAlert()
        withAnimation(Island.pop) { model.welcoming = true }
    }

    func finishWelcome() {
        model.settings[.hasOnboarded] = true
        withAnimation(Island.settle) {
            model.welcoming = false
            model.hovering = false
        }
    }

    // MARK: Alerts

    /// `force` bypasses the per-category switches in Settings (used for things the user asked for).
    func showAlert(_ alert: IslandAlert, force: Bool = false, if key: AppSettings.Key? = nil) {
        if let key, !force, !model.settings[key] { return }
        guard model.hasNotch, !model.hiddenByUser, !model.obscured, !model.searching, !model.welcoming else { return }
        alertQueue.append(alert)
        if model.alert == nil, alertWork == nil { showNextAlert() }
    }

    private func showNextAlert() {
        guard !model.searching, !alertQueue.isEmpty else { alertQueue.removeAll(); return }
        let next = alertQueue.removeFirst()
        withAnimation(Island.pop) { model.alert = next }
        haptic()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.dismissAlert() } }
        alertWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + next.duration, execute: w)
    }

    func dismissAlert() {
        alertWork?.cancel()
        alertWork = nil
        guard model.alert != nil else { return }
        withAnimation(Island.settle) { model.alert = nil }
        if !alertQueue.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                MainActor.assumeIsolated { if self?.model.alert == nil { self?.showNextAlert() } }
            }
        }
    }

    /// Drops queued alerts with this tag, and the one on screen if it has it.
    func cancelAlerts(tagged tag: String) {
        alertQueue.removeAll { $0.tag == tag }
        if model.alert?.tag == tag { dismissAlert() }
    }

    private func trackChanged(_ track: TrackInfo) {
        guard model.settings[.trackPeek] else { return }
        // Give the cover a moment to arrive, so the preview opens with it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.model.music.track?.id == track.id,
                      [.compact, .idle].contains(self.model.presentation) else { return }
                self.showAlert(self.trackAlert(track))
            }
        }
    }

    private func trackAlert(_ track: TrackInfo) -> IslandAlert {
        IslandAlert(kind: .nowPlaying, icon: "music.note", title: track.title,
                    value: track.artist.isEmpty ? track.appName : track.artist,
                    tint: .white, valueTint: .white.opacity(0.6), duration: 3)
    }

    private func powerChanged(_ old: PowerSnapshot, _ new: PowerSnapshot) {
        guard new.hasBattery else { return }
        if !old.onAC, new.onAC {
            showAlert(chargingAlert(new), if: .alertPower)
        } else if !new.onAC, [20, 10, 5].contains(where: { old.percent > $0 && new.percent <= $0 }) {
            showAlert(lowBatteryAlert(new.percent), if: .alertPower)
        }
    }

    private func chargingAlert(_ s: PowerSnapshot) -> IslandAlert {
        IslandAlert(icon: "bolt.fill", title: s.charging || s.percent < 100 ? "Charging" : "Power Connected",
                    value: "\(s.percent)%", valueIcon: "battery.100percent.bolt", tint: .green)
    }

    private func lowBatteryAlert(_ percent: Int) -> IslandAlert {
        IslandAlert(icon: "battery.25percent", title: "Low Battery", value: "\(percent)%", tint: .red)
    }

    private func outputChanged(_ device: OutputDevice) {
        guard device.isExternal else { return }
        showAlert(connectedAlert(device), if: .alertAudio)
    }

    private func connectedAlert(_ d: OutputDevice) -> IslandAlert {
        IslandAlert(icon: d.symbol, title: d.name, value: "Connected", tint: .white, valueTint: .green)
    }

    private func muteChanged(_ muted: Bool) {
        showAlert(muteAlert(muted), if: .alertMute)
    }

    private func muteAlert(_ muted: Bool) -> IslandAlert {
        IslandAlert(icon: muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    title: muted ? "Silent Mode" : "Sound On",
                    value: muted ? "On" : model.audio.device.name,
                    tint: muted ? .red : .white,
                    valueTint: muted ? .red : .white.opacity(0.55))
    }

    private func unlocked() {
        showAlert(unlockAlert(), if: .alertUnlock)
    }

    private func unlockAlert() -> IslandAlert {
        IslandAlert(icon: "lock.open.fill", title: "Unlocked", value: "", valueIcon: "checkmark.circle.fill",
                    tint: .white, valueTint: .green, duration: 1.8)
    }

    // MARK: Status item (doubles as a spacer so the island never covers other icons)

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: 26)
        statusItem.button?.setAccessibilityLabel("NotchActivity")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusReservation(force: true)
    }

    /// Status items fill leftward from the right edge and ours is the leftmost. macOS already
    /// keeps ~22pt clear beside the notch; widening our item by whatever the island's right ear
    /// needs beyond that keeps every other app's icon out from under the island.
    private func updateStatusReservation(force: Bool = false) {
        var extra = max(0, model.restingRightCoverage - Island.menuBarNotchMargin)
        extra += UserDefaults.standard.double(forKey: "debugExtraReserve")
        if !reservationFits { extra = 0 }
        let length = (26 + extra).rounded()
        guard force || length != reservedLength else { return }
        reservedLength = length
        statusItem.length = length
        statusItem.button?.image = statusIcon(width: length)
        guard extra > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            MainActor.assumeIsolated { self?.checkReservationFits() }
        }
    }

    /// On a packed menu bar the wider item can get pushed into macOS's « overflow, which would
    /// hide our icon. If that happens, give the space back.
    private func checkReservationFits() {
        guard reservationFits, let window = statusItem.button?.window else { return }
        let visible = window.occlusionState.contains(.visible)
        let onScreen = window.frame.minX >= model.geometry.notchRight
        if !visible || !onScreen {
            reservationFits = false
            updateStatusReservation(force: true)
        }
    }

    /// A little screen with a notch, drawn at the right end of the (possibly widened) item.
    private func statusIcon(width: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: 18), flipped: false) { rect in
            let glyph = NSRect(x: rect.maxX - 6 - 17, y: (rect.height - 12) / 2, width: 17, height: 12)
            NSColor.black.set()
            let screen = NSBezierPath(roundedRect: glyph.insetBy(dx: 0.75, dy: 0.75), xRadius: 3, yRadius: 3)
            screen.lineWidth = 1.5
            screen.stroke()
            NSBezierPath(roundedRect: NSRect(x: glyph.midX - 3.5, y: glyph.maxY - 4.6, width: 7, height: 3.6),
                         xRadius: 1.6, yRadius: 1.6).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: Menus (status item + right-click on the island)

    func menuNeedsUpdate(_ menu: NSMenu) { populate(menu) }

    private func showContextMenu(_ event: NSEvent) {
        let menu = NSMenu()
        populate(menu)
        menu.popUp(positioning: nil, at: hosting.convert(event.locationInWindow, from: nil), in: hosting)
    }

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        let music = model.music

        if let t = music.track {
            menu.addItem(disabled(t.artist.isEmpty ? t.title : "\(t.title) — \(t.artist)"))
            menu.addItem(item(t.isPlaying ? "Pause" : "Play", #selector(menuPlayPause)))
            menu.addItem(item("Next Track", #selector(menuNext)))
            menu.addItem(item("Previous Track", #selector(menuPrevious)))
        } else {
            menu.addItem(disabled(music.setting == .demo ? "Demo stopped" : "Nothing Playing"))
        }
        if let denied = music.deniedApp {
            menu.addItem(item("Allow Access to \(denied)…", #selector(menuOpenAutomation)))
        }
        menu.addItem(.separator())

        let timerMenu = NSMenu()
        for minutes in [1, 3, 5, 10, 25] {
            let i = item("\(minutes) Minute\(minutes == 1 ? "" : "s")", #selector(menuStartTimer(_:)))
            i.tag = minutes * 60
            timerMenu.addItem(i)
        }
        menu.addItem(submenu("Start Timer", timerMenu))
        if model.timer.isActive {
            menu.addItem(item(model.timer.isRunning ? "Pause Timer" : "Resume Timer", #selector(menuToggleTimer)))
            menu.addItem(item("Cancel Timer", #selector(menuCancelTimer)))
        }
        menu.addItem(item("Search…", #selector(menuSearch)))
        menu.addItem(item("AirDrop Files…", #selector(menuAirDrop)))
        menu.addItem(.separator())

        let pin = item("Keep Expanded", #selector(menuTogglePin))
        pin.state = model.pinned ? .on : .off
        pin.isEnabled = model.hasNotch && !model.hiddenByUser
        menu.addItem(pin)
        let vis = item(model.hiddenByUser ? "Show Island" : "Hide Island", #selector(menuToggleVisible))
        vis.isEnabled = model.hasNotch
        menu.addItem(vis)
        if !model.hasNotch { menu.addItem(disabled("No Notch Display Connected")) }
        menu.addItem(.separator())

        let previewMenu = NSMenu()
        let previews = ["Charging", "Low Battery", "AirPods Connected", "Silent Mode", "Unlocked", "Timer Done",
                        "New Track", "Upcoming Event", "Live Activity"]
        for (i, title) in previews.enumerated() {
            let p = item(title, #selector(menuPreview(_:)))
            p.tag = i
            previewMenu.addItem(p)
        }
        menu.addItem(submenu("Preview", previewMenu))
        menu.addItem(item("Settings…", #selector(menuSettings), key: ","))
        menu.addItem(item("About NotchActivity", #selector(menuAbout)))
        menu.addItem(.separator())
        menu.addItem(item("Quit NotchActivity", #selector(menuQuit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.submenu = menu
        return i
    }

    @objc private func menuPlayPause() { model.music.togglePlay() }
    @objc private func menuNext() { model.music.next() }
    @objc private func menuPrevious() { model.music.previous() }
    @objc private func menuStartTimer(_ sender: NSMenuItem) { startTimer(seconds: TimeInterval(sender.tag)) }
    @objc private func menuToggleTimer() { model.timer.toggle() }
    @objc private func menuCancelTimer() { withAnimation(Island.morph) { model.timer.cancel() } }
    @objc private func menuSearch() { beginSearch() }
    @objc private func menuAirDrop() { pickFilesForAirDrop() }
    @objc private func menuSettings() { openSettings() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    @objc private func menuAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(
                string: "A Dynamic Island–style home for music, timers, and alerts in the MacBook notch.",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]),
        ])
    }

    @objc private func menuOpenAutomation() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func menuTogglePin() {
        withAnimation(Island.morph) { model.pinned.toggle() }
    }

    @objc private func menuToggleVisible() {
        model.hiddenByUser.toggle()
        if model.hiddenByUser { model.hovering = false; model.pinned = false }
        layoutForScreens()
    }

    @objc private func menuPreview(_ sender: NSMenuItem) { runPreview(sender.tag) }

    static let previewNames = ["charging", "lowbattery", "airpods", "silent", "unlocked", "timerdone",
                               "track", "event", "activity"]

    /// Shows a sample of one alert or activity (index into `previewNames`).
    func runPreview(_ index: Int) {
        let power = model.power.state
        switch index {
        case 0: showAlert(chargingAlert(PowerSnapshot(hasBattery: true, percent: power.percent, onAC: true, charging: true)), force: true)
        case 1: showAlert(lowBatteryAlert(min(power.percent, 19)), force: true)
        case 2: showAlert(connectedAlert(OutputDevice(id: 0, name: "AirPods Pro", symbol: "airpods.pro", isExternal: true)), force: true)
        case 3: showAlert(muteAlert(true), force: true)
        case 4: showAlert(unlockAlert(), force: true)
        case 5:
            NSSound(named: "Glass")?.play()
            showAlert(IslandAlert(icon: "timer", title: "Timer", value: "Done", tint: .orange), force: true)
        case 6:
            if let track = model.music.track { showAlert(trackAlert(track), force: true) }
        case 7:
            model.calendar.showPreview()
            if model.calendar.upcoming != nil { withAnimation(Island.pop) { model.promote(.calendar) } }
        default:
            previewLiveActivity()
        }
    }

    /// A sample activity that fills its progress bar over ten seconds, then reports success.
    private func previewLiveActivity() {
        previewTimer?.invalidate()
        let base = "\(Self.urlScheme)://"
        func send(_ s: String) { if let url = URL(string: base + s) { handle(url: url) } }
        send("end?id=preview")
        send("activity?id=preview&title=Exporting%20Video&subtitle=Summer%20Trip.mov&icon=film.fill&tint=purple&progress=0")
        var progress = 0.0
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                progress += 0.05
                if progress >= 1 {
                    timer.invalidate()
                    self?.previewTimer = nil
                    send("end?id=preview&status=success&message=Exported")
                } else {
                    send(String(format: "activity?id=preview&progress=%.2f", progress))
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        previewTimer = t
    }
}
