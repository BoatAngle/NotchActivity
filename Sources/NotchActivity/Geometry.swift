import AppKit
import SwiftUI

/// Where the physical notch is, in global AppKit coordinates (origin bottom-left).
struct NotchGeometry: Equatable {
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var midX: CGFloat
    var top: CGFloat
    var displayID: CGDirectDisplayID = 0

    var notchLeft: CGFloat { midX - notchWidth / 2 }
    var notchRight: CGFloat { midX + notchWidth / 2 }

    static func find() -> NotchGeometry? {
        for screen in NSScreen.screens {
            let height = screen.safeAreaInsets.top
            guard height > 0,
                  let left = screen.auxiliaryTopLeftArea,
                  let right = screen.auxiliaryTopRightArea else { continue }
            let width = screen.frame.width - left.width - right.width
            guard width > 0 else { continue }
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return NotchGeometry(notchWidth: width, notchHeight: height,
                                 midX: screen.frame.minX + left.width + width / 2,
                                 top: screen.frame.maxY,
                                 displayID: number?.uint32Value ?? 0)
        }
        return nil
    }
}

/// Layout constants shared by the views (drawing) and the controller (hover zones),
/// so what is drawn and what reacts to the mouse can't drift apart.
enum Island {
    static let shoulder: CGFloat = 8          // concave flare where the island meets the menu bar
    static let clearance: CGFloat = 10        // content never comes closer than this to the notch edge
    /// Negative: the island's and bubble's shoulders overlap at the top edge, so the bubble
    /// looks pinched off the island (visible gap at the bottom is 2 × shoulder + this).
    static let bubbleGap: CGFloat = -6
    static let shadowPad: CGFloat = 34
    /// macOS keeps roughly this much clear to the right of the notch before the first status
    /// icon (measured on macOS 27: an icon closer than ~22-32pt goes into the « overflow).
    static let menuBarNotchMargin: CGFloat = 22

    static let compactEar: CGFloat = 42       // icon on one side, glyph on the other
    static let compactTextEar: CGFloat = 58   // room for a short countdown ("12:45", "12m")
    static let alertEar: CGFloat = 138
    static let peekEar: CGFloat = 176         // track previews carry a title and an artist
    static let expandedEar: CGFloat = 112
    static let expandedMinWidth: CGFloat = 448
    static let pagePadding: CGFloat = 20
    static let maxContentHeight: CGFloat = 280

    /// The island's signature morph: quick, with a little overshoot.
    static let morph = Animation.spring(response: 0.42, dampingFraction: 0.76)
    /// Bouncier, for things arriving (alerts, a new activity, the bubble splitting off).
    static let pop = Animation.spring(response: 0.5, dampingFraction: 0.62)
    /// Calm, for settling back.
    static let settle = Animation.spring(response: 0.5, dampingFraction: 0.86)
}

/// Black island hanging from the top edge: concave shoulders at the top where it meets
/// the menu bar, rounded corners at the bottom.
struct NotchShape: Shape {
    var shoulder: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulder, bottomRadius) }
        set { shoulder = newValue.first; bottomRadius = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let s = shoulder
        let b = max(0, min(bottomRadius, (r.width - 2 * s) / 2, r.height - s))
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addArc(tangent1End: CGPoint(x: r.minX + s, y: r.minY),
                 tangent2End: CGPoint(x: r.minX + s, y: r.minY + s), radius: s)
        p.addLine(to: CGPoint(x: r.minX + s, y: r.maxY - b))
        p.addArc(tangent1End: CGPoint(x: r.minX + s, y: r.maxY),
                 tangent2End: CGPoint(x: r.minX + s + b, y: r.maxY), radius: b)
        p.addLine(to: CGPoint(x: r.maxX - s - b, y: r.maxY))
        p.addArc(tangent1End: CGPoint(x: r.maxX - s, y: r.maxY),
                 tangent2End: CGPoint(x: r.maxX - s, y: r.maxY - b), radius: b)
        p.addLine(to: CGPoint(x: r.maxX - s, y: r.minY + s))
        p.addArc(tangent1End: CGPoint(x: r.maxX - s, y: r.minY),
                 tangent2End: CGPoint(x: r.maxX, y: r.minY), radius: s)
        p.closeSubpath()
        return p
    }
}

extension Color {
    /// "orange", "blue"… or "#RRGGBB". Used by the URL scheme / CLI.
    init?(islandName raw: String) {
        let name = raw.lowercased().trimmingCharacters(in: .whitespaces)
        let named: [String: Color] = [
            "red": .red, "orange": .orange, "yellow": .yellow, "green": .green, "mint": .mint,
            "teal": .teal, "cyan": .cyan, "blue": .blue, "indigo": .indigo, "purple": .purple,
            "pink": .pink, "white": .white, "gray": .gray, "grey": .gray, "brown": .brown,
        ]
        if let c = named[name] { self = c; return }
        var hex = name
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        self = Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255)
    }
}
