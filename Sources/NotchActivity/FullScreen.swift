import AppKit
import OSLog

let islandLog = Logger(subsystem: "com.harrisonbraun.notchactivity", category: "Island")

// The island steps aside when something takes over the notched display.
//
// A menu-bar-style (LSUIElement) app's floating panels are shown over other apps' full-screen
// Spaces whether or not they ask to be, so the island can't rely on the window server to keep
// it out. It has to notice full screen itself and order its panel out. There are two kinds:
//
//  1. Native full screen (the green button; Safari, Chrome, QuickTime, Plex, most players).
//     The window moves into its own Space. `isFullScreenSpace` asks the window server what
//     kind of Space the notched display is showing.
//
//  2. "Borderless" full screen (Firefox video, many games, slideshows). The app stays in the
//     current Space and covers the display itself, hiding the menu bar or drawing above it.
//     `frontmostAppCovers` looks for that window.
//
// Everything here is per display: full screen on an external monitor leaves the island alone.

enum FullScreenDetector {
    /// Whether the Space currently showing on `displayID` is a full-screen (or Split View) Space.
    ///
    /// Primary source: the window server's list of managed Spaces. That call is private, so it
    /// is looked up at run time; if a macOS update removes it, this falls back to what public
    /// APIs can tell (see `frontmostAppLooksFullScreen`).
    @MainActor
    static func isFullScreenSpace(displayID: CGDirectDisplayID, menuBarHeight: CGFloat) -> Bool {
        guard displayID != 0 else { return false }
        if let type = currentSpaceType(displayID: displayID) { return type == fullScreenSpaceType }
        return frontmostAppLooksFullScreen(displayID: displayID, menuBarHeight: menuBarHeight)
    }

    /// True when the frontmost app has a window covering the whole display — including the
    /// strip where the menu bar lives — and that window is really taking over the screen:
    /// the app has hidden the menu bar, or the window sits above it.
    ///
    /// Only the frontmost, regular (Dock-visible) app counts. Background helpers keep
    /// invisible screen-sized overlays around (the Dock does, so do annotation and
    /// screenshot tools), and those must not hide the island.
    @MainActor
    static func frontmostAppCovers(displayID: CGDirectDisplayID) -> Bool {
        guard let (pid, display) = frontmostRegularApp(on: displayID) else { return false }
        let menuBarHidden = !NSApp.currentSystemPresentationOptions
            .isDisjoint(with: [.hideMenuBar, .autoHideMenuBar, .fullScreen])
        let menuBarLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        return windows(of: pid).contains { layer, bounds in
            let coversDisplay = bounds.minX <= display.minX + 1 && bounds.maxX >= display.maxX - 1
                && bounds.minY <= display.minY + 1 && bounds.maxY >= display.maxY - 1
            return coversDisplay && (menuBarHidden || layer > menuBarLevel)
        }
    }

    // MARK: Window server Spaces (private, resolved at run time)

    /// "Current Space" → "type" in CGSCopyManagedDisplaySpaces: 0 is a desktop, 4 is full screen.
    private static let fullScreenSpaceType = 4

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private static let spaceFunctions: (MainConnection, CopyManagedDisplaySpaces)? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let connection = dlsym(handle, "CGSMainConnectionID"),
              let copy = dlsym(handle, "CGSCopyManagedDisplaySpaces") else { return nil }
        return (unsafeBitCast(connection, to: MainConnection.self),
                unsafeBitCast(copy, to: CopyManagedDisplaySpaces.self))
    }()

    /// nil when the window server can't be asked or the display isn't in its answer.
    private static func currentSpaceType(displayID: CGDirectDisplayID) -> Int? {
        guard let (connection, copy) = spaceFunctions,
              let displays = copy(connection())?.takeRetainedValue() as? [[String: Any]] else { return nil }
        let uuid = CGDisplayCreateUUIDFromDisplayID(displayID).map {
            CFUUIDCreateString(nil, $0.takeRetainedValue()) as String
        }
        // With "Displays have separate Spaces" off there is a single entry, called "Main".
        let entry = displays.first { ($0["Display Identifier"] as? String) == uuid }
            ?? displays.first { ($0["Display Identifier"] as? String) == "Main" }
        return (entry?["Current Space"] as? [String: Any])?["type"] as? Int
    }

    // MARK: Fallback from public APIs

    /// The frontmost app reports itself full screen, and one of its windows on this display
    /// runs from the menu bar line to the bottom edge (full-screen and Split View windows do).
    /// Weaker than the window server's answer: it only knows about the frontmost app.
    @MainActor
    private static func frontmostAppLooksFullScreen(displayID: CGDirectDisplayID, menuBarHeight: CGFloat) -> Bool {
        guard NSApp.currentSystemPresentationOptions.contains(.fullScreen),
              let (pid, display) = frontmostRegularApp(on: displayID) else { return false }
        return windows(of: pid).contains { layer, bounds in
            layer == 0 && bounds.intersects(display)
                && bounds.minY <= display.minY + menuBarHeight + 2
                && bounds.maxY >= display.maxY - 1
                && bounds.width >= display.width * 0.3
        }
    }

    // MARK: Helpers

    private static func frontmostRegularApp(on displayID: CGDirectDisplayID) -> (pid_t, CGRect)? {
        guard displayID != 0,
              let front = NSWorkspace.shared.frontmostApplication,
              front.activationPolicy == .regular,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let display = CGDisplayBounds(displayID)
        return display.isEmpty ? nil : (front.processIdentifier, display)
    }

    /// On-screen windows of one app: layer and bounds. Needs no Screen Recording permission.
    private static func windows(of pid: pid_t) -> [(layer: Int, bounds: CGRect)] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { window in
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  let layer = window[kCGWindowLayer as String] as? Int, layer >= 0,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let dict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict) else { return nil }
            return (layer, bounds)
        }
    }
}
