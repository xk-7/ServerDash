import AppKit
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum AppleDesign {
    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 22
        static let xl: CGFloat = 32
        static let section: CGFloat = 44
    }

    enum Radius {
        static let chip: CGFloat = 6
        static let thumbnail: CGFloat = 12
        static let card: CGFloat = 18
        static let panel: CGFloat = 22
        static let hero: CGFloat = 26
        static let pill: CGFloat = 999
    }

    static let spring = Animation.spring(duration: 0.38, bounce: 0)
    static let quick = Animation.easeOut(duration: 0.18)
}

extension Color {
    static let appGround = Color(
        light: NSColor(srgbRed: 245 / 255, green: 245 / 255, blue: 247 / 255, alpha: 1),
        dark: NSColor(srgbRed: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 1)
    )
    static let appSurface = Color(
        light: .white,
        dark: NSColor(srgbRed: 44 / 255, green: 44 / 255, blue: 46 / 255, alpha: 1)
    )
    static let appHover = Color(
        light: NSColor(srgbRed: 251 / 255, green: 251 / 255, blue: 253 / 255, alpha: 1),
        dark: NSColor(srgbRed: 52 / 255, green: 52 / 255, blue: 54 / 255, alpha: 1)
    )
    static let appHairline = Color(nsColor: .separatorColor)
    static let appTrack = Color(
        light: NSColor(srgbRed: 232 / 255, green: 232 / 255, blue: 237 / 255, alpha: 1),
        dark: NSColor(srgbRed: 58 / 255, green: 58 / 255, blue: 60 / 255, alpha: 1)
    )
    static let appAccent = Color.accentColor
    static let appLive = Color(nsColor: .systemGreen)
    static let appWarning = Color(nsColor: .systemOrange)
    static let appError = Color(nsColor: .systemRed)

    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

struct ApplePanelModifier: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    var padding: CGFloat = 16
    var radius: CGFloat = AppleDesign.Radius.panel

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Color.appSurface)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(
                        Color.appHairline.opacity(contrast == .increased ? 1 : 0.35),
                        lineWidth: 1
                    )
            }
            .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
            .shadow(color: .black.opacity(0.05), radius: 20, y: 8)
    }
}

extension View {
    func applePanel(
        padding: CGFloat = AppleDesign.Spacing.md,
        radius: CGFloat = AppleDesign.Radius.panel
    ) -> some View {
        modifier(ApplePanelModifier(padding: padding, radius: radius))
    }
}

struct AppleUnifiedPanel<Content: View>: View {
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppleDesign.Radius.panel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppleDesign.Radius.panel, style: .continuous)
                .stroke(
                    Color.appHairline.opacity(contrast == .increased ? 1 : 0.35),
                    lineWidth: 1
                )
        }
        .shadow(color: .black.opacity(0.035), radius: 2, y: 1)
        .shadow(color: .black.opacity(0.045), radius: 18, y: 7)
    }
}

struct AppleSectionHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppleDesign.Spacing.xxs) {
            Text(title)
                .font(.title2.weight(.bold))
                .tracking(-0.35)
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct AppleChromeBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if reduceTransparency {
            Color.appSurface
        } else {
            Rectangle()
                .fill(contrast == .increased ? .thickMaterial : .regularMaterial)
        }
    }
}

struct StatusDot: View {
    let status: ServerConnectionStatus
    var size: CGFloat = 8

    private var color: Color {
        switch status {
        case .online: .appLive
        case .connecting: .appWarning
        case .failed, .offline: .appError
        case .unknown: .secondary
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct MetricCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let title: String
    let value: String
    let subtitle: String
    let progress: Double
    var tint: Color = .appAccent

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .contentTransition(reduceMotion ? .identity : .numericText())
            ProgressView(value: min(max(progress, 0), 1))
                .tint(tint)
                .scaleEffect(x: 1, y: 0.7)
            Text(subtitle)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(AppleDesign.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ApplePressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .padding(.horizontal, AppleDesign.Spacing.sm)
            .padding(.vertical, AppleDesign.Spacing.xs)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.06))
            )
            .frame(minWidth: 44, minHeight: 44)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : AppleDesign.quick, value: configuration.isPressed)
    }
}

typealias CompactActionButtonStyle = ApplePressButtonStyle

enum DisplayFormat {
    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    static func bytes(_ value: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB, .useTB]
        formatter.countStyle = .binary
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(max(0, value)))
    }

    static func speed(_ value: Double) -> String {
        "\(bytes(value))/s"
    }

    static func shortDate(_ date: Date?) -> String {
        guard let date else { return "尚未连接" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

