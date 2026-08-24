import AppKit
import Foundation
import SwiftUI

enum TerminalCursorShape: String, CaseIterable, Codable, Identifiable {
    case block
    case underline
    case bar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .block: "Block"
        case .underline: "Underline"
        case .bar: "Bar"
        }
    }
}

enum TerminalInactiveCursorStyle: String, CaseIterable, Codable, Identifiable {
    case outline
    case block
    case bar
    case underline
    case hidden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .outline: "Outline"
        case .block: "Block"
        case .bar: "Bar"
        case .underline: "Underline"
        case .hidden: "Hidden"
        }
    }
}

enum TerminalScrollbarMode: String, CaseIterable, Codable, Identifiable {
    case automatic
    case visible
    case hidden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .visible: "Visible"
        case .hidden: "Hidden"
        }
    }
}

struct TerminalAppearanceProfile: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var lightThemeID: String
    var darkThemeID: String
    var fontPostScriptName: String
    var fontSize: Double
    var lineHeight: Double
    var letterSpacing: Double
    var activeCursorStyle: TerminalCursorShape
    var inactiveCursorStyle: TerminalInactiveCursorStyle
    var cursorBlinkEnabled: Bool
    var scrollbarMode: TerminalScrollbarMode
    var terminalBellEnabled: Bool

    static let `default` = TerminalAppearanceProfile(
        schemaVersion: currentSchemaVersion,
        lightThemeID: "serverdash-light",
        darkThemeID: "serverdash-dark",
        fontPostScriptName: "Menlo-Regular",
        fontSize: 13,
        lineHeight: 1,
        letterSpacing: 0,
        activeCursorStyle: .block,
        inactiveCursorStyle: .outline,
        cursorBlinkEnabled: true,
        scrollbarMode: .automatic,
        terminalBellEnabled: true
    )

    func validated(
        themes: [TerminalColorTheme] = TerminalThemeCatalog.shared.themes
    ) -> TerminalAppearanceProfile {
        var copy = self
        copy.schemaVersion = Self.currentSchemaVersion
        let themeIDs = Set(themes.map(\.id))
        if !themeIDs.contains(copy.lightThemeID) {
            copy.lightThemeID = Self.default.lightThemeID
        }
        if !themeIDs.contains(copy.darkThemeID) {
            copy.darkThemeID = Self.default.darkThemeID
        }
        copy.fontSize = min(48, max(8, copy.fontSize))
        copy.lineHeight = min(2, max(1, copy.lineHeight))
        copy.letterSpacing = min(3, max(-1, copy.letterSpacing))
        copy.fontPostScriptName = TerminalFontCatalog.resolvedPostScriptName(
            copy.fontPostScriptName
        )
        return copy
    }
}

struct TerminalColor: Codable, Hashable {
    let hex: String

    init(_ hex: String) {
        self.hex = hex
    }

    var nsColor: NSColor {
        let raw = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard raw.count == 6 || raw.count == 8,
              let value = UInt64(raw, radix: 16) else {
            return .textColor
        }
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
        if raw.count == 8 {
            red = CGFloat((value >> 24) & 0xff) / 255
            green = CGFloat((value >> 16) & 0xff) / 255
            blue = CGFloat((value >> 8) & 0xff) / 255
            alpha = CGFloat(value & 0xff) / 255
        } else {
            red = CGFloat((value >> 16) & 0xff) / 255
            green = CGFloat((value >> 8) & 0xff) / 255
            blue = CGFloat(value & 0xff) / 255
            alpha = 1
        }
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    var color: Color {
        Color(nsColor: nsColor)
    }
}

struct TerminalColorTheme: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let isDark: Bool
    let foreground: TerminalColor
    let background: TerminalColor
    let cursor: TerminalColor
    let selectionBackground: TerminalColor
    let selectionForeground: TerminalColor
    let bold: TerminalColor
    let link: TerminalColor
    let ansiColors: [TerminalColor]

    var contrastRatio: Double {
        let foregroundLuminance = foreground.nsColor.relativeLuminance
        let backgroundLuminance = background.nsColor.relativeLuminance
        return (max(foregroundLuminance, backgroundLuminance) + 0.05)
            / (min(foregroundLuminance, backgroundLuminance) + 0.05)
    }
}

private struct TerminalThemeSeed: Codable {
    let id: String
    let name: String
    let isDark: Bool
    let foreground: String
    let background: String
    let accent: String
    let selection: String
    let palette: String
}

final class TerminalThemeCatalog {
    static let shared = TerminalThemeCatalog()

    let themes: [TerminalColorTheme]

    init(bundle: Bundle = .main) {
        themes = Self.loadSeeds(bundle: bundle)
            .map(Self.expand)
            .filter { $0.ansiColors.count == 16 }
    }

    func theme(id: String, dark: Bool) -> TerminalColorTheme {
        if let theme = themes.first(where: { $0.id == id }) {
            return theme
        }
        let fallbackID = dark ? "serverdash-dark" : "serverdash-light"
        return themes.first(where: { $0.id == fallbackID })
            ?? Self.expand(Self.fallbackSeeds.first { $0.id == fallbackID }!)
    }

    func filtered(_ query: String, dark: Bool? = nil) -> [TerminalColorTheme] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return themes.filter { theme in
            (dark == nil || theme.isDark == dark) &&
            (trimmed.isEmpty || theme.name.localizedCaseInsensitiveContains(trimmed))
        }
    }

    private static func loadSeeds(bundle: Bundle) -> [TerminalThemeSeed] {
        let candidates = [
            bundle.url(
                forResource: "themes",
                withExtension: "json",
                subdirectory: "TerminalThemes"
            ),
            bundle.url(forResource: "themes", withExtension: "json")
        ]
        for url in candidates.compactMap({ $0 }) {
            if let data = try? Data(contentsOf: url),
               let seeds = try? JSONDecoder().decode([TerminalThemeSeed].self, from: data),
               seeds.count == 20 {
                return seeds
            }
        }
        return fallbackSeeds
    }

    private static func expand(_ seed: TerminalThemeSeed) -> TerminalColorTheme {
        let palette = palettes[seed.palette] ?? palettes["classic"]!
        return TerminalColorTheme(
            id: seed.id,
            name: seed.name,
            isDark: seed.isDark,
            foreground: TerminalColor(seed.foreground),
            background: TerminalColor(seed.background),
            cursor: TerminalColor(seed.accent),
            selectionBackground: TerminalColor(seed.selection),
            selectionForeground: TerminalColor(seed.foreground),
            bold: TerminalColor(seed.foreground),
            link: TerminalColor(seed.accent),
            ansiColors: palette.map(TerminalColor.init)
        )
    }

    private static let palettes: [String: [String]] = [
        "classic": [
            "#1f2329", "#e06c75", "#98c379", "#e5c07b",
            "#61afef", "#c678dd", "#56b6c2", "#abb2bf",
            "#5c6370", "#ff7b86", "#b3e58f", "#ffd68a",
            "#80bfff", "#df91f2", "#75d4df", "#f2f4f8"
        ],
        "soft": [
            "#3b4252", "#bf616a", "#a3be8c", "#ebcb8b",
            "#81a1c1", "#b48ead", "#88c0d0", "#d8dee9",
            "#4c566a", "#d08770", "#b8d7a3", "#f0d399",
            "#8fbcbb", "#c7a3c3", "#9ad4df", "#eceff4"
        ],
        "solar": [
            "#073642", "#dc322f", "#859900", "#b58900",
            "#268bd2", "#d33682", "#2aa198", "#eee8d5",
            "#586e75", "#cb4b16", "#93a1a1", "#657b83",
            "#839496", "#6c71c4", "#94d4cc", "#fdf6e3"
        ],
        "vivid": [
            "#17181c", "#ff5f57", "#5af78e", "#f3f99d",
            "#57c7ff", "#ff6ac1", "#9aedfe", "#f1f1f0",
            "#686868", "#ff9f9a", "#9effb0", "#ffffb5",
            "#8be9fd", "#ff92d0", "#c5f5ff", "#ffffff"
        ]
    ]

    private static let fallbackSeeds: [TerminalThemeSeed] = [
        .init(id: "serverdash-light", name: "ServerDash Light", isDark: false, foreground: "#1f2329", background: "#f7f7f9", accent: "#2478d4", selection: "#cfe4ff", palette: "classic"),
        .init(id: "paper", name: "Paper", isDark: false, foreground: "#2f3337", background: "#ffffff", accent: "#2468b4", selection: "#d8e9fb", palette: "soft"),
        .init(id: "ivory", name: "Ivory", isDark: false, foreground: "#34312d", background: "#fffdf5", accent: "#9a5b13", selection: "#f4e5bd", palette: "solar"),
        .init(id: "sand", name: "Warm Sand", isDark: false, foreground: "#3a322a", background: "#f8f0df", accent: "#ad5d2a", selection: "#ead3ad", palette: "solar"),
        .init(id: "rose", name: "Rose Quartz", isDark: false, foreground: "#3b3035", background: "#fff7fa", accent: "#b54572", selection: "#f6d5e2", palette: "soft"),
        .init(id: "mint", name: "Fresh Mint", isDark: false, foreground: "#20332d", background: "#f3fff9", accent: "#16805f", selection: "#ccefe2", palette: "soft"),
        .init(id: "sky", name: "Clear Sky", isDark: false, foreground: "#26343c", background: "#f2fbff", accent: "#197ba8", selection: "#cceafa", palette: "classic"),
        .init(id: "lavender", name: "Lavender", isDark: false, foreground: "#332f3d", background: "#faf7ff", accent: "#7256ad", selection: "#e5daf8", palette: "soft"),
        .init(id: "sepia", name: "Sepia", isDark: false, foreground: "#43382c", background: "#f5ead5", accent: "#8f5d28", selection: "#dfc89f", palette: "solar"),
        .init(id: "monochrome-light", name: "Monochrome Light", isDark: false, foreground: "#222222", background: "#f5f5f5", accent: "#555555", selection: "#d8d8d8", palette: "classic"),
        .init(id: "serverdash-dark", name: "ServerDash Dark", isDark: true, foreground: "#e8eaed", background: "#111317", accent: "#56a8ff", selection: "#28496b", palette: "classic"),
        .init(id: "midnight", name: "Midnight", isDark: true, foreground: "#dce7f5", background: "#09111f", accent: "#5fa8ff", selection: "#1b3d65", palette: "vivid"),
        .init(id: "graphite", name: "Graphite", isDark: true, foreground: "#e0e0e0", background: "#202124", accent: "#a6a6a6", selection: "#45474c", palette: "classic"),
        .init(id: "ocean", name: "Deep Ocean", isDark: true, foreground: "#d7edf4", background: "#08232d", accent: "#37b4d2", selection: "#174b5c", palette: "soft"),
        .init(id: "forest", name: "Night Forest", isDark: true, foreground: "#dceadf", background: "#102019", accent: "#60b87a", selection: "#274b34", palette: "soft"),
        .init(id: "aubergine", name: "Aubergine", isDark: true, foreground: "#eee6f2", background: "#241629", accent: "#c184d5", selection: "#51365a", palette: "vivid"),
        .init(id: "ember", name: "Ember", isDark: true, foreground: "#f3e5dc", background: "#241511", accent: "#ef7d42", selection: "#5b3020", palette: "vivid"),
        .init(id: "nordic", name: "Nordic Night", isDark: true, foreground: "#d8dee9", background: "#2e3440", accent: "#88c0d0", selection: "#434c5e", palette: "soft"),
        .init(id: "slate", name: "Blue Slate", isDark: true, foreground: "#dfe6ed", background: "#1b2632", accent: "#70a4d4", selection: "#334b63", palette: "classic"),
        .init(id: "high-contrast", name: "High Contrast", isDark: true, foreground: "#ffffff", background: "#000000", accent: "#00d8ff", selection: "#2d4e57", palette: "vivid")
    ]
}

struct TerminalFontOption: Identifiable, Hashable {
    let postScriptName: String
    let displayName: String
    let isTargetFont: Bool

    var id: String { postScriptName }
}

enum TerminalFontCatalog {
    static let targetFamilies = [
        "Menlo", "Monaco", "DejaVu Sans Mono", "JetBrains Mono",
        "Ubuntu Mono", "Andale Mono", "Source Code Pro", "Courier New", "Courier"
    ]

    static func availableFonts() -> [TerminalFontOption] {
        NSFontManager.shared.availableFonts
            .compactMap { postScriptName -> TerminalFontOption? in
                guard let font = NSFont(name: postScriptName, size: 13),
                      isMonospaced(font) else {
                    return nil
                }
                let family = font.familyName ?? font.displayName ?? postScriptName
                return TerminalFontOption(
                    postScriptName: postScriptName,
                    displayName: family,
                    isTargetFont: targetFamilies.contains {
                        family.localizedCaseInsensitiveContains($0)
                    }
                )
            }
            .sorted {
                if $0.isTargetFont != $1.isTargetFont {
                    return $0.isTargetFont
                }
                return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
    }

    static func resolvedPostScriptName(_ requested: String) -> String {
        if let font = NSFont(name: requested, size: 13), isMonospaced(font) {
            return font.fontName
        }
        if let menlo = NSFont(name: "Menlo-Regular", size: 13) {
            return menlo.fontName
        }
        return NSFont.monospacedSystemFont(ofSize: 13, weight: .regular).fontName
    }

    static func font(name: String, size: Double) -> NSFont {
        let resolved = resolvedPostScriptName(name)
        return NSFont(name: resolved, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func isMonospaced(_ font: NSFont) -> Bool {
        if font.fontDescriptor.symbolicTraits.contains(.monoSpace) {
            return true
        }
        let wide = ("W" as NSString).size(withAttributes: [.font: font]).width
        let narrow = ("i" as NSString).size(withAttributes: [.font: font]).width
        return abs(wide - narrow) < 0.01
    }
}

@MainActor
final class TerminalAppearanceStore: ObservableObject {
    static let shared = TerminalAppearanceStore()
    static let defaultsKey = "terminalAppearanceProfile"

    @Published var profile: TerminalAppearanceProfile {
        didSet { save() }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(
               TerminalAppearanceProfile.self,
               from: data
           ) {
            profile = decoded.validated()
        } else {
            var migrated = TerminalAppearanceProfile.default
            if let legacyName = defaults.string(forKey: "terminalFontName") {
                migrated.fontPostScriptName = legacyName
            }
            let legacySize = defaults.double(forKey: "terminalFontSize")
            if legacySize > 0 {
                migrated.fontSize = legacySize
            }
            profile = migrated.validated()
        }
    }

    func reset() {
        profile = .default.validated()
    }

    func theme(dark: Bool, profile override: TerminalAppearanceProfile? = nil) -> TerminalColorTheme {
        let profile = override ?? profile
        return TerminalThemeCatalog.shared.theme(
            id: dark ? profile.darkThemeID : profile.lightThemeID,
            dark: dark
        )
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(profile.validated()) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

private extension NSColor {
    var relativeLuminance: Double {
        guard let rgb = usingColorSpace(.sRGB) else { return 0 }
        func channel(_ value: CGFloat) -> Double {
            let value = Double(value)
            return value <= 0.03928
                ? value / 12.92
                : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(rgb.redComponent)
            + 0.7152 * channel(rgb.greenComponent)
            + 0.0722 * channel(rgb.blueComponent)
    }
}
