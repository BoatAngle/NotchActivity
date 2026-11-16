import AppKit
import SwiftUI

// MARK: - Artwork

/// Cover art, or the source app's icon on a dark tile when there is none, or a gradient for
/// demo tracks. `size` and `radius` animate, so one instance can morph between layouts.
struct ArtView: View {
    let track: TrackInfo?
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        ZStack {
            if let image = track?.artwork {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else if let id = track?.appBundleID, let icon = AppIcons.icon(for: id) {
                Color(white: 0.14)
                Image(nsImage: icon)
                    .resizable()
                    .scaleEffect(0.78)
            } else {
                LinearGradient(colors: track?.colors ?? DemoTrack.catalog[0].colors,
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .scaleEffect(size / 56)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .animation(.easeInOut(duration: 0.35), value: track?.artwork)
    }
}

// MARK: - Progress

struct ProgressRing: View {
    let fraction: Double
    let tint: Color
    let size: CGFloat
    let lineWidth: CGFloat
    var symbol: String?

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.25), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.5), value: fraction)
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Indeterminate spinner. Core Animation rotates it in the render server, so it costs no CPU.
struct Spinner: NSViewRepresentable {
    let tint: Color
    let size: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        view.wantsLayer = true
        let arc = CAShapeLayer()
        arc.frame = view.bounds
        let lineWidth = max(2, size * 0.14)
        arc.path = CGPath(ellipseIn: view.bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2), transform: nil)
        arc.fillColor = nil
        arc.lineWidth = lineWidth
        arc.lineCap = .round
        arc.strokeEnd = 0.72
        arc.strokeColor = NSColor(tint).cgColor
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        spin.duration = 0.85
        spin.repeatCount = .infinity
        arc.add(spin, forKey: "spin")
        view.layer?.addSublayer(arc)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view.layer?.sublayers?.first as? CAShapeLayer)?.strokeColor = NSColor(tint).cgColor
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }
}

// MARK: - Small controls

struct PageDots: View {
    let count: Int
    let index: Int
    let select: (Int) -> Void

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(.white.opacity(i == index ? 0.9 : 0.3))
                    .frame(width: i == index ? 12 : 6, height: 6)
                    .contentShape(Rectangle().inset(by: -4))
                    .onTapGesture { select(i) }
            }
        }
        .animation(Island.morph, value: index)
        .accessibilityLabel("Page \(index + 1) of \(count)")
    }
}

struct PinButton: View {
    let pinned: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: pinned ? "pin.fill" : "pin")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(pinned ? 0.9 : 0.4))
                .rotationEffect(.degrees(45))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .help(pinned ? "Unpin" : "Keep expanded")
        .accessibilityLabel(pinned ? "Unpin" : "Keep expanded")
    }
}

struct SourceBadge: View {
    let track: TrackInfo
    let open: () -> Void

    var body: some View {
        if let id = track.appBundleID, let icon = AppIcons.icon(for: id) {
            Button(action: open) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 18, height: 18)
                    .frame(width: 40, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .help("Open \(track.appName)")
            .accessibilityLabel("Open \(track.appName)")
        } else {
            Image(systemName: "waveform")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
                .frame(width: 40, height: 34)
                .help("Demo tracks")
        }
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct GlyphButton: View {
    let symbol: String
    let size: CGFloat
    let label: String
    var filledCircle = false
    var bounces = true
    let action: () -> Void
    @State private var hovering = false
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: bounces ? taps : 0)
                .foregroundStyle(.white)
                .frame(width: 40, height: 34)
                .background(
                    Circle()
                        .fill(.white.opacity(filledCircle ? (hovering ? 0.24 : 0.14) : (hovering ? 0.12 : 0)))
                        .frame(width: filledCircle ? 28 : 34, height: filledCircle ? 28 : 34))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
    }
}

struct CircleButton: View {
    let symbol: String
    let diameter: CGFloat
    let foreground: Color
    let background: Color
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: diameter * 0.38, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(foreground)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(background).brightness(hovering ? 0.08 : 0))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

struct PillButton: View {
    let title: String
    let symbol: String?
    let background: Color
    let foreground: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .bold)) }
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(Capsule().fill(background).brightness(hovering ? -0.06 : 0))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
    }
}

/// A switch drawn by hand: the island's panel never becomes key, and system switches
/// render in their gray "inactive window" style there, which reads as off.
struct IslandSwitch: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                Capsule()
                    .fill(isOn ? Color.green : Color.white.opacity(0.22))
                    .frame(width: 30, height: 18)
                    .overlay(alignment: isOn ? .trailing : .leading) {
                        Circle().fill(.white).frame(width: 14, height: 14).padding(2)
                            .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    }
            }
            .contentShape(Rectangle())
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

struct QuickAction: View {
    let symbol: String
    let label: String
    var tint: AnyShapeStyle = AnyShapeStyle(Color.white)
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(.white.opacity(hovering ? 0.2 : 0.12)))
                    .scaleEffect(hovering ? 1.06 : 1)
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
    }
}

struct Chip: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.orange.opacity(hovering ? 0.3 : 0.18)))
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .accessibilityLabel("\(title) timer")
    }
}

// MARK: - Waveform (Core Animation: animates in the render server, ~0% CPU)

/// Five bars that dance while playing and settle into dots when paused.
struct Waveform: NSViewRepresentable {
    static let bars = 5
    static let barWidth: CGFloat = 2.5
    static let spacing: CGFloat = 2
    static let width: CGFloat = CGFloat(bars) * barWidth + CGFloat(bars - 1) * spacing
    static let height: CGFloat = 16

    var playing: Bool
    var colors: [Color]

    func makeNSView(context: Context) -> WaveformLayerView { WaveformLayerView() }

    func updateNSView(_ view: WaveformLayerView, context: Context) {
        let ns = colors.isEmpty ? [NSColor.white] : colors.map { NSColor($0) }
        view.update(playing: playing, colors: ns)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WaveformLayerView, context: Context) -> CGSize? {
        CGSize(width: Self.width, height: Self.height)
    }
}

final class WaveformLayerView: NSView {
    private var barLayers: [CAGradientLayer] = []
    private var playing = false
    private var laidOut = false

    /// Per-bar height keyframes (fraction of full height). Each loop starts where it ends.
    private static let patterns: [[CGFloat]] = [
        [0.35, 0.90, 0.50, 1.00, 0.30, 0.75, 0.45, 0.35],
        [0.60, 0.30, 1.00, 0.45, 0.85, 0.35, 0.70, 0.60],
        [1.00, 0.50, 0.75, 0.30, 0.95, 0.55, 0.40, 1.00],
        [0.45, 0.85, 0.35, 0.70, 0.50, 1.00, 0.30, 0.45],
        [0.70, 0.40, 0.90, 0.55, 0.30, 0.80, 0.50, 0.70],
    ]
    private static let durations: [CFTimeInterval] = [1.5, 1.3, 1.7, 1.4, 1.6]

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Waveform.width, height: Waveform.height))
        wantsLayer = true
        for _ in 0..<Waveform.bars {
            let l = CAGradientLayer()
            l.cornerRadius = Waveform.barWidth / 2
            l.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer?.addSublayer(l)
            barLayers.append(l)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        guard !laidOut, bounds.height > 0 else { return }
        laidOut = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, l) in barLayers.enumerated() {
            l.bounds = CGRect(x: 0, y: 0, width: Waveform.barWidth, height: Waveform.barWidth)
            l.position = CGPoint(x: CGFloat(i) * (Waveform.barWidth + Waveform.spacing) + Waveform.barWidth / 2,
                                 y: bounds.midY)
        }
        CATransaction.commit()
        applyState(animated: false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Layer animations are dropped when the view leaves a window; restore them on return.
        if window != nil, laidOut { applyState(animated: false) }
    }

    func update(playing: Bool, colors: [NSColor]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let cg = colors.map(\.cgColor)
        for l in barLayers { l.colors = cg.count > 1 ? cg : cg + cg }
        CATransaction.commit()
        guard playing != self.playing else { return }
        self.playing = playing
        if laidOut { applyState(animated: true) }
    }

    private func applyState(animated: Bool) {
        let full = Waveform.height
        let dot = Waveform.barWidth
        for (i, l) in barLayers.enumerated() {
            let current = l.presentation()?.bounds.height ?? l.bounds.height
            l.removeAnimation(forKey: "wave")
            if playing {
                let wave = CAKeyframeAnimation(keyPath: "bounds.size.height")
                wave.values = Self.patterns[i % Self.patterns.count].map { max(dot, full * $0) }
                wave.duration = Self.durations[i % Self.durations.count]
                wave.calculationMode = .cubic
                wave.repeatCount = .infinity
                l.add(wave, forKey: "wave")
            } else if animated {
                let settle = CABasicAnimation(keyPath: "bounds.size.height")
                settle.fromValue = current
                settle.toValue = dot
                settle.duration = 0.3
                settle.timingFunction = CAMediaTimingFunction(name: .easeOut)
                l.add(settle, forKey: "settle")
            }
        }
    }
}

// MARK: - Scrubber

struct Scrubber: View {
    let track: TrackInfo
    let now: Date
    let seek: (TimeInterval) -> Void
    @State private var dragFraction: Double?
    @State private var hovering = false

    var body: some View {
        if track.hasDuration {
            let position = track.position(at: now)
            let fraction = dragFraction ?? position / track.duration
            let shown = dragFraction.map { $0 * track.duration } ?? position
            HStack(spacing: 10) {
                Text(timeString(shown)).frame(width: 40, alignment: .leading)
                GeometryReader { geo in
                    let thick = hovering || dragFraction != nil
                    let h: CGFloat = thick ? 8 : 5
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.2))
                        Capsule().fill(.white).frame(width: max(h, geo.size.width * min(1, max(0, fraction))))
                    }
                    .frame(height: h)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in dragFraction = min(max(0, v.location.x / geo.size.width), 1) }
                        .onEnded { v in
                            let f = min(max(0, v.location.x / geo.size.width), 1)
                            seek(f * track.duration)
                            dragFraction = nil
                        })
                    .animation(.spring(response: 0.25, dampingFraction: 0.8), value: thick)
                }
                .frame(height: 16)
                .onHover { hovering = $0 }
                Text("-" + timeString(max(0, track.duration - shown))).frame(width: 46, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
        } else {
            // Live streams and sources that don't report a length.
            HStack(spacing: 10) {
                Text("LIVE")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.red))
                    .opacity(track.isPlaying ? 1 : 0.4)
                Capsule().fill(.white.opacity(0.2)).frame(height: 5)
            }
            .frame(height: 16)
        }
    }
}
