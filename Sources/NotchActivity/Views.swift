import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Root

struct IslandRoot: View {
    let model: IslandModel

    var body: some View {
        ZStack(alignment: .top) {
            IslandView(model: model)
            if model.showsBubble, let page = model.secondary {
                BubbleView(model: model, page: page)
                    .offset(x: model.bubbleOffset)
                    // Pinches off the island's edge, like the iPhone's second activity.
                    .transition(.asymmetric(
                        insertion: .offset(x: model.geometry.notchHeight)
                            .combined(with: .scale(scale: 0.3, anchor: .trailing))
                            .combined(with: .opacity),
                        removal: .scale(scale: 0.3, anchor: .trailing).combined(with: .opacity)))
            }
        }
        .frame(width: model.windowSize.width, height: model.windowSize.height, alignment: .top)
        .environment(\.colorScheme, .dark)
    }
}

struct IslandView: View {
    let model: IslandModel

    var body: some View {
        let size = model.bodySize
        let p = model.presentation
        let shape = NotchShape(shoulder: Island.shoulder, bottomRadius: model.bottomRadius)

        ZStack(alignment: .top) {
            content(p)
                .id(p)
                .transition(.blurReplace)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .overlay(alignment: .topLeading) { HeroLayer(model: model, width: size.width) }
        .padding(.horizontal, Island.shoulder)
        .background(Color.black)
        .clipShape(shape)
        .contentShape(shape)
        .shadow(color: .black.opacity(model.isLarge ? 0.5 : 0), radius: 22, y: 10)
        .onTapGesture {
            switch p {
            case .compact, .idle: model.expandNow()
            case .alert: model.actions?.dismissAlert()
            default: break
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: Binding(get: { model.dropHighlighted },
                                                          set: { model.dropHighlighted = $0 })) { providers in
            model.actions?.handleDrop(providers) ?? false
        }
    }

    /// Each presentation lays out at its own final size, so nothing reflows while the island morphs.
    @ViewBuilder
    private func content(_ p: Presentation) -> some View {
        let g = model.geometry
        switch p {
        case .hidden, .idle:
            Color.clear.frame(width: g.notchWidth, height: g.notchHeight)
        case .compact:
            CompactContent(model: model)
                .frame(width: g.notchWidth + 2 * model.compactEar, height: g.notchHeight)
        case .alert:
            if let alert = model.alert {
                AlertContent(model: model, alert: alert)
                    .frame(width: g.notchWidth + 2 * model.alertEar, height: g.notchHeight)
            }
        case .expanded:
            ExpandedContent(model: model)
                .frame(width: model.expandedWidth,
                       height: g.notchHeight + model.pageHeight(model.currentPage), alignment: .top)
        case .search:
            SearchContent(model: model)
                .frame(width: model.expandedWidth, height: g.notchHeight + model.search.contentHeight,
                       alignment: .top)
        case .drop:
            DropContent(model: model)
                .frame(width: model.expandedWidth, height: g.notchHeight + 100, alignment: .top)
        case .welcome:
            WelcomeContent(model: model)
                .frame(width: model.expandedWidth, height: g.notchHeight + IslandModel.welcomeHeight,
                       alignment: .top)
        }
    }
}

/// The artwork and waveform live here, above the per-presentation content, and move between
/// slots (`IslandModel.heroArt` / `heroWave`) as the island changes shape.
struct HeroLayer: View {
    let model: IslandModel
    let width: CGFloat

    var body: some View {
        let art = model.heroArt
        let wave = model.heroWave
        ZStack(alignment: .topLeading) {
            if let track = model.music.track {
                let large = art.size > 40
                ArtView(track: track, size: art.size, radius: art.radius)
                    .shadow(color: (track.colors.first ?? .clear).opacity(large && art.visible ? 0.45 : 0),
                            radius: 14, y: 5)
                    .scaleEffect(art.visible ? 1 : 0.4)
                    .opacity(art.visible ? 1 : 0)
                    .position(x: art.x, y: art.y)
                    .allowsHitTesting(large && art.visible)
                    .onTapGesture { model.music.openSourceApp() }
                    .help(track.isDemo ? "" : "Open \(track.appName)")

                Waveform(playing: track.isPlaying, colors: track.colors)
                    .frame(width: Waveform.width, height: Waveform.height)
                    .scaleEffect(wave.visible ? wave.size : 0.4)
                    .opacity(wave.visible ? 1 : 0)
                    .position(x: width - wave.x, y: wave.y)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: width, alignment: .topLeading)
    }
}

// MARK: - Ears: content beside the notch, never under it

/// Lays out a row level with the physical notch. The middle `notch` points are always
/// empty; leading/trailing content is confined to its ear minus `Island.clearance`.
struct Ears<Leading: View, Trailing: View>: View {
    let notch: CGFloat
    let ear: CGFloat
    let height: CGFloat
    var leadingAlignment: Alignment = .center
    var trailingAlignment: Alignment = .center
    var inset: CGFloat = 0
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        let w = max(0, ear - Island.clearance - inset)
        // Color.clear underneath gives each slot a real frame even when its content is
        // EmptyView; otherwise the row shrinks, re-centers, and slides under the notch.
        HStack(spacing: 0) {
            ZStack(alignment: leadingAlignment) { Color.clear; leading }
                .frame(width: w, height: height)
                .padding(.leading, inset)
                .padding(.trailing, Island.clearance)
            Color.clear.frame(width: notch, height: height)
            ZStack(alignment: trailingAlignment) { Color.clear; trailing }
                .frame(width: w, height: height)
                .padding(.leading, Island.clearance)
                .padding(.trailing, inset)
        }
        .frame(width: 2 * ear + notch, height: height)
    }
}

extension Text {
    func earTitle() -> some View {
        font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.5))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

// MARK: - Compact, bubble, alert

struct CompactContent: View {
    let model: IslandModel

    var body: some View {
        let g = model.geometry
        Ears(notch: g.notchWidth, ear: model.compactEar, height: g.notchHeight, inset: 4) {
            switch model.primary {
            case .timer:
                Image(systemName: "timer")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.orange)
            case .calendar:
                Image(systemName: "calendar")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(model.calendar.upcoming?.color ?? .red)
            case .custom(let id):
                if let a = model.custom(id) {
                    Image(systemName: a.icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(a.tint)
                        .symbolEffect(.bounce, value: a.startedAt)
                }
            default:
                EmptyView()     // music: the hero artwork sits here
            }
        } trailing: {
            switch model.primary {
            case .timer:
                Text(countdownString(model.timer.remaining(at: model.now)))
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(model.timer.isRunning ? Color.orange : Color.orange.opacity(0.55))
                    .contentTransition(.numericText(countsDown: true))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            case .calendar:
                if let e = model.calendar.upcoming {
                    Text(e.shortCountdown(at: model.now))
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                        .foregroundStyle(e.color)
                        .contentTransition(.numericText(countsDown: true))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            case .custom(let id):
                if let a = model.custom(id) {
                    if let progress = a.progress {
                        ProgressRing(fraction: progress, tint: a.tint, size: 18, lineWidth: 3)
                    } else if a.indeterminate {
                        Spinner(tint: a.tint, size: 16)
                    }
                }
            default:
                EmptyView()     // music: the hero waveform sits here
            }
        }
    }
}

/// The detached "minimal" bubble for the second live activity. Click it to swap.
struct BubbleView: View {
    let model: IslandModel
    let page: Page

    var body: some View {
        let h = model.geometry.notchHeight
        let d = h - 14
        let shape = NotchShape(shoulder: Island.shoulder, bottomRadius: h / 2)
        ZStack {
            switch page {
            case .music:
                ArtView(track: model.music.track, size: d, radius: d / 2)
            case .timer:
                ProgressRing(fraction: model.timer.fraction(at: model.now), tint: .orange, size: d,
                             lineWidth: 3, symbol: "timer")
            case .calendar:
                Image(systemName: "calendar")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(model.calendar.upcoming?.color ?? .red)
            case .custom(let id):
                if let a = model.custom(id) {
                    if let progress = a.progress {
                        ProgressRing(fraction: progress, tint: a.tint, size: d, lineWidth: 3)
                    } else {
                        Image(systemName: a.icon)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(a.tint)
                    }
                }
            case .home:
                EmptyView()
            }
        }
        .frame(width: h, height: h)
        .padding(.horizontal, Island.shoulder)
        .background(Color.black)
        .clipShape(shape)
        .contentShape(shape)
        .onTapGesture { model.swapPrimary() }
        .accessibilityLabel("Switch live activity")
    }
}

struct AlertContent: View {
    let model: IslandModel
    let alert: IslandAlert

    var body: some View {
        let g = model.geometry
        Ears(notch: g.notchWidth, ear: alert.ear,
             height: g.notchHeight, leadingAlignment: .leading, trailingAlignment: .trailing, inset: 16) {
            HStack(spacing: 8) {
                if alert.kind == .nowPlaying {
                    Color.clear.frame(width: IslandModel.artCompact, height: IslandModel.artCompact)   // hero artwork
                } else {
                    Image(systemName: alert.icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(alert.tint)
                        .symbolEffect(.bounce, value: alert.id)
                }
                Text(alert.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.85)
            }
        } trailing: {
            HStack(spacing: 5) {
                Text(alert.value)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.85)
                if let icon = alert.valueIcon {
                    Image(systemName: icon).font(.system(size: 15, weight: .medium))
                }
            }
            .foregroundStyle(alert.valueTint ?? alert.tint)
        }
    }
}

// MARK: - Expanded

struct ExpandedContent: View {
    let model: IslandModel

    var body: some View {
        let g = model.geometry
        let pages = model.pages
        VStack(spacing: 0) {
            Ears(notch: g.notchWidth, ear: model.expandedEar, height: g.notchHeight,
                 leadingAlignment: .leading, trailingAlignment: .trailing, inset: 18) {
                Text(model.title(for: model.currentPage)).earTitle()
                    .id(model.currentPage)
                    .transition(.opacity)
            } trailing: {
                HStack(spacing: 10) {
                    if pages.count > 1 {
                        PageDots(count: pages.count, index: min(model.pageIndex, pages.count - 1)) {
                            model.selectPage($0)
                        }
                    }
                    PinButton(pinned: model.pinned) {
                        withAnimation(Island.morph) { model.pinned.toggle() }
                    }
                }
            }
            Group {
                switch model.currentPage {
                case .music: MusicPage(model: model)
                case .timer: TimerPage(model: model)
                case .calendar: CalendarPage(model: model)
                case .custom(let id): CustomPage(model: model, id: id)
                case .home: HomePage(model: model)
                }
            }
            .id(model.currentPage)
            .transition(.blurReplace)
            .padding(.horizontal, Island.pagePadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

struct MusicPage: View {
    let model: IslandModel

    var body: some View {
        let music = model.music
        if let t = music.track {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Color.clear.frame(width: IslandModel.artExpanded, height: IslandModel.artExpanded)   // hero artwork
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(t.artist.isEmpty ? t.appName : t.artist)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .lineLimit(1)
                    .id(t.id)
                    .transition(.blurReplace)
                    Spacer(minLength: 8)
                    Color.clear.frame(width: Waveform.width * 1.15, height: Waveform.height)             // hero waveform
                }
                .padding(.top, 8)

                Scrubber(track: t, now: model.now) { music.seek(to: $0) }
                    .padding(.top, 12)

                ZStack {
                    HStack(spacing: 30) {
                        GlyphButton(symbol: "backward.fill", size: 18, label: "Previous track") { music.previous() }
                        GlyphButton(symbol: t.isPlaying ? "pause.fill" : "play.fill", size: 24,
                                    label: t.isPlaying ? "Pause" : "Play", bounces: false) { music.togglePlay() }
                        GlyphButton(symbol: "forward.fill", size: 18, label: "Next track") { music.next() }
                    }
                    HStack {
                        SourceBadge(track: t) { music.openSourceApp() }
                        Spacer()
                        GlyphButton(symbol: "stop.fill", size: 11, label: "Stop", filledCircle: true) { music.stop() }
                    }
                }
                .padding(.top, 6)
            }
            .animation(Island.settle, value: t.id)
        } else {
            Text("Nothing playing")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.top, 40)
        }
    }
}

struct TimerPage: View {
    let model: IslandModel

    var body: some View {
        let timer = model.timer
        HStack(spacing: 14) {
            ProgressRing(fraction: timer.fraction(at: model.now), tint: .orange, size: 50, lineWidth: 4.5,
                         symbol: "timer")
            VStack(alignment: .leading, spacing: 0) {
                Text(timer.endDate.map { "Ends " + $0.formatted(date: .omitted, time: .shortened) } ?? "Paused")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                Text(countdownString(timer.remaining(at: model.now)))
                    .font(.system(size: 32, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.orange)
                    .contentTransition(.numericText(countsDown: true))
            }
            Spacer()
            CircleButton(symbol: timer.isRunning ? "pause.fill" : "play.fill", diameter: 42,
                         foreground: .orange, background: .orange.opacity(0.22),
                         label: timer.isRunning ? "Pause timer" : "Resume timer") { timer.toggle() }
            CircleButton(symbol: "xmark", diameter: 42, foreground: .white, background: .white.opacity(0.14),
                         label: "Cancel timer") {
                withAnimation(Island.morph) { timer.cancel() }
            }
        }
        .padding(.top, 12)
    }
}

struct CalendarPage: View {
    let model: IslandModel

    var body: some View {
        if let e = model.calendar.upcoming {
            HStack(spacing: 12) {
                VStack(spacing: -1) {
                    Text(e.start.formatted(.dateTime.month(.abbreviated)).uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(e.color)
                    Text(e.start.formatted(.dateTime.day()))
                        .font(.system(size: 24, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                }
                .frame(width: 50, height: 50)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.1)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(e.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(e.detailLine)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                    Text(e.longCountdown(at: model.now))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(e.color)
                        .contentTransition(.numericText(countsDown: true))
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                if let url = e.joinURL {
                    PillButton(title: "Join", symbol: "video.fill", background: .green, foreground: .white) {
                        model.actions?.open(url)
                    }
                }
                CircleButton(symbol: "xmark", diameter: 30, foreground: .white, background: .white.opacity(0.14),
                             label: "Dismiss event") {
                    withAnimation(Island.morph) { model.calendar.dismissCurrent() }
                }
            }
            .padding(.top, 12)
        }
    }
}

struct CustomPage: View {
    let model: IslandModel
    let id: String

    var body: some View {
        if let a = model.custom(id) {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: a.icon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(a.tint)
                        .frame(width: 50, height: 50)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(a.tint.opacity(0.2)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                        if !a.subtitle.isEmpty {
                            Text(a.subtitle)
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .lineLimit(1)
                    Spacer(minLength: 8)
                    if let progress = a.progress {
                        Text("\(Int((progress * 100).rounded()))%")
                            .font(.system(size: 20, weight: .medium, design: .rounded).monospacedDigit())
                            .foregroundStyle(a.tint)
                            .contentTransition(.numericText())
                    } else if a.indeterminate {
                        Spinner(tint: a.tint, size: 20)
                    }
                    if a.url != nil {
                        CircleButton(symbol: "arrow.up.forward", diameter: 30, foreground: .white,
                                     background: .white.opacity(0.14), label: "Open") {
                            if let url = a.url { model.actions?.open(url) }
                        }
                    }
                    CircleButton(symbol: "xmark", diameter: 30, foreground: .white, background: .white.opacity(0.14),
                                 label: "Dismiss") {
                        model.actions?.endCustomActivity(a.id)
                    }
                }
                if let progress = a.progress {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.18))
                            Capsule().fill(a.tint)
                                .frame(width: max(5, geo.size.width * min(1, max(0, progress))))
                        }
                    }
                    .frame(height: 5)
                    .animation(Island.settle, value: progress)
                }
            }
            .padding(.top, 10)
        }
    }
}

struct HomePage: View {
    let model: IslandModel
    @State private var choosingTimer = false

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                if choosingTimer {
                    HStack(spacing: 8) {
                        ForEach([1, 3, 5, 10, 25], id: \.self) { minutes in
                            Chip(title: "\(minutes) min") {
                                model.actions?.startTimer(seconds: TimeInterval(minutes * 60))
                                choosingTimer = false
                            }
                        }
                        CircleButton(symbol: "xmark", diameter: 28, foreground: .white,
                                     background: .white.opacity(0.14), label: "Back") {
                            withAnimation(Island.morph) { choosingTimer = false }
                        }
                    }
                    .transition(.blurReplace)
                } else {
                    HStack(spacing: 0) {
                        QuickAction(symbol: "magnifyingglass", label: "Search") { model.actions?.beginSearch() }
                        QuickAction(symbol: "siri", label: "Siri",
                                    tint: AnyShapeStyle(LinearGradient(colors: [.pink, .purple, .blue, .cyan],
                                                                       startPoint: .topLeading, endPoint: .bottomTrailing))) {
                            model.actions?.openSiri()
                        }
                        QuickAction(symbol: "dot.radiowaves.left.and.right", label: "AirDrop",
                                    tint: AnyShapeStyle(Color(red: 0.35, green: 0.68, blue: 1))) {
                            model.actions?.pickFilesForAirDrop()
                        }
                        QuickAction(symbol: "timer", label: "Timer", tint: AnyShapeStyle(Color.orange)) {
                            withAnimation(Island.morph) { choosingTimer = true }
                        }
                    }
                    .transition(.blurReplace)
                }
            }
            .frame(height: 66)

            HStack(spacing: 6) {
                if model.power.state.hasBattery {
                    Image(systemName: model.power.symbol).foregroundStyle(model.power.tint)
                    Text("\(model.power.state.percent)%")
                }
                Spacer(minLength: 12)
                Image(systemName: model.audio.device.symbol)
                Text(model.audio.device.name).lineLimit(1)
                Button { model.actions?.openSettings() } label: {
                    Image(systemName: "gearshape.fill")
                        .padding(.leading, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .help("Settings")
                .accessibilityLabel("Settings")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.top, 10)
    }
}

// MARK: - Welcome

struct WelcomeContent: View {
    let model: IslandModel

    var body: some View {
        let g = model.geometry
        VStack(spacing: 0) {
            Ears(notch: g.notchWidth, ear: model.expandedEar, height: g.notchHeight,
                 leadingAlignment: .leading, trailingAlignment: .trailing, inset: 18) {
                Text("Welcome").earTitle()
            } trailing: {
                EmptyView()
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("Your notch just came alive")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.white)
                Text("Music, timers, and alerts now live up here.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 9) {
                    Tip(symbol: "cursorarrow.rays", text: "Rest the pointer on the notch to open it")
                    Tip(symbol: "hand.draw.fill", text: "Swipe with two fingers to switch activities")
                    Tip(symbol: "contextualmenu.and.cursorarrow", text: "Right-click for timers, search, and settings")
                }
                .padding(.top, 14)

                HStack(spacing: 10) {
                    IslandSwitch(title: "Open at Login", isOn: model.settings.launchAtLoginBinding)
                    Spacer()
                    PillButton(title: "Get Started", symbol: nil, background: .white, foreground: .black) {
                        model.actions?.finishWelcome()
                    }
                }
                .padding(.top, 16)
            }
            .padding(.horizontal, 22)
            .padding(.top, 6)
            Spacer(minLength: 0)
        }
    }

    private struct Tip: View {
        let symbol: String
        let text: String

        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.white.opacity(0.12)))
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }
}

// MARK: - Search

struct SearchContent: View {
    let model: IslandModel

    var body: some View {
        let g = model.geometry
        let search = model.search
        VStack(spacing: 0) {
            Ears(notch: g.notchWidth, ear: model.expandedEar, height: g.notchHeight,
                 leadingAlignment: .leading, trailingAlignment: .trailing, inset: 18) {
                Text("Search").earTitle()
            } trailing: {
                Text("esc")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.25)))
                    .onTapGesture { model.actions?.endSearch() }
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                SearchField(text: Binding(get: { search.query }, set: { search.setQuery($0) }),
                            onMove: { search.move($0) },
                            onSubmit: { model.actions?.activateSearchResult(nil) },
                            onCancel: { model.actions?.endSearch() })
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.1)))
            .padding(.horizontal, 16)
            .padding(.top, 8)

            if !search.results.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(search.results.enumerated()), id: \.element.id) { i, result in
                        ResultRow(model: model, result: result, selected: i == search.selection)
                            .onTapGesture { model.actions?.activateSearchResult(i) }
                            .onHover { if $0 { search.selection = i } }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
    }
}

struct ResultRow: View {
    let model: IslandModel
    let result: SearchResult
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            switch result.kind {
            case .app(let url):
                Image(nsImage: model.search.icon(for: url)).resizable().frame(width: 24, height: 24)
            case .calculation:
                Image(systemName: "equal.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.orange)
                    .frame(width: 24, height: 24)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(result.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(result.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .lineLimit(1)
            Spacer()
            if selected {
                Image(systemName: "return")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: SearchModel.rowHeight)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.white.opacity(selected ? 0.14 : 0)))
        .contentShape(Rectangle())
    }
}

/// AppKit text field so arrow keys / return / escape can drive the result list.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var onMove: (Int) -> Void
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> FocusingTextField {
        let f = FocusingTextField()
        f.isBordered = false
        f.isBezeled = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = .systemFont(ofSize: 15)
        f.textColor = .white
        f.placeholderAttributedString = NSAttributedString(
            string: "Search apps or type math",
            attributes: [.foregroundColor: NSColor.white.withAlphaComponent(0.35), .font: NSFont.systemFont(ofSize: 15)])
        f.cell?.wraps = false
        f.cell?.isScrollable = true
        f.delegate = context.coordinator
        return f
    }

    func updateNSView(_ f: FocusingTextField, context: Context) {
        context.coordinator.parent = self
        if f.stringValue != text { f.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchField
        init(_ parent: SearchField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            if let f = note.object as? NSTextField { parent.text = f.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel()
            default: return false
            }
            return true
        }
    }
}

final class FocusingTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            // Re-layouts (results appearing) can move the field between hosting views; only
            // grab focus if we don't already have it, or select-all would eat the query.
            guard let self, let window = self.window, self.currentEditor() == nil else { return }
            window.makeFirstResponder(self)
            guard let editor = self.currentEditor() as? NSTextView else { return }
            editor.insertionPointColor = .white
            editor.selectedRange = NSRange(location: (self.stringValue as NSString).length, length: 0)
        }
    }
}

// MARK: - AirDrop drop target

struct DropContent: View {
    let model: IslandModel

    var body: some View {
        let g = model.geometry
        VStack(spacing: 0) {
            Ears(notch: g.notchWidth, ear: model.expandedEar, height: g.notchHeight,
                 leadingAlignment: .leading, trailingAlignment: .trailing, inset: 18) {
                Text("AirDrop").earTitle()
            } trailing: {
                EmptyView()
            }
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [Color(red: 0.25, green: 0.65, blue: 1),
                                                      Color(red: 0.1, green: 0.38, blue: 0.95)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 54, height: 54)
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .scaleEffect(model.dropHighlighted ? 1.12 : 1)
                .animation(Island.pop, value: model.dropHighlighted)
                Text(model.dropHighlighted ? "Release to AirDrop" : "Drop here to AirDrop")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.top, 6)
            Spacer(minLength: 0)
        }
    }
}
