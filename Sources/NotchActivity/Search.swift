import AppKit
import SwiftUI

struct SearchResult: Identifiable, Equatable {
    enum Kind: Equatable {
        case app(URL)
        case calculation(String)
    }
    let id: String
    let title: String
    let subtitle: String
    let kind: Kind
}

/// Spotlight-style search living in the island: launch apps by name, or do quick math.
@MainActor @Observable
final class SearchModel {
    private(set) var query = ""
    private(set) var results: [SearchResult] = []
    var selection = 0

    @ObservationIgnored private var apps: [(name: String, url: URL)] = []
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var icons: [URL: NSImage] = [:]

    static let maxResults = 5
    static let rowHeight: CGFloat = 36

    var contentHeight: CGFloat {
        let rows = CGFloat(results.count)
        return 8 + 38 + (results.isEmpty ? 0 : 8 + rows * Self.rowHeight) + 14
    }

    func prepare() {
        guard apps.isEmpty, !loading else { return }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let found = Self.scanApplications()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.apps = found
                    self.loading = false
                    self.recompute()
                }
            }
        }
    }

    func reset() {
        query = ""
        results = []
        selection = 0
    }

    func setQuery(_ q: String) {
        query = q
        recompute()
    }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = (selection + delta + results.count) % results.count
    }

    func icon(for url: URL) -> NSImage {
        if let i = icons[url] { return i }
        let i = NSWorkspace.shared.icon(forFile: url.path)
        icons[url] = i
        return i
    }

    /// Runs the selected result. Returns a short confirmation for the island, if any.
    func activate(_ index: Int? = nil) -> String? {
        let i = index ?? selection
        guard results.indices.contains(i) else { return nil }
        switch results[i].kind {
        case .app(let url):
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            return nil
        case .calculation(let value):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            return value
        }
    }

    private func recompute() {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        selection = 0
        guard !q.isEmpty else { results = []; return }

        var out: [SearchResult] = []
        if let value = Calculator.evaluate(q) {
            out.append(SearchResult(id: "calc", title: "= " + value, subtitle: "Copy result", kind: .calculation(value)))
        }
        let ranked = apps.compactMap { app -> (Int, String, URL)? in
            guard let s = Self.score(app.name.lowercased(), q) else { return nil }
            return (s, app.name, app.url)
        }
        .sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
        for (_, name, url) in ranked.prefix(Self.maxResults - out.count) {
            out.append(SearchResult(id: url.path, title: name, subtitle: "Application", kind: .app(url)))
        }
        results = out
    }

    nonisolated static func score(_ name: String, _ q: String) -> Int? {
        if name == q { return 1000 }
        if name.hasPrefix(q) { return 800 - name.count }
        let words = name.split(whereSeparator: { " -._".contains($0) })
        if words.contains(where: { $0.hasPrefix(q) }) { return 600 - name.count }
        if q.count >= 2, String(words.compactMap(\.first)).hasPrefix(q) { return 500 }
        if name.contains(q) { return 300 - name.count }
        return nil
    }

    nonisolated static func scanApplications() -> [(name: String, url: URL)] {
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications",
                    "/System/Applications/Utilities", "/System/Library/CoreServices/Applications",
                    "/System/Library/CoreServices"]
        var seen = Set<String>()
        var out: [(name: String, url: URL)] = []
        for dir in dirs {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where item.hasSuffix(".app") {
                if dir == "/System/Library/CoreServices", item != "Finder.app" { continue }
                let name = String(item.dropLast(4))
                guard seen.insert(name.lowercased()).inserted else { continue }
                out.append((name, URL(fileURLWithPath: dir).appendingPathComponent(item)))
            }
        }
        return out
    }
}

/// Tiny arithmetic evaluator (+ - * / % ^, parentheses). Deliberately not NSExpression,
/// which raises Objective-C exceptions (= crashes) on malformed input.
enum Calculator {
    static func evaluate(_ input: String) -> String? {
        let cleaned = input.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: ",", with: "")
        guard cleaned.contains(where: \.isNumber),
              cleaned.dropFirst().contains(where: { "+-*/%^".contains($0) }) else { return nil }
        var parser = Parser(chars: Array(cleaned))
        guard let v = parser.expression(), parser.index == parser.chars.count, v.isFinite else { return nil }
        if v == v.rounded(), abs(v) < 1e15 { return String(format: "%.0f", v) }
        let f = NumberFormatter()
        f.maximumSignificantDigits = 10
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        return f.string(from: NSNumber(value: v))
    }

    struct Parser {
        let chars: [Character]
        var index = 0

        private var peek: Character? { index < chars.count ? chars[index] : nil }

        mutating func expression() -> Double? {
            guard var value = term() else { return nil }
            while let op = peek, op == "+" || op == "-" {
                index += 1
                guard let rhs = term() else { return nil }
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }

        mutating func term() -> Double? {
            guard var value = power() else { return nil }
            while let op = peek, op == "*" || op == "/" || op == "%" {
                index += 1
                guard let rhs = power() else { return nil }
                switch op {
                case "*": value *= rhs
                case "/": value /= rhs
                default: value = value.truncatingRemainder(dividingBy: rhs)
                }
            }
            return value
        }

        mutating func power() -> Double? {
            guard let base = factor() else { return nil }
            if peek == "^" {
                index += 1
                guard let exp = power() else { return nil }
                return pow(base, exp)
            }
            return base
        }

        mutating func factor() -> Double? {
            if peek == "-" { index += 1; return factor().map { -$0 } }
            if peek == "(" {
                index += 1
                guard let v = expression(), peek == ")" else { return nil }
                index += 1
                return v
            }
            let start = index
            while let c = peek, c.isNumber || c == "." { index += 1 }
            guard index > start else { return nil }
            return Double(String(chars[start..<index]))
        }
    }
}
