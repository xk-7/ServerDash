#if os(macOS)
import AppKit
import XCTest
@testable import ServerDash

@MainActor
final class MacGlassThemeTests: XCTestCase {
    func testPublishedGlassTokensMatchTheDesignContract() {
        XCTAssertEqual(MacGlassTokens.cornerRadius, 20)
        XCTAssertEqual(MacGlassTokens.tintOpacity, 0.10, accuracy: 0.0001)
        XCTAssertEqual(MacGlassTokens.borderOpacity, 0.20, accuracy: 0.0001)
        XCTAssertGreaterThan(MacGlassTokens.increasedContrastBorderOpacity, MacGlassTokens.borderOpacity)
        XCTAssertEqual(MacGlassTokens.legibilityScrimOpacity, 0.42, accuracy: 0.0001)
        XCTAssertGreaterThan(
            MacGlassTokens.increasedContrastScrimOpacity,
            MacGlassTokens.legibilityScrimOpacity
        )
        XCTAssertEqual(MacGlassTokens.hoverScale, 1.05, accuracy: 0.0001)
        XCTAssertEqual(MacGlassTokens.entranceOffset, 12)
        XCTAssertEqual(MacGlassTokens.entranceScale, 0.98, accuracy: 0.0001)
        XCTAssertEqual(MacGlassTokens.entranceStep, 0.045, accuracy: 0.0001)
        XCTAssertEqual(MacGlassTokens.maximumEntranceIndex, 8)
        XCTAssertEqual(MacGlassTokens.entranceDelay(for: -3), 0, accuracy: 0.0001)
        XCTAssertEqual(MacGlassTokens.entranceDelay(for: 4), 0.180, accuracy: 0.0001)
        XCTAssertEqual(MacGlassTokens.entranceDelay(for: 99), 0.360, accuracy: 0.0001)
    }

    func testSurfaceRolesKeepDenseChromeFlatAndCardsElevated() {
        XCTAssertEqual(GlassSurfaceRole.card.defaultCornerRadius, 20)
        XCTAssertEqual(GlassSurfaceRole.panel.defaultCornerRadius, 20)
        XCTAssertEqual(GlassSurfaceRole.chrome.defaultCornerRadius, 0)
        XCTAssertTrue(GlassSurfaceRole.card.castsShadow)
        XCTAssertTrue(GlassSurfaceRole.overlay.castsShadow)
        XCTAssertFalse(GlassSurfaceRole.search.castsShadow)
        XCTAssertFalse(GlassSurfaceRole.chrome.castsShadow)
    }

    func testEntranceRegistryAdmitsEachStableIdentifierOnlyOnce() {
        let registry = GlassCardEntranceRegistry()
        let stableID = UUID()

        XCTAssertFalse(registry.contains(stableID))
        XCTAssertTrue(registry.markEntered(stableID))
        XCTAssertTrue(registry.contains(stableID))
        XCTAssertFalse(registry.markEntered(stableID), "刷新或筛选后同一卡片不能再次入场")
        XCTAssertEqual(registry.enteredCount, 1)

        XCTAssertTrue(registry.markEntered("another-card"))
        XCTAssertEqual(registry.enteredCount, 2)
        registry.removeAll()
        XCTAssertEqual(registry.enteredCount, 0)
    }

    func testWindowEntranceStoreKeepsNamespacesAcrossPageRecreation() {
        let store = GlassCardEntranceStore()
        let dashboard = store.registry(for: "dashboard")
        XCTAssertTrue(dashboard.markEntered("host-1"))

        let recreatedDashboard = store.registry(for: "dashboard")
        XCTAssertTrue(dashboard === recreatedDashboard)
        XCTAssertFalse(recreatedDashboard.markEntered("host-1"), "切页返回后同一卡片不能重新入场")

        let machines = store.registry(for: "machines")
        XCTAssertFalse(dashboard === machines)
        XCTAssertTrue(machines.markEntered("host-1"), "不同页面使用独立稳定 ID 命名空间")
    }

    func testEntranceMotionStopsForReduceMotionRefreshAndPresentedCards() {
        XCTAssertTrue(
            MacGlassMotion.shouldWaitForEntrance(
                reduceMotion: false,
                isPresented: false,
                hasEntered: false
            )
        )
        XCTAssertFalse(
            MacGlassMotion.shouldWaitForEntrance(
                reduceMotion: true,
                isPresented: false,
                hasEntered: false
            ),
            "Reduce Motion 必须立即显示卡片"
        )
        XCTAssertFalse(
            MacGlassMotion.shouldWaitForEntrance(
                reduceMotion: false,
                isPresented: false,
                hasEntered: true
            ),
            "刷新或筛选重新出现的卡片不能再次等待入场"
        )
        XCTAssertFalse(
            MacGlassMotion.shouldWaitForEntrance(
                reduceMotion: false,
                isPresented: true,
                hasEntered: false
            )
        )
    }

    func testMissingFontBundleReportsFallbackWithoutBlockingTypography() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("serverdash-font-fallback-\(UUID().uuidString).bundle", isDirectory: true)
        let contents = root.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: contents.appendingPathComponent("Resources", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.serverdash.tests.missing-fonts.\(UUID().uuidString)",
            "CFBundleName": "Missing Fonts",
            "CFBundlePackageType": "BNDL"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
        let bundle = try XCTUnwrap(Bundle(url: root))

        let report = AppTypography.registerBundledFonts(in: bundle)
        XCTAssertEqual(Set(report.missingFileNames), Set(AppTypography.expectedFileNames))
        XCTAssertFalse(report.allFontsAvailable)
        XCTAssertFalse(AppTypography.usesBundledFont("Outfit-ExtraBold", in: bundle))
        XCTAssertFalse(AppTypography.usesBundledFont("PlusJakartaSans-Regular", in: bundle))
        _ = AppTypography.pageTitle(in: bundle)
        _ = AppTypography.body(in: bundle)
    }

    func testBundledTypographyResourcesRegisterFromTheMacApplicationBundle() throws {
        XCTAssertEqual(AppTypography.expectedFileNames, [
            "Outfit-SemiBold.ttf",
            "Outfit-Bold.ttf",
            "Outfit-ExtraBold.ttf",
            "PlusJakartaSans-Regular.ttf",
            "PlusJakartaSans-Medium.ttf"
        ])
        XCTAssertEqual(AppTypography.expectedPostScriptNames, [
            "Outfit-SemiBold",
            "Outfit-Bold",
            "Outfit-ExtraBold",
            "PlusJakartaSans-Regular",
            "PlusJakartaSans-Medium"
        ])

        for fileName in AppTypography.expectedFileNames {
            let name = String(fileName.dropLast(4))
            XCTAssertNotNil(
                Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts")
                    ?? Bundle.main.url(forResource: name, withExtension: "ttf"),
                "macOS app bundle 缺少字体资源 \(fileName)"
            )
        }

        let report = AppTypography.registerBundledFonts(in: .main)
        XCTAssertTrue(report.missingFileNames.isEmpty, report.missingFileNames.joined(separator: ", "))
        XCTAssertTrue(report.registrationErrors.isEmpty, report.registrationErrors.joined(separator: "\n"))
        XCTAssertEqual(Set(report.availablePostScriptNames), Set(AppTypography.expectedPostScriptNames))
        XCTAssertTrue(report.allFontsAvailable)
        for name in AppTypography.expectedPostScriptNames {
            XCTAssertNotNil(NSFont(name: name, size: 14), "字体注册后必须能由 PostScript 名称解析：\(name)")
        }
    }
}
#endif
