import AppKit
import Combine
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

final class TerminalFontShortcutTests: XCTestCase {
    func testRecognizesFontShortcutsAndPlusAliases() throws {
        let cases: [(String, NSEvent.ModifierFlags, TerminalFontShortcut)] = [
            ("=", .command, .increase),
            ("+", .command, .increase),
            ("+", [.command, .shift], .increase),
            ("=", [.command, .shift], .increase),
            ("-", .command, .decrease),
            ("0", .command, .reset),
            ("+", [.command, .capsLock, .numericPad], .increase),
            ("-", [.command, .capsLock, .numericPad], .decrease),
            ("0", [.command, .capsLock, .numericPad], .reset)
        ]

        for (characters, modifiers, expected) in cases {
            let event = try keyEvent(characters, modifiers: modifiers)
            XCTAssertEqual(
                TerminalFontShortcut.resolve(event),
                expected,
                "Unexpected shortcut for \(characters) with flags \(modifiers.rawValue)"
            )
        }
    }

    func testLeavesShellInputAndOtherCommandCombinationsUnchanged() throws {
        let modifiers: [NSEvent.ModifierFlags] = [
            [], .shift, .control, .option,
            [.command, .control], [.command, .option],
            [.command, .shift, .control], [.command, .shift, .option]
        ]

        for characters in ["=", "+", "-", "0"] {
            for flags in modifiers {
                XCTAssertNil(
                    TerminalFontShortcut.resolve(
                        try keyEvent(characters, modifiers: flags)
                    ),
                    "Must preserve \(characters) with flags \(flags.rawValue)"
                )
            }
        }
        for characters in ["-", "0", "_", ")"] {
            XCTAssertNil(TerminalFontShortcut.resolve(
                try keyEvent(characters, modifiers: [.command, .shift])
            ))
        }
        for characters in ["c", "v", "t", "f", "1", "2", "3"] {
            XCTAssertNil(TerminalFontShortcut.resolve(
                try keyEvent(characters, modifiers: .command)
            ))
        }
    }

    func testKeyUpDoesNotRepeatFontAdjustment() throws {
        for characters in ["=", "+", "-", "0"] {
            XCTAssertNil(TerminalFontShortcut.resolve(
                try keyEvent(characters, modifiers: .command, type: .keyUp)
            ))
        }
    }

    private func keyEvent(
        _ characters: String,
        modifiers: NSEvent.ModifierFlags,
        type: NSEvent.EventType = .keyDown
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: 0
        ))
    }
}

@MainActor
final class TerminalAppearanceStoreTests: XCTestCase {
    func testAppearanceGridFitsAfterFontAndScrollbarChanges() throws {
        let controller = TerminalSessionController(
            server: ServerRecord(name: "Terminal Grid Test", host: "192.0.2.1", username: "test"),
            attachProcess: false
        )
        let host = controller.hostView
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        host.layoutSubtreeIfNeeded()
        let terminal = try XCTUnwrap(host.subviews.compactMap { $0 as? ServerDashTerminalView }.first)
        var profile = TerminalAppearanceProfile.default
        profile.scrollbarMode = .visible
        for size in [14.0, 16.0, 12.0] {
            profile.fontSize = size
            controller.applyAppearance(profile, dark: false)
            XCTAssertLessThanOrEqual(terminal.getOptimalFrameSize().width, terminal.frame.width,
                                     "Font changes must leave room for the scrollbar")
        }
        for mode in TerminalScrollbarMode.allCases {
            profile.scrollbarMode = mode
            controller.applyAppearance(profile, dark: false)
            XCTAssertLessThanOrEqual(terminal.getOptimalFrameSize().width, terminal.frame.width,
                                     "Scrollbar changes must keep the last column visible")
        }
    }

    func testNonMetricAppearanceChangesPreserveSelectionAndTerminalGrid() throws {
        let controller = TerminalSessionController(
            server: ServerRecord(name: "Appearance Update Test", host: "192.0.2.1", username: "test"),
            attachProcess: false
        )
        let host = controller.hostView
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        host.layoutSubtreeIfNeeded()
        var profile = TerminalAppearanceProfile.default
        controller.applyAppearance(profile, dark: false)
        let terminal = try XCTUnwrap(host.subviews.compactMap { $0 as? ServerDashTerminalView }.first)
        terminal.feed(text: "keep this selected text\r\n终端内容应保留\r\n")
        terminal.selectAll()
        let selection = try XCTUnwrap(terminal.getSelection())
        let rows = terminal.terminal.rows
        let columns = terminal.terminal.cols

        profile.darkThemeID = "midnight"
        profile.activeCursorStyle = .bar
        profile.inactiveCursorStyle = .hidden
        profile.cursorBlinkEnabled = false
        profile.terminalBellEnabled = false
        controller.applyAppearance(profile, dark: true)
        host.layout()

        XCTAssertEqual(terminal.getSelection(), selection)
        XCTAssertEqual(terminal.terminal.rows, rows)
        XCTAssertEqual(terminal.terminal.cols, columns)
        XCTAssertEqual(terminal.nativeBackgroundColor, TerminalThemeCatalog.shared.theme(id: "midnight", dark: true).background.nsColor)
        XCTAssertFalse(terminal.bellEnabled)
        if case .hidden = terminal.inactiveCursorStyle {} else {
            XCTFail("Inactive cursor style was not updated")
        }

        controller.applyAppearance(profile, dark: false)
        XCTAssertEqual(terminal.getSelection(), selection)
        XCTAssertEqual(terminal.nativeBackgroundColor, TerminalThemeCatalog.shared.theme(id: profile.lightThemeID, dark: false).background.nsColor)
    }

    func testUnchangedAppearanceDoesNotPublishSessionUpdates() {
        let controller = TerminalSessionController(
            server: ServerRecord(name: "Unchanged Appearance Test", host: "192.0.2.1", username: "test"),
            attachProcess: false
        )
        var profile = TerminalAppearanceProfile.default.validated()
        controller.applyAppearance(profile, dark: false)
        var updates = 0
        let subscription = controller.objectWillChange.sink { updates += 1 }
        defer { subscription.cancel() }

        controller.applyAppearance(profile, dark: false)
        controller.applyAppearance(profile, dark: true)
        XCTAssertEqual(updates, 0)

        profile.fontSize += 1
        controller.applyAppearance(profile, dark: true)
        XCTAssertEqual(updates, 1)
        XCTAssertEqual(controller.appearanceProfile.fontSize, profile.fontSize)
    }

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

    func testFontShortcutsUpdateOnlyCurrentSessionAndPreserveAppearance() throws {
        let server = ServerRecord(
            name: "Font Shortcut Test",
            host: "127.0.0.1",
            username: "root"
        )
        let first = TerminalSessionController(server: server, attachProcess: false)
        let second = TerminalSessionController(server: server, attachProcess: false)
        let secondInitial = second.appearanceProfile
        let globalInitial = TerminalAppearanceStore.shared.profile
        var appearance = first.appearanceProfile
        appearance.fontSize = 20
        appearance.darkThemeID = "midnight"
        appearance.lineHeight = 1.5
        first.applyAppearance(appearance, dark: true)
        let terminal = try XCTUnwrap(
            first.hostView.subviews.compactMap { $0 as? ServerDashTerminalView }.first
        )
        let initialBackground = terminal.nativeBackgroundColor

        first.performFontShortcut(.increase)

        appearance.fontSize = 21
        XCTAssertEqual(first.appearanceProfile, appearance)
        XCTAssertEqual(terminal.font.pointSize, 21)
        XCTAssertEqual(terminal.nativeBackgroundColor, initialBackground)

        first.performFontShortcut(.decrease)

        appearance.fontSize = 20
        XCTAssertEqual(first.appearanceProfile, appearance)
        XCTAssertEqual(terminal.font.pointSize, 20)
        XCTAssertEqual(second.appearanceProfile, secondInitial)
        XCTAssertEqual(TerminalAppearanceStore.shared.profile, globalInitial)
    }

    func testFontShortcutsRespectBoundsAndResetToSessionInitialSize() {
        let controller = TerminalSessionController(
            server: ServerRecord(
                name: "Font Bounds Test",
                host: "127.0.0.1",
                username: "root"
            ),
            attachProcess: false
        )
        let initialSize = controller.appearanceProfile.fontSize
        var appearance = controller.appearanceProfile
        appearance.fontSize = 48
        appearance.lineHeight = 1.5
        controller.applyAppearance(appearance, dark: false)

        controller.performFontShortcut(.increase)
        XCTAssertEqual(controller.appearanceProfile.fontSize, 48)

        appearance.fontSize = 8
        controller.applyAppearance(appearance, dark: false)
        controller.performFontShortcut(.decrease)
        XCTAssertEqual(controller.appearanceProfile.fontSize, 8)

        controller.performFontShortcut(.reset)
        appearance.fontSize = initialSize
        XCTAssertEqual(controller.appearanceProfile, appearance)
    }

    func testNativeFontShortcutOnlyRunsForFocusedTerminalInActiveWindow() throws {
        let frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        let window = TerminalShortcutTestWindow(
            contentRect: frame,
            styleMask: .titled,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            window.makeFirstResponder(nil)
            window.close()
        }
        let content = NSView(frame: frame)
        let terminal = ServerDashTerminalView(frame: frame)
        // NSTextField search controls hand keyboard focus to an NSTextView field editor.
        let fieldEditor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        fieldEditor.isFieldEditor = true
        content.addSubview(terminal)
        content.addSubview(fieldEditor)
        window.contentView = content
        var received: [TerminalFontShortcut] = []
        terminal.onFontShortcut = { received.append($0) }
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "=",
            charactersIgnoringModifiers: "=",
            isARepeat: false,
            keyCode: 24
        ))

        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(window.makeFirstResponder(terminal))
        XCTAssertTrue(window.firstResponder === terminal)
        XCTAssertTrue(terminal.performKeyEquivalent(with: event))
        XCTAssertEqual(received, [.increase])

        XCTAssertTrue(window.makeFirstResponder(fieldEditor))
        XCTAssertTrue(window.firstResponder === fieldEditor)
        XCTAssertFalse(terminal.performKeyEquivalent(with: event))
        XCTAssertEqual(received, [.increase])

        XCTAssertTrue(window.makeFirstResponder(terminal))
        window.reportsKeyWindow = false
        XCTAssertFalse(terminal.performKeyEquivalent(with: event))
        XCTAssertEqual(received, [.increase])
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

private final class TerminalShortcutTestWindow: NSWindow {
    var reportsKeyWindow = true

    override var isKeyWindow: Bool { reportsKeyWindow }
}
