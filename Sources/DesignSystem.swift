import SwiftUI

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

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
#if os(macOS)
        static let card: CGFloat = MacGlassTokens.cornerRadius
        static let panel: CGFloat = MacGlassTokens.cornerRadius
#else
        static let card: CGFloat = 18
        static let panel: CGFloat = 22
#endif
        static let hero: CGFloat = 26
        static let pill: CGFloat = 999
    }

    enum Layout {
        static let contentWidth: CGFloat = 1200
        static let readingWidth: CGFloat = 960
    }

    static let spring = Animation.spring(duration: 0.38, bounce: 0)
    static let quick = Animation.easeOut(duration: 0.18)
}

enum MonitorSeverity: String, Equatable {
    case normal
    case warning
    case critical

    static func percentage(_ value: Double) -> MonitorSeverity {
        if value >= 90 { return .critical }
        if value >= 75 { return .warning }
        return .normal
    }

    var color: Color {
        switch self {
        case .normal: .appAccent
        case .warning: .appWarning
        case .critical: .appError
        }
    }
}

extension Color {
#if canImport(AppKit)
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
#else
    static let appGround = Color(uiColor: .systemGroupedBackground)
    static let appSurface = Color(uiColor: .secondarySystemGroupedBackground)
    static let appHover = Color(uiColor: .tertiarySystemGroupedBackground)
    static let appHairline = Color(uiColor: .separator)
    static let appTrack = Color(uiColor: .quaternarySystemFill)
    static let appAccent = Color.accentColor
    static let appLive = Color(uiColor: .systemGreen)
    static let appWarning = Color(uiColor: .systemOrange)
    static let appError = Color(uiColor: .systemRed)
#endif
}

struct ApplePanelModifier: ViewModifier {
#if !os(macOS)
    @Environment(\.colorSchemeContrast) private var contrast
#endif

    var padding: CGFloat = 16
    var radius: CGFloat = AppleDesign.Radius.panel

    @ViewBuilder
    func body(content: Content) -> some View {
#if os(macOS)
        content
            .padding(padding)
            .modifier(MacGlassSurfaceModifier(role: .panel, cornerRadius: radius))
#else
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
            .shadow(color: .black.opacity(0.025), radius: 3, y: 1)
#endif
    }
}

extension View {
    @ViewBuilder
    func macGlassFormBackground() -> some View {
#if os(macOS)
        self.scrollContentBackground(.hidden)
#else
        self
#endif
    }

    func applePanel(
        padding: CGFloat = AppleDesign.Spacing.md,
        radius: CGFloat = AppleDesign.Radius.panel
    ) -> some View {
        modifier(ApplePanelModifier(padding: padding, radius: radius))
    }

    func appleInteractiveSurface(
        radius: CGFloat = AppleDesign.Radius.card,
        isEnabled: Bool = true
    ) -> some View {
        modifier(AppleInteractiveSurface(radius: radius, isEnabled: isEnabled))
    }
}

private struct AppleInteractiveSurface: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
#if os(macOS)
    @Environment(\.macGlassReduceMotionOverride) private var reduceMotionOverride
#endif
    @State private var hovering = false
    let radius: CGFloat
    let isEnabled: Bool

    private var effectiveReduceMotion: Bool {
#if os(macOS)
        reduceMotionOverride ?? reduceMotion
#else
        reduceMotion
#endif
    }

    @ViewBuilder
    func body(content: Content) -> some View {
#if os(macOS)
        content
            .scaleEffect(hovering && isEnabled && !effectiveReduceMotion ? MacGlassTokens.hoverScale : 1)
            .zIndex(hovering && isEnabled ? 1 : 0)
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        hovering && isEnabled ? Color.white.opacity(0.32) : .clear,
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            }
            .shadow(
                color: hovering && isEnabled ? Color.appAccent.opacity(0.22) : .clear,
                radius: 18
            )
            .onHover { hovering = isEnabled && $0 }
            .animation(effectiveReduceMotion ? nil : AppleDesign.quick, value: hovering)
#else
        content
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(hovering && isEnabled ? Color.appAccent.opacity(0.45) : .clear, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .onHover { hovering = isEnabled && $0 }
            .animation(effectiveReduceMotion ? nil : AppleDesign.quick, value: hovering)
#endif
    }
}

struct AppleUnifiedPanel<Content: View>: View {
#if !os(macOS)
    @Environment(\.colorSchemeContrast) private var contrast
#endif

    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
#if os(macOS)
        VStack(spacing: 0) {
            content
        }
        .modifier(
            MacGlassSurfaceModifier(
                role: .panel,
                cornerRadius: AppleDesign.Radius.panel
            )
        )
#else
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
#endif
    }
}

struct AppleSectionHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppleDesign.Spacing.xxs) {
            Text(title)
#if os(macOS)
                .font(AppTypography.sectionTitle)
#else
                .font(.title2.weight(.semibold))
#endif
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
#if os(macOS)
                    .font(AppTypography.body)
#else
                    .font(.callout)
#endif
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A shared page heading that keeps actions usable at the minimum window width.
struct AppleWorkspaceHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    @ViewBuilder let actions: Actions

    init(title: String, subtitle: String, symbol: String, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.actions = actions()
    }

    private var heading: some View {
        HStack(alignment: .center, spacing: AppleDesign.Spacing.sm) {
            Image(systemName: symbol)
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
#if os(macOS)
                .macGlassSurface(
                    role: .floatingControl,
                    cornerRadius: AppleDesign.Radius.thumbnail
                )
#else
                .background(Color.appSurface, in: RoundedRectangle(cornerRadius: AppleDesign.Radius.thumbnail))
#endif
                .accessibilityHidden(true)
            AppleSectionHeader(title: title, subtitle: subtitle)
        }
#if os(macOS)
        .foregroundStyle(
            GlassPalette.primaryText,
            GlassPalette.secondaryText,
            GlassPalette.tertiaryText
        )
#endif
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: AppleDesign.Spacing.lg) {
                heading
                Spacer(minLength: AppleDesign.Spacing.md)
                actions.fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: AppleDesign.Spacing.md) {
                heading
                actions
            }
        }
        .controlSize(.regular)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AppleSearchField: View {
    let prompt: String
    @Binding var text: String
    @FocusState private var isFocused: Bool

    @ViewBuilder
    var body: some View {
#if os(macOS)
        searchContents
            .padding(AppleDesign.Spacing.xs)
            .modifier(
                MacGlassSurfaceModifier(
                    role: .search,
                    cornerRadius: AppleDesign.Radius.chip
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: AppleDesign.Radius.chip, style: .continuous)
                    .strokeBorder(
                        isFocused ? Color.white.opacity(0.78) : .clear,
                        lineWidth: isFocused ? 2 : 1
                    )
                    .allowsHitTesting(false)
            }
#else
        searchContents
            .padding(AppleDesign.Spacing.xs)
            .background(Color.appSurface, in: RoundedRectangle(cornerRadius: AppleDesign.Radius.chip))
            .overlay {
                RoundedRectangle(cornerRadius: AppleDesign.Radius.chip)
                    .strokeBorder(isFocused ? Color.appAccent : Color.appHairline.opacity(0.5), lineWidth: 1)
                    .allowsHitTesting(false)
            }
#endif
    }

    private var searchContents: some View {
        HStack(spacing: AppleDesign.Spacing.xs) {
            Image(systemName: "magnifyingglass")
#if os(macOS)
                .foregroundStyle(GlassPalette.secondaryText)
#else
                .foregroundStyle(.secondary)
#endif
                .accessibilityHidden(true)
            Group {
#if os(macOS)
                ZStack(alignment: .leading) {
                    if text.isEmpty {
                        Text(prompt)
                            .foregroundStyle(GlassPalette.secondaryText)
                            .lineLimit(1)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    TextField("", text: $text)
                        .foregroundStyle(GlassPalette.primaryText)
                }
#else
                TextField(prompt, text: $text)
#endif
            }
                .textFieldStyle(.plain)
#if os(macOS)
                .font(AppTypography.body)
#endif
                .focused($isFocused)
                .accessibilityLabel(prompt)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
#if os(macOS)
                        .foregroundStyle(GlassPalette.secondaryText)
#else
                        .foregroundStyle(.secondary)
#endif
                }
                .buttonStyle(.plain)
                .help("清除搜索")
                .accessibilityLabel("清除搜索")
            }
        }
    }
}

struct ServerStatusBadge: View {
    let status: ServerConnectionStatus

    private var tint: Color {
        switch status {
        case .online: .appLive
        case .connecting: .appWarning
        case .failed, .offline: .appError
        case .unknown: .secondary
        }
    }

    var body: some View {
        HStack(spacing: AppleDesign.Spacing.xxs) {
            StatusDot(status: status, size: 6)
            Text(status.title)
#if os(macOS)
                .font(AppTypography.label)
#else
                .font(.caption.weight(.medium))
#endif
        }
        .foregroundStyle(tint)
        .padding(.horizontal, AppleDesign.Spacing.xs)
        .padding(.vertical, AppleDesign.Spacing.xxs)
        .background(tint.opacity(0.08), in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

struct AppleChromeBackground: View {
#if !os(macOS)
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
#endif

    @ViewBuilder
    var body: some View {
#if os(macOS)
        Color.clear
            .modifier(MacGlassSurfaceModifier(role: .chrome, cornerRadius: 0))
#else
        if reduceTransparency {
            Color.appSurface
        } else {
            Rectangle()
                .fill(contrast == .increased ? .thickMaterial : .regularMaterial)
        }
#endif
    }
}

struct AppleDismissibleOverlay<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
#if os(macOS)
    @Environment(\.macGlassReduceMotionOverride) private var reduceMotionOverride
#endif

    let maxWidth: CGFloat
    let maxHeight: CGFloat
    let onDismiss: () -> Void
    @ViewBuilder let content: Content

    private var effectiveReduceMotion: Bool {
#if os(macOS)
        reduceMotionOverride ?? reduceMotion
#else
        reduceMotion
#endif
    }

    init(
        maxWidth: CGFloat,
        maxHeight: CGFloat,
        onDismiss: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.onDismiss = onDismiss
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        ZStack {
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            content
                .frame(maxWidth: maxWidth, maxHeight: maxHeight)
#if os(macOS)
                .modifier(
                    MacGlassSurfaceModifier(
                        role: .overlay,
                        cornerRadius: AppleDesign.Radius.hero
                    )
                )
#else
                .background(Color.appGround)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: AppleDesign.Radius.hero,
                        style: .continuous
                    )
                )
                .shadow(color: .black.opacity(0.22), radius: 28, y: 12)
#endif
                .contentShape(
                    RoundedRectangle(
                        cornerRadius: AppleDesign.Radius.hero,
                        style: .continuous
                    )
                )
                .padding(AppleDesign.Spacing.xl)
        }
        .appleExitCommand(perform: onDismiss)
        .transition(
            effectiveReduceMotion
                ? .opacity
                : .opacity.combined(with: .scale(scale: 0.98))
        )
    }
}

private extension View {
    @ViewBuilder
    func appleExitCommand(perform action: @escaping () -> Void) -> some View {
#if os(macOS)
        onExitCommand(perform: action)
#else
        self
#endif
    }
}

struct MonitorSectionPanel<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppleDesign.Spacing.md) {
            VStack(alignment: .leading, spacing: AppleDesign.Spacing.xxs) {
                Text(title)
#if os(macOS)
                    .font(AppTypography.cardTitle)
#else
                    .font(.headline)
#endif
                if let subtitle {
                    Text(subtitle)
#if os(macOS)
                        .font(AppTypography.label)
#else
                        .font(.caption)
#endif
                        .foregroundStyle(.secondary)
                }
            }
            content
        }
        .applePanel(padding: AppleDesign.Spacing.lg, radius: AppleDesign.Radius.card)
    }
}

struct MonitorStatTile: View {
    let title: String
    let value: String
    let symbol: String
    var tint: Color = .appAccent
    var detail: String?

    var body: some View {
        HStack(spacing: AppleDesign.Spacing.sm) {
            Image(systemName: symbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.11))
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: AppleDesign.Radius.chip,
                        style: .continuous
                    )
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
#if os(macOS)
                    .font(AppTypography.label)
#else
                    .font(.caption)
#endif
                    .foregroundStyle(.secondary)
                Text(value)
#if os(macOS)
                    .font(AppTypography.button)
#else
                    .font(.callout.weight(.semibold))
#endif
                    .monospacedDigit()
                if let detail {
                    Text(detail)
#if os(macOS)
                        .font(AppTypography.label)
#else
                        .font(.caption2)
#endif
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct MonitorLinearGauge: View {
    let value: Double
    var tint: Color? = nil

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.appTrack)
                Capsule()
                    .fill(tint ?? MonitorSeverity.percentage(value).color)
                    .frame(
                        width: geometry.size.width * min(1, max(0, value / 100))
                    )
            }
        }
        .frame(height: 7)
        .accessibilityLabel("使用率")
        .accessibilityValue(DisplayFormat.percent(value))
    }
}

struct MonitorLegend: View {
    let items: [(title: String, color: Color)]

    var body: some View {
        HStack(spacing: AppleDesign.Spacing.sm) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: AppleDesign.Spacing.xxs) {
                    Circle()
                        .fill(item.color)
                        .frame(width: 7, height: 7)
                    Text(item.title)
#if os(macOS)
                        .font(AppTypography.label)
#else
                        .font(.caption2)
#endif
                        .foregroundStyle(.secondary)
                }
            }
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
