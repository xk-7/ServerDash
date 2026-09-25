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
        static let card: CGFloat = 18
        static let panel: CGFloat = 22
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

/// Test-only display preference overrides carried through the view environment.
/// Production views still honor the real accessibility environment; the
/// isolated MacQA app can additionally force each state without changing the
/// developer machine's system settings. The key exists on every Apple target
/// because shared design modifiers consume it; only the MacQA target injects it.
struct MacAccessibilityOverrides: Equatable, Sendable {
    var reduceMotion = false
    var reduceTransparency = false
    var increaseContrast = false

    static let none = MacAccessibilityOverrides()
}

private struct MacAccessibilityOverridesKey: EnvironmentKey {
    static let defaultValue = MacAccessibilityOverrides.none
}

extension EnvironmentValues {
    var macAccessibilityOverrides: MacAccessibilityOverrides {
        get { self[MacAccessibilityOverridesKey.self] }
        set { self[MacAccessibilityOverridesKey.self] = newValue }
    }
}

#if os(macOS)
/// Describes the usable detail area rather than the window's outer frame.
///
/// Keeping this calculation in one value type prevents individual pages from
/// drifting toward slightly different responsive breakpoints. A short window
/// deliberately enters the compact tier even when it is wide: vertical space
/// is the limiting resource at ServerDash's supported 900 x 620 window size.
struct MacWorkspaceMetrics: Equatable {
    enum Tier: Equatable {
        case compact
        case regular
        case wide
    }

    static let compactWidth: CGFloat = 760
    static let compactHeight: CGFloat = 680
    static let wideWidth: CGFloat = 1_200

    let width: CGFloat
    let height: CGFloat

    init(width: CGFloat, height: CGFloat) {
        self.width = max(0, width)
        self.height = max(0, height)
    }

    init(size: CGSize) {
        self.init(width: size.width, height: size.height)
    }

    var tier: Tier {
        if width < Self.compactWidth || height < Self.compactHeight {
            return .compact
        }
        return width < Self.wideWidth ? .regular : .wide
    }

    var isCompact: Bool { tier == .compact }
    var isWide: Bool { tier == .wide }
    var pagePadding: CGFloat { isCompact ? AppleDesign.Spacing.md : AppleDesign.Spacing.lg }
    var gridMinimumWidth: CGFloat { isCompact ? 244 : 280 }

    // Content density follows the usable detail area. Keep primary text at its
    // semantic size; compact windows save space through chrome and spacing.
    var sectionSpacing: CGFloat { isCompact ? AppleDesign.Spacing.sm : AppleDesign.Spacing.md }
    var cardPadding: CGFloat { isCompact ? AppleDesign.Spacing.sm : AppleDesign.Spacing.md }
    var cardContentSpacing: CGFloat { isCompact ? AppleDesign.Spacing.xs : AppleDesign.Spacing.sm }
    var tableRowPadding: CGFloat { isCompact ? AppleDesign.Spacing.xxs / 2 : AppleDesign.Spacing.xxs }
    var inspectorPadding: CGFloat { isCompact ? AppleDesign.Spacing.xs : AppleDesign.Spacing.sm }
    var pageHeaderPadding: CGFloat { isCompact ? AppleDesign.Spacing.sm : AppleDesign.Spacing.md }
}

/// Shared native sheet chrome for macOS editors.
///
/// Editors keep ownership of validation and dismissal while the scaffold
/// provides a scroll-safe content region, native button placement and a
/// consistent inline error announcement. The maximum width is a ceiling, so a
/// sheet hosted by the minimum supported window can always shrink to fit.
struct MacEditorSheetScaffold<Content: View>: View {
    let title: String
    let accessibilityID: String
    let cancelTitle: String
    let cancelRole: ButtonRole?
    let showsCancelAction: Bool
    let cancelDisabled: Bool
    let cancelAccessibilityID: String?
    let saveTitle: String
    let showsSaveAction: Bool
    let saveAccessibilityID: String?
    let errorMessage: String?
    let saveDisabled: Bool
    let maxContentWidth: CGFloat
    let scrollsContent: Bool
    let onCancel: () -> Void
    let onSave: () -> Void
    let onValidationError: (() -> Void)?
    @ViewBuilder let content: Content

    @AccessibilityFocusState private var errorIsFocused: Bool

    init(
        title: String,
        accessibilityID: String = "mac.editor.sheet",
        cancelTitle: String = "取消",
        cancelRole: ButtonRole? = .cancel,
        showsCancelAction: Bool = true,
        cancelDisabled: Bool = false,
        cancelAccessibilityID: String? = nil,
        saveTitle: String = "保存",
        showsSaveAction: Bool = true,
        saveAccessibilityID: String? = nil,
        errorMessage: String? = nil,
        saveDisabled: Bool = false,
        maxContentWidth: CGFloat = 720,
        scrollsContent: Bool = true,
        onCancel: @escaping () -> Void,
        onSave: @escaping () -> Void,
        onValidationError: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.accessibilityID = accessibilityID
        self.cancelTitle = cancelTitle
        self.cancelRole = cancelRole
        self.showsCancelAction = showsCancelAction
        self.cancelDisabled = cancelDisabled
        self.cancelAccessibilityID = cancelAccessibilityID
        self.saveTitle = saveTitle
        self.showsSaveAction = showsSaveAction
        self.saveAccessibilityID = saveAccessibilityID
        self.errorMessage = errorMessage
        self.saveDisabled = saveDisabled
        self.maxContentWidth = max(320, maxContentWidth)
        self.scrollsContent = scrollsContent
        self.onCancel = onCancel
        self.onSave = onSave
        self.onValidationError = onValidationError
        self.content = content()
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                Group {
                    if scrollsContent {
                        ScrollView { scrollingSheetContent(width: geometry.size.width) }
                    } else {
                        nonScrollingSheetContent(width: geometry.size.width)
                    }
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .font(.headline)
                        .accessibilityIdentifier("\(accessibilityID).title")
                }
                if showsCancelAction {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(cancelTitle, role: cancelRole, action: onCancel)
                            .keyboardShortcut(.cancelAction)
                            .disabled(cancelDisabled)
                            .accessibilityIdentifier(cancelAccessibilityID ?? "\(accessibilityID).cancel")
                    }
                }
                if showsSaveAction {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(saveTitle, action: onSave)
                            .keyboardShortcut(.defaultAction)
                            .disabled(saveDisabled)
                            .accessibilityIdentifier(saveAccessibilityID ?? "\(accessibilityID).save")
                    }
                }
            }
        }
        .frame(idealWidth: min(768, maxContentWidth + AppleDesign.Spacing.xl * 2), idealHeight: 560)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(accessibilityID).container")
        .onAppear { focusValidationTarget(for: errorMessage) }
        .onChange(of: errorMessage) { _, value in
            focusValidationTarget(for: value)
        }
    }

    private func scrollingSheetContent(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: AppleDesign.Spacing.md) {
            content
            validationError
        }
        .frame(
            maxWidth: min(maxContentWidth, max(0, width - AppleDesign.Spacing.xl * 2)),
            alignment: .leading
        )
        .padding(AppleDesign.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func nonScrollingSheetContent(width: CGFloat) -> some View {
        content
            .frame(
                maxWidth: min(maxContentWidth, max(0, width - AppleDesign.Spacing.xl * 2)),
                maxHeight: .infinity,
                alignment: .topLeading
            )
            .padding(AppleDesign.Spacing.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if errorMessage?.isEmpty == false {
                    validationError
                        .padding(.horizontal, AppleDesign.Spacing.lg)
                        .padding(.bottom, AppleDesign.Spacing.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.bar)
                }
            }
    }

    @ViewBuilder
    private var validationError: some View {
        if let errorMessage, !errorMessage.isEmpty {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(Color.appError)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityFocused($errorIsFocused)
                .accessibilityIdentifier("\(accessibilityID).error")
        }
    }

    private func focusValidationTarget(for message: String?) {
        guard message?.isEmpty == false else {
            errorIsFocused = false
            return
        }
        if let onValidationError {
            errorIsFocused = false
            onValidationError()
        } else {
            // Editors without field-level validation still expose and focus the
            // inline error instead of dropping the VoiceOver announcement.
            errorIsFocused = true
        }
    }
}
#endif

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
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.macAccessibilityOverrides) private var accessibilityOverrides

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
                        Color.appHairline.opacity((contrast == .increased || accessibilityOverrides.increaseContrast) ? 1 : 0.35),
                        lineWidth: 1
                    )
            }
            .shadow(color: .black.opacity(0.025), radius: 3, y: 1)
    }
}

extension View {
    func applePanel(
        padding: CGFloat = AppleDesign.Spacing.md,
        radius: CGFloat = AppleDesign.Radius.panel
    ) -> some View {
        modifier(ApplePanelModifier(padding: padding, radius: radius))
    }

    func appleInteractiveSurface(radius: CGFloat = AppleDesign.Radius.card) -> some View {
        modifier(AppleInteractiveSurface(radius: radius))
    }
}

private struct AppleInteractiveSurface: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.macAccessibilityOverrides) private var accessibilityOverrides
    @State private var hovering = false
    let radius: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(hovering ? Color.appAccent.opacity(0.45) : .clear, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .onHover { hovering = $0 }
            .animation((reduceMotion || accessibilityOverrides.reduceMotion) ? nil : AppleDesign.quick, value: hovering)
    }
}

struct AppleUnifiedPanel<Content: View>: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.macAccessibilityOverrides) private var accessibilityOverrides

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
                    Color.appHairline.opacity((contrast == .increased || accessibilityOverrides.increaseContrast) ? 1 : 0.35),
                    lineWidth: 1
                )
        }
    }
}

struct AppleSectionHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppleDesign.Spacing.xxs) {
            Text(title)
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
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
                .background(Color.appSurface, in: RoundedRectangle(cornerRadius: AppleDesign.Radius.thumbnail))
                .accessibilityHidden(true)
            AppleSectionHeader(title: title, subtitle: subtitle)
        }
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

    var body: some View {
        HStack(spacing: AppleDesign.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .accessibilityLabel(prompt)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(AppleDesign.Spacing.xs)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: AppleDesign.Radius.chip))
        .overlay {
            RoundedRectangle(cornerRadius: AppleDesign.Radius.chip)
                .strokeBorder(isFocused ? Color.appAccent : Color.appHairline.opacity(0.5), lineWidth: 1)
                .allowsHitTesting(false)
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
            Text(status.title).font(.caption.weight(.medium))
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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.macAccessibilityOverrides) private var accessibilityOverrides

    var body: some View {
        if reduceTransparency || accessibilityOverrides.reduceTransparency {
            Color.appSurface
        } else {
            Rectangle()
                .fill((contrast == .increased || accessibilityOverrides.increaseContrast) ? .thickMaterial : .regularMaterial)
        }
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
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                if let detail {
                    Text(detail)
                        .font(.caption2)
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
                        .font(.caption2)
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
    @Environment(\.macAccessibilityOverrides) private var accessibilityOverrides

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
                .contentTransition((reduceMotion || accessibilityOverrides.reduceMotion) ? .identity : .numericText())
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
    @Environment(\.macAccessibilityOverrides) private var accessibilityOverrides

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
            .scaleEffect(configuration.isPressed && !(reduceMotion || accessibilityOverrides.reduceMotion) ? 0.98 : 1)
            .animation((reduceMotion || accessibilityOverrides.reduceMotion) ? nil : AppleDesign.quick, value: configuration.isPressed)
    }
}

typealias CompactActionButtonStyle = ApplePressButtonStyle
