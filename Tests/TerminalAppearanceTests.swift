import AppKit
import XCTest
@testable import ServerDash

final class TerminalThemeCatalogTests: XCTestCase {
    func testBuiltInThemesAreUniqueAndComplete() {
        let themes = TerminalThemeCatalog.shared.themes

        XCTAssertEqual(themes.count, 20)
        XCTAssertEqual(Set(themes.map(\.id)).count, themes.count)
        XCTAssertTrue(themes.allSatisfy { $0.ansiColors.count == 16 })
        XCTAssertEqual(themes.filter(\.isDark).count, 10)
        XCTAssertEqual(themes.filter { !$0.isDark }.count, 10)
    }

    func testDefaultThemesExistAndHaveReadableContrast() {
        let light = TerminalThemeCatalog.shared.theme(
            id: "serverdash-light",
            dark: false
        )
        let dark = TerminalThemeCatalog.shared.theme(
            id: "serverdash-dark",
            dark: true
        )

        XCTAssertEqual(light.id, "serverdash-light")
        XCTAssertEqual(dark.id, "serverdash-dark")
        XCTAssertGreaterThanOrEqual(light.contrastRatio, 4.5)
        XCTAssertGreaterThanOrEqual(dark.contrastRatio, 4.5)
    }

    func testThemeSearchIsCaseInsensitive() {
        XCTAssertEqual(
            TerminalThemeCatalog.shared.filtered("OCEAN").map(\.id),
            ["ocean"]
        )
        XCTAssertTrue(
            TerminalThemeCatalog.shared.filtered("missing-theme").isEmpty
        )
    }
}

final class TerminalAppearanceProfileTests: XCTestCase {
    func testProfileRoundTripAndValidation() throws {
        var profile = TerminalAppearanceProfile.default
        profile.lightThemeID = "missing-light"
        profile.darkThemeID = "missing-dark"
        profile.fontPostScriptName = "Definitely Missing Font"
        profile.fontSize = 100
        profile.lineHeight = 0.2
        profile.letterSpacing = 9

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(
            TerminalAppearanceProfile.self,
            from: data
        )
        let validated = decoded.validated()

        XCTAssertEqual(validated.lightThemeID, "serverdash-light")
        XCTAssertEqual(validated.darkThemeID, "serverdash-dark")
        XCTAssertEqual(validated.fontSize, 48)
        XCTAssertEqual(validated.lineHeight, 1)
        XCTAssertEqual(validated.letterSpacing, 3)
        XCTAssertNotEqual(
            validated.fontPostScriptName,
            "Definitely Missing Font"
        )
    }

    func testDefaultUsesMenloWhenAvailable() {
        let resolved = TerminalFontCatalog.resolvedPostScriptName("Menlo-Regular")
        XCTAssertFalse(resolved.isEmpty)
        XCTAssertTrue(TerminalFontCatalog.isMonospaced(
            TerminalFontCatalog.font(name: resolved, size: 13)
        ))
    }
}

@MainActor
final class TerminalAppearanceStoreTests: XCTestCase {
    func testLegacyFontSettingsMigrateOnce() {
        let suiteName = "TerminalAppearanceStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("Menlo-Regular", forKey: "terminalFontName")
        defaults.set(18.0, forKey: "terminalFontSize")

        let store = TerminalAppearanceStore(defaults: defaults)

        XCTAssertEqual(store.profile.fontSize, 18)
        XCTAssertFalse(store.profile.fontPostScriptName.isEmpty)
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testSessionAppearanceOverridesAreIsolated() {
        let server = ServerRecord(
            name: "Appearance Test",
            host: "127.0.0.1",
            username: "root"
        )
        let first = TerminalSessionController(
            server: server,
            attachProcess: false
        )
        let second = TerminalSessionController(
            server: server,
            attachProcess: false
        )
        let secondInitial = second.appearanceProfile
        var changed = first.appearanceProfile
        changed.fontSize = min(48, changed.fontSize + 4)
        changed.darkThemeID = "midnight"

        first.applyAppearance(changed, dark: true)

        XCTAssertEqual(first.appearanceProfile.fontSize, changed.fontSize)
        XCTAssertEqual(first.appearanceProfile.darkThemeID, "midnight")
        XCTAssertEqual(second.appearanceProfile, secondInitial)
    }

    func testVendoredSwiftTermTextMetricsAndControls() {
        let view = ServerDashTerminalView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 500)
        )
        view.font = TerminalFontCatalog.font(
            name: "Menlo-Regular",
            size: 13
        )
        let originalRows = view.terminal.rows
        let originalColumns = view.terminal.cols

        view.lineHeightMultiplier = 1.5
        let rowsWithSpacing = view.terminal.rows
        view.characterSpacing = 2
        let columnsWithSpacing = view.terminal.cols
        view.scrollbarVisibility = .hidden
        view.inactiveCursorStyle = .hidden
        view.bellEnabled = false

        XCTAssertLessThan(rowsWithSpacing, originalRows)
        XCTAssertLessThan(columnsWithSpacing, originalColumns)
        XCTAssertFalse(view.bellEnabled)
        if case .hidden = view.inactiveCursorStyle {
            // Expected.
        } else {
            XCTFail("Inactive cursor style was not applied")
        }
    }
}
