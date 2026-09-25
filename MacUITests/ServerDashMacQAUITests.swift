import XCTest

@MainActor
final class ServerDashMacQAUITests: XCTestCase {
    private struct FixtureScenario {
        let page: String
        let arguments: [String]

        init(_ page: String, _ arguments: [String] = []) {
            self.page = page
            self.arguments = arguments
        }
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testDashboardRefreshIsAvailableAtMinimumWindowSize() {
        let app = launch(page: "dashboard")
        defer { app.terminate() }
        assertWindow(in: app, minimumWidth: 895, minimumHeight: 615)

        let refresh = app.buttons["dashboard.refresh.all"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 10), "The dashboard refresh action must remain visible at 900×620.")
        XCTAssertTrue(refresh.isEnabled)
        refresh.click()
        XCTAssertTrue(refresh.exists)
    }

    func testMachinesRouteStartsInIsolatedQAApplication() {
        let app = launch(page: "machines")
        defer { app.terminate() }
        assertWindow(in: app, minimumWidth: 895, minimumHeight: 615)

        let newMachine = app.buttons["machines.toolbar.new"]
        let machineOverflow = app.buttons["machines.toolbar.more"]
        XCTAssertTrue(
            newMachine.waitForExistence(timeout: 10) || machineOverflow.waitForExistence(timeout: 2),
            "The machines route should expose its native toolbar controls."
        )
    }

    func testMachineSelectionSurvivesNativeSidebarNavigation() {
        let app = launch(
            page: "machines", width: 1440, height: 900,
            extraArguments: ["--fixture-machine-view", "list"]
        )
        defer { app.terminate() }
        let table = app.descendants(matching: .any)["machines.browser.table"]
        let summary = app.descendants(matching: .any)["machines.selection.summary"]
        XCTAssertTrue(table.waitForExistence(timeout: 10))
        let firstHost = table.descendants(matching: .tableRow)
            .matching(NSPredicate(format: "label CONTAINS %@", "192.0.2.10:22"))
            .firstMatch
        XCTAssertTrue(firstHost.waitForExistence(timeout: 5))
        firstHost.click()
        XCTAssertTrue(firstHost.isSelected)
        XCTAssertTrue(waitForLabel("已选 1 台", on: summary, timeout: 5))

        let dashboard = app.descendants(matching: .any)["sidebar.dashboard"]
        XCTAssertTrue(dashboard.waitForExistence(timeout: 5))
        dashboard.click()
        XCTAssertTrue(app.buttons["dashboard.refresh.all"].waitForExistence(timeout: 5))

        let machines = app.descendants(matching: .any)["sidebar.machines"]
        XCTAssertTrue(machines.waitForExistence(timeout: 5))
        machines.click()
        XCTAssertTrue(table.waitForExistence(timeout: 5))
        XCTAssertTrue(firstHost.waitForExistence(timeout: 5))
        XCTAssertTrue(firstHost.isSelected, "The same native Table row must remain selected after a sidebar round trip.")
        XCTAssertTrue(waitForLabel("已选 1 台", on: summary, timeout: 5))
    }

    func testSFTPRouteMountsOfflineBrowserAtCompactAndRegularWidths() {
        for theme in ["light", "dark"] {
            for width in [900, 1440] {
                let app = launch(page: "sftp", width: width, height: width == 900 ? 620 : 900, theme: theme)
                assertFixturePage("sftp", in: app)
                XCTAssertTrue(app.descendants(matching: .any)["sftp.browser.table"].waitForExistence(timeout: 10))
                XCTAssertTrue(app.descendants(matching: .any)["sftp.browser.path"].exists)
                XCTAssertTrue(app.descendants(matching: .any)["sftp.browser.search"].exists)
                XCTAssertTrue(app.buttons["sftp.browser.refresh"].exists)
                XCTAssertTrue(app.descendants(matching: .any)["sftp.browser.more"].exists)
                let fixtureFile = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label CONTAINS %@", "上海生产环境核心数据库配置文件.yaml"))
                    .firstMatch
                XCTAssertTrue(fixtureFile.exists)
                app.terminate()
            }
        }
    }

    func testSFTPSelectionAndScrollAnchorSurviveRealWindowResize() {
        let app = launch(
            page: "sftp", width: 1440, height: 900,
            extraArguments: [
                "--fixture-sftp-select-index", "15",
                "--fixture-resize-width", "900",
                "--fixture-resize-height", "620",
            ]
        )
        defer { app.terminate() }
        let browserState = app.descendants(matching: .any)["macqa.sftp.browserState"]
        XCTAssertTrue(browserState.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForWindowWidth(below: 1_000, in: app, timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["sftp.browser.table"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["sftp.browser.path"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["sftp.browser.search"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["sftp.browser.more"].exists)
        let value = browserState.value as? String ?? ""
        let initialSelection = fixtureState("初始已选", from: value)
        let currentSelection = fixtureState("当前已选", from: value)
        let initialAnchor = fixtureState("初始滚动锚点", from: value)
        let currentAnchor = fixtureState("当前滚动锚点", from: value)
        XCTAssertEqual(initialSelection, "应用配置-15.txt", "The fixture must select the intended row: \(value)")
        XCTAssertEqual(currentSelection, initialSelection, "Resizing must preserve the selected file: \(value)")
        XCTAssertNotNil(initialAnchor)
        XCTAssertNotEqual(initialAnchor, "无")
        XCTAssertEqual(currentAnchor, initialAnchor, "Resizing must preserve the same row anchor: \(value)")
        let selectedRow = app.staticTexts["应用配置-15.txt"].firstMatch
        XCTAssertTrue(selectedRow.waitForExistence(timeout: 5))
        XCTAssertTrue(
            waitForHittable(selectedRow, timeout: 5),
            "The selected row must remain visible in the native table after the window shrinks."
        )
    }

    func testTerminalAndShortcutSettingsUseResponsiveNativeForms() {
        for theme in ["light", "dark"] {
            for width in [900, 1440] {
                let height = width == 900 ? 620 : 900
                let terminal = launch(
                    page: "settings", width: width, height: height, theme: theme,
                    extraArguments: ["--fixture-settings-page", "terminal"]
                )
                assertFixturePage("settings", in: terminal)
                XCTAssertTrue(terminal.descendants(matching: .any)["mac.settings.terminal.editor"].waitForExistence(timeout: 10))
                if width == 900 {
                    XCTAssertTrue(terminal.descendants(matching: .any)["mac.settings.terminal.previewDisclosure"].exists)
                } else {
                    XCTAssertTrue(terminal.descendants(matching: .any)["mac.settings.terminal.preview"].exists)
                }
                terminal.terminate()

                let shortcuts = launch(
                    page: "settings", width: width, height: height, theme: theme,
                    extraArguments: ["--fixture-settings-page", "shortcuts"]
                )
                assertFixturePage("settings", in: shortcuts)
                XCTAssertTrue(shortcuts.descendants(matching: .any)["mac.settings.shortcuts.search"].waitForExistence(timeout: 10))
                shortcuts.terminate()
            }
        }
    }

    func testTerminalSettingsPreviewAndShellDraftValidationAtMinimumWindow() {
        let app = launch(page: "settings", extraArguments: ["--fixture-settings-page", "terminal"])
        defer { app.terminate() }
        let disclosure = app.descendants(matching: .any)["mac.settings.terminal.previewDisclosure"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 10))
        disclosure.click()
        XCTAssertTrue(waitForNonExistence(app.descendants(matching: .any)["mac.settings.terminal.preview"]))
        disclosure.click()
        XCTAssertTrue(app.descendants(matching: .any)["mac.settings.terminal.preview"].waitForExistence(timeout: 5))

        let path = app.textFields["mac.settings.terminal.shellPath"]
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        path.click()
        path.typeText("relative/shell")
        XCTAssertFalse(app.buttons["mac.settings.terminal.shellSave"].isEnabled)
        XCTAssertTrue(app.descendants(matching: .any)["mac.settings.terminal.shellError"].waitForExistence(timeout: 5))
        app.buttons["mac.settings.terminal.shellCancel"].click()
        XCTAssertFalse((path.value as? String ?? "").contains("relative/shell"), "Cancel must restore the effective Shell path.")
    }

    func testAllSettingsCategoriesOpenFromIsolatedLaunchArguments() {
        let categories: [(id: String, expectedContent: String)] = [
            ("general", "显示模式"),
            ("terminal", "Shell 路径"),
            ("monitoring", "自动刷新"),
            ("files", "默认下载目录"),
            ("shortcuts", "查找快捷键"),
            ("security", "主机密钥验证"),
            ("sync", "启用配置同步"),
            ("recording", "选择目录"),
            ("ai", "提供商"),
        ]
        for category in categories {
            let app = launch(page: "settings", extraArguments: ["--fixture-settings-page", category.id])
            assertFixturePage("settings", in: app)
            XCTAssertTrue(
                app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label CONTAINS %@", category.expectedContent))
                    .firstMatch.waitForExistence(timeout: 5),
                "Settings category \(category.id) should render its own native form content."
            )
            app.terminate()
        }
    }

    func testCoreRoutesFitMinimumWindowInLightAndDarkAppearances() {
        let scenarios = [
            FixtureScenario("dashboard"),
            FixtureScenario("machines"),
            FixtureScenario("machines", ["--fixture-machine-view", "list"]),
            FixtureScenario("terminal", ["--fixture-panes", "1"]),
            FixtureScenario("terminal", ["--fixture-panes", "4"]),
            FixtureScenario("sftp"),
            FixtureScenario("editor"),
            FixtureScenario("settings"),
        ]

        for theme in ["light", "dark"] {
            for scenario in scenarios {
                let app = launch(page: scenario.page, theme: theme, extraArguments: scenario.arguments)
                assertFixturePage(scenario.page, in: app)
                assertWindow(in: app, minimumWidth: 895, minimumHeight: 615)
                if scenario.page == "terminal" {
                    XCTAssertTrue(app.descendants(matching: .any)["terminal.workspace"].waitForExistence(timeout: 10))
                }
                app.terminate()
            }
        }
    }

    func testMajorRoutesStartAtRegularWindowSizeInLightAndDarkAppearances() {
        let scenarios = [
            FixtureScenario("recordings"),
            FixtureScenario("identities"),
            FixtureScenario("ssh-keys"),
            FixtureScenario("snippets"),
            FixtureScenario("trusted-hosts"),
            FixtureScenario("connections"),
            FixtureScenario("monitor"),
            FixtureScenario("sftp"),
            FixtureScenario("rdp"),
            FixtureScenario("settings"),
            FixtureScenario("ai"),
            FixtureScenario("editor"),
            FixtureScenario("import-export"),
            FixtureScenario("import-export", ["--fixture-transfer-mode", "export"]),
            FixtureScenario("connection-editor", ["--fixture-connection-editor", "ssh"]),
            FixtureScenario("empty"),
            FixtureScenario("error"),
        ]

        for theme in ["light", "dark"] {
            for scenario in scenarios {
                let app = launch(
                    page: scenario.page,
                    width: 1440,
                    height: 900,
                    theme: theme,
                    extraArguments: scenario.arguments
                )
                assertFixturePage(scenario.page, in: app)
                assertWindow(in: app, minimumWidth: 1435, minimumHeight: 895)
                app.terminate()
            }
        }
    }

    func testWideMachinesAndSixteenPaneTerminalRoutes() {
        for theme in ["light", "dark"] {
            let machines = launch(page: "machines", width: 1920, height: 1080, theme: theme)
            assertFixturePage("machines", in: machines)
            assertWindow(in: machines, minimumWidth: 1915, minimumHeight: 1075)
            XCTAssertTrue(machines.buttons["machines.toolbar.new"].waitForExistence(timeout: 10))
            machines.terminate()

            let terminal = launch(
                page: "terminal",
                width: 1920,
                height: 1080,
                theme: theme,
                extraArguments: ["--fixture-panes", "16"]
            )
            assertFixturePage("terminal", in: terminal)
            assertWindow(in: terminal, minimumWidth: 1915, minimumHeight: 1075)
            XCTAssertTrue(terminal.descendants(matching: .any)["terminal.workspace"].waitForExistence(timeout: 10))
            terminal.terminate()
        }
    }

    func testAccessibilityAppearanceOverridesStartInIsolatedWindows() {
        for flag in [
            "--fixture-reduce-motion",
            "--fixture-reduce-transparency",
            "--fixture-increase-contrast",
        ] {
            let app = launch(page: "dashboard", width: 1440, height: 900, extraArguments: [flag])
            assertFixturePage("dashboard", in: app)
            XCTAssertTrue(app.buttons["dashboard.refresh.all"].waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    func testConnectionEditorsUseRealSheetsAndFitMinimumWindow() {
        let scenarios: [(kind: String, identifier: String, action: String, field: String?, expectsCancel: Bool)] = [
            ("ssh", "mac.editor.server", "mac.editor.server.save", "mac.editor.server.host", true),
            ("rdp", "mac.editor.rdp", "mac.editor.rdp.save", "mac.editor.rdp.host", true),
            ("vnc", "mac.editor.vnc", "mac.editor.vnc.save", "mac.editor.vnc.host", true),
            ("serial", "mac.editor.serial", "mac.editor.serial.save", "mac.editor.serial.device", true),
            ("identity", "mac.editor.identity", "mac.editor.identity.save", "mac.editor.identity.username", true),
            ("key", "mac.editor.ssh-key", "mac.editor.ssh-key.save", "mac.editor.ssh-key.file", true),
            ("snippet", "mac.editor.snippet", "mac.editor.snippet.save", "mac.editor.snippet.command", true),
            ("route", "mac.editor.route", "mac.editor.route.save", "mac.editor.route.alias", false),
            ("tunnel", "mac.editor.tunnel", "mac.editor.tunnel.save", nil, true),
        ]

        for scenario in scenarios {
            let app = launch(page: "connection-editor", extraArguments: ["--fixture-connection-editor", scenario.kind])
            assertFixturePage("connection-editor", in: app)
            assertSheet(
                scenario.identifier,
                titleIdentifier: "\(scenario.identifier).title",
                actionIdentifier: scenario.action,
                in: app
            )
            if let field = scenario.field {
                XCTAssertTrue(
                    app.descendants(matching: .any)[field].waitForExistence(timeout: 5),
                    "\(scenario.kind) should render a real editable field inside the sheet."
                )
            }
            if scenario.expectsCancel {
                XCTAssertTrue(
                    app.buttons["\(scenario.identifier).cancel"].waitForExistence(timeout: 5),
                    "\(scenario.kind) should expose the native cancellation action."
                )
            } else {
                XCTAssertFalse(
                    app.buttons["\(scenario.identifier).cancel"].exists,
                    "\(scenario.kind) saves immediately and must not advertise a false cancellation action."
                )
            }
            app.terminate()
        }
    }

    func testEditorAndImportExportRoutesUseRealSheetsAtMinimumSize() {
        let scenarios: [(page: String, arguments: [String], identifier: String, title: String, action: String)] = [
            ("editor", [], "mac.remote-editor", "mac.remote-editor.title", "mac.remote-editor.done"),
            ("import-export", [], "mac.import", "mac.import.title", "mac.import.primary"),
            ("import-export", ["--fixture-transfer-mode", "export"], "mac.export", "mac.export.title", "mac.export.primary"),
        ]

        for scenario in scenarios {
            let app = launch(page: scenario.page, extraArguments: scenario.arguments)
            assertFixturePage(scenario.page, in: app)
            assertSheet(
                scenario.identifier,
                titleIdentifier: scenario.title,
                actionIdentifier: scenario.action,
                in: app
            )
            app.terminate()
        }
    }

    func testBatchAndRecordingConfigurationUseOfflineNativeSheetsAtMinimumSize() {
        let scenarios: [(page: String, identifier: String, action: String, field: String)] = [
            ("batch-execution", "mac.batch-execution", "mac.batch-execution.save", "mac.batch-execution.command"),
            ("recording-config", "mac.recording-config", "mac.recording-config.save", "mac.recording-config.start"),
        ]

        for theme in ["light", "dark"] {
            for scenario in scenarios {
                let app = launch(page: scenario.page, theme: theme)
                assertFixturePage(scenario.page, in: app)
                assertWindow(in: app, minimumWidth: 895, minimumHeight: 615)
                assertSheet(
                    scenario.identifier,
                    titleIdentifier: "\(scenario.identifier).title",
                    actionIdentifier: scenario.action,
                    in: app
                )
                XCTAssertTrue(
                    app.descendants(matching: .any)[scenario.field].waitForExistence(timeout: 5),
                    "\(scenario.page) should expose a stable editable field inside its native sheet."
                )
                XCTAssertTrue(app.buttons["\(scenario.identifier).cancel"].waitForExistence(timeout: 5))
                app.terminate()
            }
        }
    }

    func testWorkbenchKeyboardShortcutsUseTheFocusedNativeActions() {
        let app = launch(page: "dashboard")
        defer { app.terminate() }
        let refresh = app.buttons["dashboard.refresh.all"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 10))

        app.typeKey("r", modifierFlags: .command)
        XCTAssertTrue(refresh.waitForExistence(timeout: 5), "⌘R must leave the focused dashboard refresh action available.")
        app.typeKey("r", modifierFlags: [.command, .shift])
        XCTAssertTrue(refresh.waitForExistence(timeout: 5), "⌘⇧R must run the focused failed-monitor retry action.")

        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(
            app.descendants(matching: .any)["mac.editor.server.container"].waitForExistence(timeout: 10),
            "⌘N should open the native server editor for the focused workbench."
        )
        XCTAssertTrue(app.buttons["mac.editor.server.cancel"].waitForExistence(timeout: 5))
    }

    func testRemoteEditorKeyboardSearchEscapeAndCloseDocument() {
        let app = launch(page: "editor")
        defer { app.terminate() }
        assertSheet(
            "mac.remote-editor",
            titleIdentifier: "mac.remote-editor.title",
            actionIdentifier: "mac.remote-editor.done",
            in: app
        )

        app.typeKey("f", modifierFlags: .command)
        let search = app.textFields["mac.remote-editor.search.field"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), "⌘F should reveal and focus the document search field.")
        app.typeText("monitoring")
        XCTAssertEqual(search.value as? String, "monitoring", "⌘F should move keyboard focus into search.")

        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(waitForNonExistence(search), "Escape should close only the editor search bar.")
        XCTAssertTrue(app.descendants(matching: .any)["mac.remote-editor.container"].exists)

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(
            app.staticTexts["未打开文件"].waitForExistence(timeout: 5),
            "⌘W should close the current clean document while leaving the editor sheet open."
        )
    }

    func testRemoteEditorLongTabsAndSearchFeedback() {
        let app = launch(page: "editor", extraArguments: ["--fixture-editor-documents", "5"])
        defer { app.terminate() }
        assertSheet(
            "mac.remote-editor",
            titleIdentifier: "mac.remote-editor.title",
            actionIdentifier: "mac.remote-editor.done",
            in: app
        )
        let tabs = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "mac.remote-editor.tab."))
        XCTAssertEqual(tabs.count, 5)
        let selectedTab = tabs.matching(NSPredicate(format: "value == %@", "已选择")).firstMatch
        XCTAssertTrue(selectedTab.exists)
        XCTAssertTrue(selectedTab.label.contains("多标签工作区-第05份"), "The full long document name should remain available to accessibility.")
        XCTAssertTrue(waitForHittable(selectedTab, timeout: 5), "The selected long document tab should scroll into view.")

        app.typeKey("f", modifierFlags: .command)
        let search = app.textFields["mac.remote-editor.search.field"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("monitoring")
        let feedback = app.descendants(matching: .any)["mac.remote-editor.search.result"]
        XCTAssertTrue(feedback.waitForExistence(timeout: 5))
        XCTAssertTrue((feedback.label).contains("处"), "A matching query should show its position or count.")
        search.click()
        search.typeKey("a", modifierFlags: .command)
        search.typeText("missing-qa-token")
        XCTAssertTrue(waitForLabel("无匹配", on: feedback, timeout: 5))
    }

    func testTerminalInspectorKeyboardShortcutTogglesInspector() {
        let app = launch(page: "terminal", extraArguments: ["--fixture-panes", "1"])
        defer { app.terminate() }
        XCTAssertTrue(app.descendants(matching: .any)["terminal.workspace"].waitForExistence(timeout: 10))

        app.typeKey("i", modifierFlags: [.command, .option])
        let inspectorRefresh = app.buttons["terminal.inspector.refresh"]
        XCTAssertTrue(inspectorRefresh.waitForExistence(timeout: 10), "⌘⌥I should show the terminal inspector.")
        app.typeKey("i", modifierFlags: [.command, .option])
        XCTAssertTrue(waitForNonExistence(inspectorRefresh), "A second ⌘⌥I should hide the terminal inspector.")
    }

    func testErrorRouteUsesNativeAlert() {
        let app = launch(page: "error")
        defer { app.terminate() }
        assertFixturePage("error", in: app)
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "The error fixture should present a native alert.")
        XCTAssertTrue(app.buttons["macqa.error.retry"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["macqa.error.cancel"].exists)
    }

    private func launch(
        page: String,
        width: Int = 900,
        height: Int = 620,
        theme: String = "light",
        extraArguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--fixture-page", page,
            "--fixture-width", String(width),
            "--fixture-height", String(height),
            "--fixture-hosts", "8",
            "--fixture-theme", theme,
        ] + extraArguments
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "The QA application should open a real macOS window.")
        return app
    }

    private func assertFixturePage(_ page: String, in app: XCUIApplication) {
        if page == "sftp" {
            XCTAssertTrue(app.descendants(matching: .any)["sftp.browser.table"].waitForExistence(timeout: 10))
            return
        }
        if page == "settings" {
            let terminalCategory = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", "终端"))
                .firstMatch
            XCTAssertTrue(terminalCategory.waitForExistence(timeout: 10))
            return
        }
        XCTAssertTrue(
            app.descendants(matching: .any)["macqa.page.\(page)"].waitForExistence(timeout: 10),
            "The isolated QA route \(page) should render its native content."
        )
    }

    private func assertWindow(in app: XCUIApplication, minimumWidth: CGFloat, minimumHeight: CGFloat) {
        let frame = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(frame.width, minimumWidth)
        XCTAssertGreaterThanOrEqual(frame.height, minimumHeight)
    }

    private func waitForNonExistence(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForWindowWidth(below width: CGFloat, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.windows.firstMatch.frame.width < width { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.isHittable { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    private func fixtureState(_ key: String, from rawValue: String) -> String? {
        let prefix = "\(key)："
        return rawValue.split(separator: "；")
            .first(where: { $0.hasPrefix(prefix) })
            .map { String($0.dropFirst(prefix.count)) }
    }

    private func waitForLabel(_ value: String, on element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", value),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func assertSheet(
        _ identifier: String,
        titleIdentifier: String,
        actionIdentifier: String,
        in app: XCUIApplication
    ) {
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "\(identifier) should be presented as a native sheet.")
        let container = app.descendants(matching: .any)["\(identifier).container"]
        XCTAssertTrue(container.waitForExistence(timeout: 5), "The sheet should expose its stable container identifier.")
        XCTAssertTrue(app.descendants(matching: .any)[titleIdentifier].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons[actionIdentifier].waitForExistence(timeout: 5))

        let windowFrame = app.windows.firstMatch.frame
        let sheetFrame = sheet.frame
        XCTAssertLessThanOrEqual(sheetFrame.width, windowFrame.width + 2, "The sheet must fit within the window width.")
        XCTAssertLessThanOrEqual(sheetFrame.height, windowFrame.height + 2, "The sheet must fit within the window height.")
        XCTAssertGreaterThanOrEqual(sheetFrame.minX, windowFrame.minX - 2)
        XCTAssertGreaterThanOrEqual(sheetFrame.minY, windowFrame.minY - 2)
        XCTAssertLessThanOrEqual(sheetFrame.maxX, windowFrame.maxX + 2)
        XCTAssertLessThanOrEqual(sheetFrame.maxY, windowFrame.maxY + 2)
    }
}
