import Foundation
import SwiftUI
import SwiftTerm
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct TerminalHighlightRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var pattern: String
    var color: Int
    var enabled = true
    static let presets: [Self] = [
        .init(name: "URL 链接", pattern: #"https?://[^\s<>\"']+"#, color: 0),
        .init(name: "IPv4", pattern: #"\b(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\b"#, color: 1),
        .init(name: "IPv6", pattern: #"(?<![\w:])(?=[\da-fA-F:]*\d|[a-fA-F]+:)(?![\da-fA-F:]*:::)(?:[\da-fA-F]{0,4}:){2,7}[\da-fA-F]{0,4}(?![\w:])"#, color: 2),
        .init(name: "邮箱", pattern: #"\b[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}\b"#, color: 3),
        .init(name: "日期时间", pattern: #"\b\d{4}[-/]\d{2}[-/]\d{2}(?:[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?)?\b"#, color: 4),
        .init(name: "文件路径", pattern: #"(?:[A-Za-z]:\\|(?<![:/\w])/(?!/))[^\s<>\"']+"#, color: 5),
        .init(name: "数字", pattern: #"\b\d+\b"#, color: 6)
    ]
    static let colors: [SwiftUI.Color] = [.cyan, .green, .teal, .purple, .orange, .blue, .yellow, .pink, .red, .mint, .indigo, .brown]
    static let colorNames = ["青色", "绿色", "蓝绿", "紫色", "橙色", "蓝色", "黄色", "粉色", "红色", "薄荷", "靛蓝", "棕色"]
}

@MainActor
final class TerminalHighlightSettings: ObservableObject {
    static let shared = TerminalHighlightSettings()
    @Published var rules: [TerminalHighlightRule] { didSet { save() } }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        rules = defaults.data(forKey: "terminal.highlight.rules").flatMap { try? JSONDecoder().decode([TerminalHighlightRule].self, from: $0) } ?? TerminalHighlightRule.presets
        rules = Array(rules.prefix(32))
    }
    private func save() {
        if let data = try? JSONEncoder().encode(rules) { defaults.set(data, forKey: "terminal.highlight.rules") }
    }
}

struct CommandHistoryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    let serverID: UUID
    let command: String
    var date: Date
}

@MainActor
final class CommandHistoryStore: ObservableObject {
    static let shared = CommandHistoryStore()
    @Published private(set) var entries: [CommandHistoryEntry]
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "terminal.history.enabled") } }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: "terminal.history.enabled") as? Bool ?? true
        entries = defaults.data(forKey: "terminal.command.history").flatMap { try? JSONDecoder().decode([CommandHistoryEntry].self, from: $0) } ?? []
        entries = Array(entries.filter { Self.mayPersist($0.command) }.prefix(2000))
    }
    /// Defense in depth, not a guarantee that arbitrary command arguments contain no secrets.
    /// Raw keyboard data, output and password responses never enter this store.
    static func mayPersist(_ command: String) -> Bool {
        guard !command.isEmpty, command.count <= 4096, !command.hasPrefix(" "),
              !command.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        let lower = command.lowercased()
        let sensitive = ["password", "passwd", "passphrase", "secret", "token", "authorization", "private key", "sshpass", "api_key", "apikey", "credential", "mysql -p", "curl -u", "export ", "env "]
        return !sensitive.contains(where: lower.contains) && !lower.contains("://") && !lower.contains("=")
    }
    func record(_ command: String, serverID: UUID) {
        guard enabled, Self.mayPersist(command) else { return }
        entries.removeAll { $0.serverID == serverID && $0.command == command }
        entries.insert(.init(serverID: serverID, command: command, date: .now), at: 0)
        entries = Array(entries.prefix(2000)); save()
    }
    func clear() { entries.removeAll(); defaults.removeObject(forKey: "terminal.command.history") }
    private func save() { if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: "terminal.command.history") } }
}

struct CommandSuggestion: Identifiable, Equatable {
    var id: String { command }
    let command: String
    let source: String
}
enum TerminalCompletion {
    static let builtins = ["ls -lah", "pwd", "cd ", "cat ", "tail -f ", "tail -n 100 ", "grep -n ", "find . -name ", "less ", "df -h", "du -sh ", "free -h", "top", "ps aux", "ss -tulnp", "ip addr", "ping ", "curl -I ", "ssh ", "systemctl status ", "journalctl -fu ", "docker ps", "docker logs -f ", "docker compose ps", "git status", "git log --oneline", "uname -a", "uptime"]
    static func suggestions(prefix: String, history: [String], snippets: [String]) -> [CommandSuggestion] {
        guard !prefix.isEmpty else { return [] }
        var seen = Set<String>(), result: [CommandSuggestion] = []
        for (source, commands) in [("历史", history), ("片段", snippets), ("命令库", builtins)] {
            for command in commands where command.localizedCaseInsensitiveContains(prefix) && command != prefix {
                if seen.insert(command).inserted { result.append(.init(command: command, source: source)) }
                if result.count == 8 { return result }
            }
        }
        return result
    }
}

enum TerminalShellIntegration {
    // No rc-file writes or DEBUG trap replacement. Guard against repeated installation.
    static let bash = #"if [ -n "${BASH_VERSION-}" ] && [ -z "${SERVERDASH_INTEGRATED-}" ]; then export SERVERDASH_INTEGRATED=1; PS1=$'\[\e]133;A\a\]'"$PS1"$'\[\e]133;B\a\]'; PS0=$'\e]133;C\a'"${PS0-}"; fi"#
    static let zsh = #"if [ -n "${ZSH_VERSION-}" ] && [ -z "${SERVERDASH_INTEGRATED-}" ]; then export SERVERDASH_INTEGRATED=1; autoload -Uz add-zsh-hook; __serverdash_preexec() { printf '\033]133;C\007'; }; add-zsh-hook preexec __serverdash_preexec; PS1=$'%{\e]133;A\a%}'"$PS1"$'%{\e]133;B\a%}'; fi"#
}

/// Display-only helpers owned by a session, alongside its persistent native terminal.
@MainActor
final class TerminalTools: ObservableObject {
    @Published var searchVisible = false
    @Published var searchText = "" { didSet { cache.removeAll(); redraw() } }
    @Published var composerVisible = false
    @Published var command = ""
    @Published private(set) var promptCommand = ""
    @Published var searchFound: Bool?
    @Published var showingHistory = false
    @Published var showingRules = false
    weak var terminal: SwiftTerm.TerminalView?
    let serverID: UUID
    private let history: CommandHistoryStore
    private let highlightSettings: TerminalHighlightSettings
    private var rules: [TerminalHighlightRule] = []
    private var compiled: [(NSRegularExpression, CGColor)] = []
    private var cache: [String: [TerminalCellHighlight]] = [:]
    private var commandStart: Position?
    init(serverID: UUID, history: CommandHistoryStore? = nil, highlightSettings: TerminalHighlightSettings? = nil) {
        self.serverID = serverID
        self.history = history ?? .shared
        self.highlightSettings = highlightSettings ?? .shared
    }

    func attach(_ view: SwiftTerm.TerminalView) {
        terminal = view
        view.cellHighlights = { [weak self, weak view] line in
            guard let self, let view else { return [] }
            return self.highlights(line, terminal: view.getTerminal())
        }
        // Only an explicitly emitted shell command boundary can authorize automatic history.
        view.getTerminal().registerOscHandler(code: 133) { [weak self] data in
            self?.shellBoundary(String(decoding: data, as: UTF8.self))
        }
    }
    private func shellBoundary(_ marker: String) {
        guard let view = terminal, let position = view.commandCursorPosition else { commandStart = nil; return }
        let terminal = view.getTerminal()
        if marker == "B" { commandStart = position }
        else if marker == "C" {
            defer { commandStart = nil }
            guard let start = commandStart, position.row >= start.row, position.row - start.row <= 8 else { return }
            let text = terminal.getText(start: start, end: position)
            let command = text.trimmingCharacters(in: .newlines)
            history.record(command, serverID: serverID)
        } else if marker == "A" || marker.hasPrefix("D") { commandStart = nil }
        if commandStart == nil, !promptCommand.isEmpty { promptCommand = "" }
    }
    func resetCommandBoundary() { commandStart = nil; promptCommand = "" }
    /// Read echoed text only inside an OSC 133 prompt; never collect raw keystrokes.
    func refreshPrompt() {
        guard let view = terminal, let start = commandStart, let end = view.commandCursorPosition,
              end.row >= start.row, end.row - start.row < 4 else {
            if !promptCommand.isEmpty { promptCommand = "" }
            return
        }
        let text = view.getTerminal().getText(start: start, end: end)
        let safe = text.count <= 512 && !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        let updated = safe ? text : ""
        if promptCommand != updated { promptCommand = updated }
    }
    func completionSuffix(for suggestion: String) -> String? {
        guard commandStart != nil, !promptCommand.isEmpty, suggestion.hasPrefix(promptCommand),
              !suggestion.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return String(suggestion.dropFirst(promptCommand.count))
    }
    func search(backwards: Bool = false) {
        guard let terminal else { return }
        if searchText.isEmpty { terminal.clearSearch(); searchFound = nil; return }
        searchFound = backwards ? terminal.findPrevious(searchText) : terminal.findNext(searchText)
    }
    func redraw() {
        #if os(macOS)
        terminal?.needsDisplay = true
        #else
        terminal?.setNeedsDisplay()
        #endif
    }
    private func highlights(_ line: BufferLine, terminal: Terminal) -> [TerminalCellHighlight] {
        let current = highlightSettings.rules
        if current != rules {
            rules = current; cache.removeAll()
            compiled = current.prefix(32).filter(\.enabled).compactMap { rule -> (NSRegularExpression, CGColor)? in
                guard rule.pattern.count <= 256, let regex = try? NSRegularExpression(pattern: rule.pattern) else { return nil }
                let color = TerminalHighlightRule.colors[min(11, max(0, rule.color))]
                #if os(macOS)
                return (regex, NSColor(color).withAlphaComponent(0.25).cgColor)
                #else
                return (regex, UIColor(color).withAlphaComponent(0.25).cgColor)
                #endif
            }
        }
        var text = "", columns: [Int] = []
        // Map UTF-16 regex offsets back to terminal cells, including emoji/CJK/wide glyphs.
        for (column, data) in line.getData().prefix(2048).enumerated() {
            if line.getWidth(index: column) == 0 { continue }
            let char = terminal.getCharacter(for: data)
            let string = char == "\0" ? " " : String(char)
            text += string
            columns += Array(repeating: column, count: string.utf16.count)
        }
        columns.append(min(line.count, 2048))
        if let cached = cache[text] { return cached }
        var result: [TerminalCellHighlight] = [], occupied = IndexSet()
        let range = NSRange(location: 0, length: text.utf16.count)
        let deadline = Date.timeIntervalSinceReferenceDate + 0.004
        var patterns = compiled
        if !searchText.isEmpty, searchText.count <= 512,
           let regex = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: searchText), options: .caseInsensitive) {
            patterns.insert((regex, CGColor(red: 1, green: 0.8, blue: 0.1, alpha: 0.55)), at: 0)
        }
        for (regex, color) in patterns {
            if Date.timeIntervalSinceReferenceDate > deadline { break }
            regex.enumerateMatches(in: text, options: .reportProgress, range: range) { match, _, stop in
                if Date.timeIntervalSinceReferenceDate > deadline || result.count >= 128 { stop.pointee = true; return }
                guard let match, match.range.length > 0, NSMaxRange(match.range) < columns.count else { return }
                let start = columns[match.range.location]
                let end = columns[NSMaxRange(match.range)]
                guard start < end, !occupied.intersects(integersIn: start..<end) else { return }
                occupied.insert(integersIn: start..<end)
                result.append(.init(columns: start..<end, color: color))
            }
        }
        if cache.count >= 256 { cache.removeAll(keepingCapacity: true) }
        cache[text] = result
        return result
    }
}
