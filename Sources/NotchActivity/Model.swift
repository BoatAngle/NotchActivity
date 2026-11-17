import AppKit
import SwiftUI

/// A screen the island can show when expanded. Live activities come first, Home is always last.
enum Page: Hashable {
    case music, timer, calendar, custom(String), home
}

/// What the island is doing right now (see `IslandModel.presentation` for the priority order).
enum Presentation: Equatable {
    case hidden     // no notched display, the user hid it, or something is full screen
    case idle       // nothing live: the island is just the notch
    case compact    // primary activity in the ears beside the notch
    case alert      // transient event (charging, AirPods, a new track...)
    case expanded   // hover / pinned: full card for the current page
    case search     // Spotlight-style search field
    case drop       // files are being dragged toward the notch: AirDrop target
    case welcome    // first-run introduction
}

struct IslandAlert: Equatable, Identifiable {
    enum Kind: Equatable { case standard, nowPlaying }
    let id = UUID()
    var kind: Kind = .standard
    var icon: String
    var title: String
    var value: String
    var valueIcon: String? = nil
    var tint: Color
    var valueTint: Color? = nil
    var duration: TimeInterval = 2.8
    /// Groups alerts about the same thing, so a newer one can replace an older one.
    var tag: String? = nil

    /// Track previews and alerts with longer text get wider ears.
    var ear: CGFloat {
        kind == .nowPlaying || title.count > 11 || value.count > 13 ? Island.peekEar : Island.alertEar
    }
}

/// A live activity posted by another app or script through the URL scheme / `notch` CLI.
struct CustomActivity: Identifiable, Equatable {
    let id: String
    var title: String
    var subtitle = ""
    var icon = "app.badge.fill"
    var tint: Color = .blue
    var progress: Double?           // 0...1, nil = no bar
    var indeterminate = false       // spinner
    var url: URL?                   // opened when the card is clicked
    var startedAt = Date()
}

/// Where a persistent "hero" element (artwork, waveform) sits for the current presentation,
/// in the island body's coordinate space. One view moves between slots instead of two
/// views cross-fading, which is what makes the morph read as a single object.
struct HeroSlot: Equatable {
    var x: CGFloat
    var y: CGFloat
    var size: CGFloat
    var radius: CGFloat
    var visible: Bool
}

/// Things the views ask the app to do that need AppKit (panel focus, open panels, menus).
@MainActor protocol IslandActions: AnyObject {
    func beginSearch()
    func endSearch()
    func pickFilesForAirDrop()
    func openSiri()
    func startTimer(seconds: TimeInterval)
    func dismissAlert()
    func activateSearchResult(_ index: Int?)
    func handleDrop(_ providers: [NSItemProvider]) -> Bool
    func openSettings()
    func finishWelcome()
    func endCustomActivity(_ id: String)
    func open(_ url: URL)
}

@MainActor @Observable
final class IslandModel {
    var geometry = NotchGeometry(notchWidth: 200, notchHeight: 32, midX: 0, top: 0)
    var hasNotch = false
    var hiddenByUser = false
    /// Something full screen has taken over the notched display (see FullScreen.swift).
    var obscured = false

    let settings = AppSettings()
    let music = MusicController()
    let timer = TimerActivity()
    let calendar = CalendarMonitor()
    let power = PowerMonitor()
    let audio = AudioMonitor()
    let search = SearchModel()

    var customs: [CustomActivity] = []
    /// Most recently started / promoted activity first. Activities not listed keep their natural order.
    var priority: [Page] = []

    var hovering = false
    var pinned = false
    var searching = false
    var dropTargeting = false
    var dropHighlighted = false
    var welcoming = false
    var alert: IslandAlert?
    var pageIndex = 0
    var now = Date()

    @ObservationIgnored weak var actions: IslandActions?

    // MARK: Activities

    func custom(_ id: String) -> CustomActivity? { customs.first { $0.id == id } }

    /// Live activities, primary first.
    var activities: [Page] {
        var live: [Page] = []
        if music.track != nil { live.append(.music) }
        if timer.isActive { live.append(.timer) }
        if calendar.upcoming != nil { live.append(.calendar) }
        live += customs.map { .custom($0.id) }
        return live.enumerated().sorted { a, b in
            let ra = priority.firstIndex(of: a.element) ?? Int.max
            let rb = priority.firstIndex(of: b.element) ?? Int.max
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }
    var pages: [Page] { activities + [.home] }
    var currentPage: Page {
        let p = pages
        return p[min(max(pageIndex, 0), p.count - 1)]
    }
    var primary: Page? { activities.first }
    var secondary: Page? { activities.count > 1 ? activities[1] : nil }

    func promote(_ page: Page) {
        priority.removeAll { $0 == page }
        priority.insert(page, at: 0)
    }

    var presentation: Presentation {
        if !hasNotch || hiddenByUser || obscured { return .hidden }
        if dropTargeting { return .drop }
        if searching { return .search }
        if welcoming { return .welcome }
        if alert != nil { return .alert }
        if hovering || pinned { return .expanded }
        return primary == nil ? .idle : .compact
    }

    // MARK: Layout (shared by views and hover hit-testing)

    func compactEar(for page: Page?) -> CGFloat {
        switch page {
        case .timer, .calendar: Island.compactTextEar
        case .music, .custom: Island.compactEar
        case .home, nil: 0
        }
    }
    var compactEar: CGFloat { compactEar(for: primary) }
    var alertEar: CGFloat { alert?.ear ?? Island.alertEar }

    var expandedWidth: CGFloat {
        max(Island.expandedMinWidth, geometry.notchWidth + 2 * Island.expandedEar)
    }
    var expandedEar: CGFloat { (expandedWidth - geometry.notchWidth) / 2 }

    static let welcomeHeight: CGFloat = 206

    func pageHeight(_ page: Page) -> CGFloat {
        switch page {
        case .music: 142
        case .timer: 86
        case .calendar: 90
        case .custom(let id): custom(id)?.progress != nil ? 100 : 84
        case .home: 124
        }
    }

    /// Size of the island body (between the shoulders) for the current presentation.
    var bodySize: CGSize {
        let n = geometry.notchWidth, h = geometry.notchHeight
        switch presentation {
        case .hidden, .idle: return CGSize(width: n, height: h)
        case .compact: return CGSize(width: n + 2 * compactEar, height: h)
        case .alert: return CGSize(width: n + 2 * alertEar, height: h)
        case .expanded: return CGSize(width: expandedWidth, height: h + pageHeight(currentPage))
        case .search: return CGSize(width: expandedWidth, height: h + search.contentHeight)
        case .drop: return CGSize(width: expandedWidth, height: h + 100)
        case .welcome: return CGSize(width: expandedWidth, height: h + Self.welcomeHeight)
        }
    }

    var bottomRadius: CGFloat {
        switch presentation {
        case .expanded, .search, .drop, .welcome: 32
        case .alert: 16
        default: 12
        }
    }

    var isLarge: Bool {
        [.expanded, .search, .drop, .welcome].contains(presentation)
    }

    var showsBubble: Bool { presentation == .compact && secondary != nil }

    /// Horizontal offset from the notch center to the bubble's center. The bubble goes on the
    /// LEFT: the right side of a MacBook menu bar is where status icons pile up, while the
    /// strip left of the notch is almost always empty.
    var bubbleOffset: CGFloat {
        -(geometry.notchWidth / 2 + compactEar + Island.shoulder + Island.bubbleGap
            + Island.shoulder + geometry.notchHeight / 2)
    }

    /// How far right of the notch the resting island reaches.
    var restingRightCoverage: CGFloat {
        guard hasNotch, !hiddenByUser, primary != nil else { return 0 }
        return compactEar + Island.shoulder
    }

    var windowSize: CGSize {
        let n = geometry.notchWidth, h = geometry.notchHeight
        let widest = max(expandedWidth,
                         n + 2 * Island.peekEar,
                         n + 2 * (Island.compactTextEar + 3 * Island.shoulder + h))
        return CGSize(width: widest + 2 * Island.shoulder + 2 * Island.shadowPad,
                      height: h + Island.maxContentHeight + Island.shadowPad)
    }

    // MARK: Hero elements

    private var compactSlotX: CGFloat { 4 + (compactEar - Island.clearance - 4) / 2 }
    static let artCompact: CGFloat = 22
    static let artExpanded: CGFloat = 56
    /// Vertical center of the title row on the music page, below the notch band.
    private var musicRowY: CGFloat { geometry.notchHeight + 8 + Self.artExpanded / 2 }

    var heroArt: HeroSlot {
        let h = geometry.notchHeight
        if music.track != nil {
            switch presentation {
            case .compact where primary == .music:
                return HeroSlot(x: compactSlotX, y: h / 2, size: Self.artCompact, radius: 6, visible: true)
            case .expanded where currentPage == .music:
                return HeroSlot(x: Island.pagePadding + Self.artExpanded / 2, y: musicRowY,
                                size: Self.artExpanded, radius: 13, visible: true)
            case .alert where alert?.kind == .nowPlaying:
                return HeroSlot(x: 16 + Self.artCompact / 2, y: h / 2, size: Self.artCompact, radius: 6, visible: true)
            default: break
            }
        }
        return HeroSlot(x: compactSlotX, y: h / 2, size: Self.artCompact, radius: 6, visible: false)
    }

    /// Center of the waveform; `x` is measured from the body's trailing edge.
    var heroWave: HeroSlot {
        let h = geometry.notchHeight
        if music.track != nil {
            switch presentation {
            case .compact where primary == .music:
                return HeroSlot(x: compactSlotX, y: h / 2, size: 1, radius: 0, visible: true)
            case .expanded where currentPage == .music:
                return HeroSlot(x: Island.pagePadding + Waveform.width / 2, y: musicRowY, size: 1.15, radius: 0, visible: true)
            default: break
            }
        }
        return HeroSlot(x: compactSlotX, y: h / 2, size: 1, radius: 0, visible: false)
    }

    // MARK: Interactions

    func title(for page: Page) -> String {
        switch page {
        case .music: music.track?.appName ?? "Now Playing"
        case .timer: "Timer"
        case .calendar: "Up Next"
        case .custom: "Live Activity"
        case .home: Self.dayFormatter.string(from: now)
        }
    }

    /// Click on the compact island: open it right away (hover alone waits a beat).
    func expandNow() {
        withAnimation(Island.morph) { hovering = true }
    }

    func selectPage(_ index: Int) {
        withAnimation(Island.morph) { pageIndex = min(max(index, 0), pages.count - 1) }
    }

    func swapPrimary() {
        guard let second = secondary else { return }
        withAnimation(Island.pop) { promote(second) }
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEMMMd")
        return f
    }()
}

// MARK: - Timer activity

@MainActor @Observable
final class TimerActivity {
    private(set) var duration: TimeInterval = 0
    private(set) var endDate: Date?
    private(set) var pausedRemaining: TimeInterval?

    var isActive: Bool { endDate != nil || pausedRemaining != nil }
    var isRunning: Bool { endDate != nil }

    func remaining(at now: Date) -> TimeInterval {
        if let end = endDate { return max(0, end.timeIntervalSince(now)) }
        return pausedRemaining ?? 0
    }

    func fraction(at now: Date) -> Double {
        duration > 0 ? remaining(at: now) / duration : 0
    }

    func start(_ seconds: TimeInterval) {
        duration = seconds
        endDate = Date().addingTimeInterval(seconds)
        pausedRemaining = nil
    }

    func toggle() {
        if let end = endDate {
            pausedRemaining = max(0, end.timeIntervalSinceNow)
            endDate = nil
        } else if let left = pausedRemaining {
            endDate = Date().addingTimeInterval(left)
            pausedRemaining = nil
        }
    }

    func cancel() {
        endDate = nil
        pausedRemaining = nil
        duration = 0
    }

    /// True exactly once, when a running timer reaches zero (and clears it).
    func finishIfDue(at now: Date) -> Bool {
        guard let end = endDate, now >= end else { return false }
        cancel()
        return true
    }
}

func countdownString(_ t: TimeInterval) -> String {
    let s = max(0, Int(t.rounded(.up)))
    if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
    return String(format: "%d:%02d", s / 60, s % 60)
}

func timeString(_ t: TimeInterval) -> String {
    let s = max(0, Int(t.rounded(.down)))
    if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
    return String(format: "%d:%02d", s / 60, s % 60)
}
