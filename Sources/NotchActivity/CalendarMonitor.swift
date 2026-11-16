import AppKit
import EventKit
import SwiftUI

struct UpcomingEvent: Equatable, Identifiable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var location = ""
    var joinURL: URL?
    var color: Color

    /// "12m", "1h 5m", or "Now" — for the compact ear.
    func shortCountdown(at now: Date) -> String {
        let seconds = start.timeIntervalSince(now)
        guard seconds > 0 else { return "Now" }
        let minutes = Int((seconds / 60).rounded(.up))
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    func longCountdown(at now: Date) -> String {
        let seconds = start.timeIntervalSince(now)
        guard seconds > 0 else { return "Happening now" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes >= 60 { return "Starts in \(minutes / 60) hr \(minutes % 60) min" }
        return "Starts in \(minutes) min"
    }

    var detailLine: String {
        let time = start.formatted(date: .omitted, time: .shortened) + " – " + end.formatted(date: .omitted, time: .shortened)
        return location.isEmpty ? time : "\(time) · \(location)"
    }
}

/// Turns the next calendar event into a live activity shortly before it starts.
/// Off until the user enables it (Settings › Calendar), because it needs calendar access.
@MainActor @Observable
final class CalendarMonitor {
    private(set) var upcoming: UpcomingEvent?
    private(set) var authorized = false
    private(set) var denied = false

    static let leadTime: TimeInterval = 15 * 60     // appear this long before the start
    static let graceTime: TimeInterval = 10 * 60    // linger this long after it

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var enabled = false
    @ObservationIgnored private var candidates: [UpcomingEvent] = []
    @ObservationIgnored private var dismissed: Set<String> = []
    @ObservationIgnored private var preview: UpcomingEvent?
    @ObservationIgnored private var lastFetch = Date.distantPast
    @ObservationIgnored private var observer: NSObjectProtocol?

    /// `prompt` shows the system permission dialog if access hasn't been decided yet.
    func setEnabled(_ on: Bool, prompt: Bool, completion: ((Bool) -> Void)? = nil) {
        enabled = on
        guard on else {
            candidates = []
            refresh(now: Date())
            completion?(false)
            return
        }
        updateAuthorization()
        if authorized {
            startObserving()
            fetch()
            completion?(true)
        } else if prompt, !denied {
            store.requestFullAccessToEvents { [weak self] granted, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.updateAuthorization()
                        if granted { self.startObserving(); self.fetch() }
                        completion?(granted)
                    }
                }
            }
        } else {
            completion?(false)
        }
    }

    private func updateAuthorization() {
        let status = EKEventStore.authorizationStatus(for: .event)
        authorized = status == .fullAccess
        denied = status == .denied || status == .restricted
    }

    private func startObserving() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fetch() }
        }
    }

    private func fetch() {
        guard enabled, authorized else { return }
        let now = Date()
        lastFetch = now
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-Self.graceTime),
                                                 end: now.addingTimeInterval(12 * 3600), calendars: nil)
        candidates = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                UpcomingEvent(id: "\(event.eventIdentifier ?? event.title ?? "")@\(event.startDate.timeIntervalSince1970)",
                              title: event.title ?? "Event",
                              start: event.startDate, end: event.endDate,
                              location: Self.shortLocation(event.location),
                              joinURL: Self.joinURL(for: event),
                              color: Color(cgColor: event.calendar.cgColor))
            }
        refresh(now: now)
    }

    /// Called on every clock tick; refetches from the store once a minute.
    func refresh(now: Date) {
        if enabled, authorized, now.timeIntervalSince(lastFetch) > 60 { fetch(); return }
        var next = preview
        if next == nil, enabled {
            next = candidates.first { event in
                !dismissed.contains(event.id)
                    && now >= event.start.addingTimeInterval(-Self.leadTime)
                    && now <= min(event.end, event.start.addingTimeInterval(Self.graceTime))
            }
        }
        if next != upcoming {
            withAnimation(Island.pop) { upcoming = next }
        }
    }

    func dismissCurrent() {
        if preview != nil {
            preview = nil
        } else if let event = upcoming {
            dismissed.insert(event.id)
        }
        refresh(now: Date())
    }

    /// A sample event, for trying the activity without calendar access. Calling it again removes it.
    func showPreview() {
        if preview != nil { dismissCurrent(); return }
        let start = Date().addingTimeInterval(10 * 60)
        preview = UpcomingEvent(id: "preview", title: "Design Review", start: start,
                                end: start.addingTimeInterval(30 * 60), location: "FaceTime",
                                joinURL: URL(string: "https://facetime.apple.com"), color: .red)
        refresh(now: Date())
    }

    // MARK: Helpers

    private static func shortLocation(_ location: String?) -> String {
        guard let first = location?.split(separator: "\n").first else { return "" }
        let s = String(first).trimmingCharacters(in: .whitespaces)
        return s.hasPrefix("http") ? "" : s
    }

    private static let meetingHosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com",
                                       "webex.com", "facetime.apple.com", "whereby.com", "meet.jit.si",
                                       "gotomeeting.com", "chime.aws", "around.co"]

    private static func joinURL(for event: EKEvent) -> URL? {
        var urls: [URL] = []
        if let u = event.url { urls.append(u) }
        let text = [event.location, event.notes].compactMap { $0 }.joined(separator: "\n")
        if !text.isEmpty, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(text.startIndex..., in: text)
            urls += detector.matches(in: text, range: range).compactMap(\.url)
        }
        return urls.first { url in
            guard let host = url.host?.lowercased(), url.scheme == "https" else { return false }
            return meetingHosts.contains { host == $0 || host.hasSuffix("." + $0) }
        }
    }
}
