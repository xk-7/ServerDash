#if os(macOS)
import AppKit
import CoreText
import Foundation
import SwiftUI

private struct MacGlassReduceMotionOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

private struct MacGlassReduceTransparencyOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

private struct MacGlassContrastOverrideKey: EnvironmentKey {
    static let defaultValue: ColorSchemeContrast? = nil
}

extension EnvironmentValues {
    var macGlassReduceMotionOverride: Bool? {
        get { self[MacGlassReduceMotionOverrideKey.self] }
        set { self[MacGlassReduceMotionOverrideKey.self] = newValue }
    }

    var macGlassReduceTransparencyOverride: Bool? {
        get { self[MacGlassReduceTransparencyOverrideKey.self] }
        set { self[MacGlassReduceTransparencyOverrideKey.self] = newValue }
    }

    var macGlassContrastOverride: ColorSchemeContrast? {
        get { self[MacGlassContrastOverrideKey.self] }
        set { self[MacGlassContrastOverrideKey.self] = newValue }
    }
}

enum MacGlassTokens {
    static let cornerRadius: CGFloat = 20
    static let tintOpacity = 0.10
    static let borderOpacity = 0.20
    static let increasedContrastBorderOpacity = 0.48
    static let legibilityScrimOpacity = 0.42
    static let increasedContrastScrimOpacity = 0.52
    static let hoverScale: CGFloat = 1.05
    static let entranceOffset: CGFloat = 12
    static let entranceScale: CGFloat = 0.98
    static let entranceStep: TimeInterval = 0.045
    static let maximumEntranceIndex = 8

    static func entranceDelay(for index: Int) -> TimeInterval {
        Double(min(max(index, 0), maximumEntranceIndex)) * entranceStep
    }
}

enum GlassPalette {
    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.96)
    static let tertiaryText = Color.white.opacity(0.92)
    static let border = Color.white.opacity(MacGlassTokens.borderOpacity)
    static let increasedContrastBorder = Color.white.opacity(MacGlassTokens.increasedContrastBorderOpacity)

    static let opaqueSurface = Color(
        nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 47 / 255, green: 34 / 255, blue: 70 / 255, alpha: 1)
                : NSColor(srgbRed: 91 / 255, green: 72 / 255, blue: 130 / 255, alpha: 1)
        }
    )
}

enum GlassSurfaceRole: Sendable {
    case card
    case panel
    case search
    case chrome
    case overlay
    case floatingControl

    var defaultCornerRadius: CGFloat {
        switch self {
        case .card, .panel:
            MacGlassTokens.cornerRadius
        case .search:
            AppleDesign.Radius.chip
        case .chrome:
            0
        case .overlay:
            AppleDesign.Radius.hero
        case .floatingControl:
            AppleDesign.Radius.pill
        }
    }

    var castsShadow: Bool {
        switch self {
        case .card, .panel, .overlay, .floatingControl:
            true
        case .search, .chrome:
            false
        }
    }
}

struct ServerDashBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0x66 / 255, green: 0x7e / 255, blue: 0xea / 255),
                    Color(red: 0x76 / 255, green: 0x4b / 255, blue: 0xa2 / 255)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [Color.white.opacity(0.24), Color.white.opacity(0)],
                center: UnitPoint(x: 0.10, y: 0.08),
                startRadius: 0,
                endRadius: 620
            )

            RadialGradient(
                colors: [Color(red: 0.87, green: 0.65, blue: 1).opacity(0.18), .clear],
                center: UnitPoint(x: 0.88, y: 0.84),
                startRadius: 0,
                endRadius: 520
            )
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct MacGlassSurfaceModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.macGlassReduceTransparencyOverride) private var reduceTransparencyOverride
    @Environment(\.macGlassContrastOverride) private var contrastOverride

    let role: GlassSurfaceRole
    var cornerRadius: CGFloat?

    private var radius: CGFloat { cornerRadius ?? role.defaultCornerRadius }
    private var effectiveReduceTransparency: Bool {
        reduceTransparencyOverride ?? reduceTransparency
    }
    private var effectiveContrast: ColorSchemeContrast {
        contrastOverride ?? contrast
    }
    private var legibilityScrimOpacity: Double {
        effectiveContrast == .increased
            ? MacGlassTokens.increasedContrastScrimOpacity
            : MacGlassTokens.legibilityScrimOpacity
    }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        surface(content: content)
            .foregroundStyle(
                GlassPalette.primaryText,
                GlassPalette.secondaryText,
                GlassPalette.tertiaryText
            )
            .overlay {
                shape
                    .strokeBorder(
                        effectiveContrast == .increased
                            ? GlassPalette.increasedContrastBorder
                            : GlassPalette.border,
                        lineWidth: effectiveContrast == .increased ? 1.5 : 1
                    )
                    .allowsHitTesting(false)
            }
            .shadow(
                color: role.castsShadow ? Color.black.opacity(0.16) : .clear,
                radius: 18,
                y: 10
            )
            .shadow(
                color: role.castsShadow ? Color.white.opacity(0.10) : .clear,
                radius: 2,
                y: -1
            )
    }

    @ViewBuilder
    private func surface(content: Content) -> some View {
        if effectiveReduceTransparency {
            content.background(GlassPalette.opaqueSurface, in: shape)
        } else if #available(macOS 26.0, *) {
            content
                .background(shape.fill(Color.black.opacity(legibilityScrimOpacity)))
                .glassEffect(
                    .regular.tint(Color.white.opacity(MacGlassTokens.tintOpacity)),
                    in: shape
                )
        } else {
            content.background {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay {
                        shape.fill(Color.black.opacity(legibilityScrimOpacity))
                    }
                    .overlay {
                        shape.fill(Color.white.opacity(MacGlassTokens.tintOpacity))
                    }
            }
        }
    }
}

struct ServerDashGlassEffectContainer<Content: View>: View {
    let spacing: CGFloat?
    @ViewBuilder let content: Content

    init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

@MainActor
final class GlassCardEntranceRegistry: ObservableObject {
    private var enteredIDs: Set<AnyHashable> = []

    var enteredCount: Int { enteredIDs.count }

    func contains<ID: Hashable>(_ id: ID) -> Bool {
        enteredIDs.contains(AnyHashable(id))
    }

    @discardableResult
    func markEntered<ID: Hashable>(_ id: ID) -> Bool {
        enteredIDs.insert(AnyHashable(id)).inserted
    }

    func removeAll() {
        enteredIDs.removeAll(keepingCapacity: true)
    }
}

/// Owns entrance history for the lifetime of one workbench window. Keeping the
/// registries above routed page subtrees prevents navigation from replaying the
/// stagger animation while still isolating separate windows and servers.
@MainActor
final class GlassCardEntranceStore: ObservableObject {
    private var registries: [String: GlassCardEntranceRegistry] = [:]

    func registry(for namespace: String) -> GlassCardEntranceRegistry {
        if let registry = registries[namespace] {
            return registry
        }
        let registry = GlassCardEntranceRegistry()
        registries[namespace] = registry
        return registry
    }
}

enum MacGlassMotion {
    static func shouldWaitForEntrance(
        reduceMotion: Bool,
        isPresented: Bool,
        hasEntered: Bool
    ) -> Bool {
        !reduceMotion && !isPresented && !hasEntered
    }
}

private struct GlassCardEntranceModifier<ID: Hashable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.macGlassReduceMotionOverride) private var reduceMotionOverride
    @ObservedObject var registry: GlassCardEntranceRegistry
    @State private var isPresented = false
    @State private var didHandleAppearance = false

    let id: ID
    let index: Int

    private var waitsForEntrance: Bool {
        MacGlassMotion.shouldWaitForEntrance(
            reduceMotion: reduceMotionOverride ?? reduceMotion,
            isPresented: isPresented,
            hasEntered: registry.contains(id)
        )
    }

    func body(content: Content) -> some View {
        content
            .opacity(waitsForEntrance ? 0 : 1)
            .offset(y: waitsForEntrance ? MacGlassTokens.entranceOffset : 0)
            .scaleEffect(waitsForEntrance ? MacGlassTokens.entranceScale : 1)
            .onAppear(perform: handleAppearance)
    }

    private func handleAppearance() {
        guard !didHandleAppearance else { return }
        didHandleAppearance = true

        let shouldAnimate = registry.markEntered(id)
        guard shouldAnimate, !(reduceMotionOverride ?? reduceMotion) else {
            isPresented = true
            return
        }

        withAnimation(
            .easeOut(duration: 0.32)
                .delay(MacGlassTokens.entranceDelay(for: index))
        ) {
            isPresented = true
        }
    }
}

private struct MacGlassButtonModifier: ViewModifier {
    let prominent: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                content
                    .font(AppTypography.button)
                    .buttonStyle(.glassProminent)
            } else {
                content
                    .font(AppTypography.button)
                    // Glass surfaces deliberately use white content, but a native
                    // secondary button chooses its own adaptive fill. Restore the
                    // semantic control label here so light appearances never pair
                    // a white label with that light fill. The system button style
                    // still owns disabled opacity, pressed feedback and focus rings.
                    .foregroundStyle(Color(nsColor: .controlTextColor))
                    .buttonStyle(.glass)
            }
        } else if prominent {
            content
                .font(AppTypography.button)
                .buttonStyle(.borderedProminent)
        } else {
            content
                .font(AppTypography.button)
                .foregroundStyle(Color(nsColor: .controlTextColor))
                .buttonStyle(.bordered)
        }
    }
}

extension View {
    func macGlassSurface(
        role: GlassSurfaceRole = .card,
        cornerRadius: CGFloat? = nil
    ) -> some View {
        modifier(MacGlassSurfaceModifier(role: role, cornerRadius: cornerRadius))
    }

    func glassCardEntrance<ID: Hashable>(
        id: ID,
        index: Int,
        registry: GlassCardEntranceRegistry
    ) -> some View {
        modifier(GlassCardEntranceModifier(registry: registry, id: id, index: index))
    }

    func macGlassButton(prominent: Bool = false) -> some View {
        modifier(MacGlassButtonModifier(prominent: prominent))
    }

    func macGlassSheetRoot() -> some View {
        background { ServerDashBackdrop() }
            .font(AppTypography.body)
            .foregroundStyle(
                GlassPalette.primaryText,
                GlassPalette.secondaryText,
                GlassPalette.tertiaryText
            )
    }

    func macGlassChromeBar() -> some View {
        macGlassSurface(role: .chrome, cornerRadius: 0)
    }

    func macHighContrastContentSurface(cornerRadius: CGFloat = 0) -> some View {
        foregroundStyle(Color(nsColor: .textColor))
            .background(
                Color(nsColor: .windowBackgroundColor).opacity(0.96),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
    }

    func macGlassAccessibilityOverrides(
        reduceMotion: Bool?,
        reduceTransparency: Bool?,
        contrast: ColorSchemeContrast?
    ) -> some View {
        environment(\.macGlassReduceMotionOverride, reduceMotion)
            .environment(\.macGlassReduceTransparencyOverride, reduceTransparency)
            .environment(\.macGlassContrastOverride, contrast)
    }
}

struct FontRegistrationReport: Equatable, Sendable {
    let availablePostScriptNames: [String]
    let missingFileNames: [String]
    let registrationErrors: [String]

    var allFontsAvailable: Bool {
        missingFileNames.isEmpty && registrationErrors.isEmpty
            && availablePostScriptNames.count == AppTypography.expectedPostScriptNames.count
    }
}

enum AppTypography {
    private enum Asset: CaseIterable {
        case outfitSemiBold
        case outfitBold
        case outfitExtraBold
        case plusJakartaSansRegular
        case plusJakartaSansMedium

        var fileName: String {
            switch self {
            case .outfitSemiBold: "Outfit-SemiBold"
            case .outfitBold: "Outfit-Bold"
            case .outfitExtraBold: "Outfit-ExtraBold"
            case .plusJakartaSansRegular: "PlusJakartaSans-Regular"
            case .plusJakartaSansMedium: "PlusJakartaSans-Medium"
            }
        }

        var postScriptName: String { fileName }
    }

    private final class RegistrationCache: @unchecked Sendable {
        let lock = NSLock()
        var reports: [String: FontRegistrationReport] = [:]
    }

    private static let registrationCache = RegistrationCache()

    static let expectedFileNames = Asset.allCases.map { $0.fileName + ".ttf" }
    static let expectedPostScriptNames = Asset.allCases.map(\.postScriptName)

    static var pageTitle: Font {
        pageTitle(in: .main)
    }

    static func pageTitle(in bundle: Bundle) -> Font {
        bundled(
            .outfitExtraBold,
            size: 32,
            relativeTo: .largeTitle,
            fallback: .largeTitle.weight(.bold),
            bundle: bundle
        )
    }

    static var sectionTitle: Font {
        bundled(.outfitBold, size: 22, relativeTo: .title2, fallback: .title2.weight(.bold))
    }

    static var cardTitle: Font {
        bundled(.outfitSemiBold, size: 17, relativeTo: .headline, fallback: .headline.weight(.semibold))
    }

    static var body: Font {
        body(in: .main)
    }

    static func body(in bundle: Bundle) -> Font {
        bundled(
            .plusJakartaSansRegular,
            size: 14,
            relativeTo: .body,
            fallback: .body,
            bundle: bundle
        )
    }

    static var label: Font {
        bundled(.plusJakartaSansMedium, size: 12, relativeTo: .caption, fallback: .caption.weight(.medium))
    }

    static var button: Font {
        bundled(.plusJakartaSansMedium, size: 14, relativeTo: .callout, fallback: .callout.weight(.medium))
    }

    @discardableResult
    static func registerBundledFonts(in bundle: Bundle = .main) -> FontRegistrationReport {
        let cacheKey = bundle.bundleURL.standardizedFileURL.path
        registrationCache.lock.lock()
        defer { registrationCache.lock.unlock() }

        if let cached = registrationCache.reports[cacheKey] {
            return cached
        }

        var available: [String] = []
        var missing: [String] = []
        var errors: [String] = []

        for asset in Asset.allCases {
            guard let url = resourceURL(for: asset, in: bundle) else {
                missing.append(asset.fileName + ".ttf")
                continue
            }

            if NSFont(name: asset.postScriptName, size: 12) != nil {
                available.append(asset.postScriptName)
                continue
            }

            var unmanagedError: Unmanaged<CFError>?
            let registered = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &unmanagedError)
            if registered || NSFont(name: asset.postScriptName, size: 12) != nil {
                available.append(asset.postScriptName)
            } else if let error = unmanagedError?.takeRetainedValue() {
                errors.append("\(asset.fileName).ttf: \(error.localizedDescription)")
            } else {
                errors.append("\(asset.fileName).ttf: registration failed")
            }
        }

        let report = FontRegistrationReport(
            availablePostScriptNames: available.sorted(),
            missingFileNames: missing.sorted(),
            registrationErrors: errors.sorted()
        )
        registrationCache.reports[cacheKey] = report
        return report
    }

    static func usesBundledFont(_ postScriptName: String, in bundle: Bundle = .main) -> Bool {
        let report = registerBundledFonts(in: bundle)
        return report.availablePostScriptNames.contains(postScriptName)
            && NSFont(name: postScriptName, size: 12) != nil
    }

    private static func bundled(
        _ asset: Asset,
        size: CGFloat,
        relativeTo textStyle: Font.TextStyle,
        fallback: Font,
        bundle: Bundle = .main
    ) -> Font {
        guard usesBundledFont(asset.postScriptName, in: bundle) else {
            return fallback
        }
        return .custom(asset.postScriptName, size: size, relativeTo: textStyle)
    }

    private static func resourceURL(for asset: Asset, in bundle: Bundle) -> URL? {
        for directory in ["Fonts", "MacResources/Fonts", nil] as [String?] {
            if let url = bundle.url(
                forResource: asset.fileName,
                withExtension: "ttf",
                subdirectory: directory
            ) {
                return url
            }
        }
        return nil
    }
}
#endif
