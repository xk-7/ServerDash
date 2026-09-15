import XCTest

@MainActor
final class ServerDashGlassUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testDashboardWindowMatrix() {
        captureMatrix(page: "dashboard", sizes: standardSizes)
    }

    func testMachineGridWindowMatrix() {
        captureMatrix(page: "machines-grid", sizes: standardSizes)
    }

    func testMachineListWindowMatrix() {
        captureMatrix(page: "machines-list", sizes: standardSizes)
    }

    func testCorePagesAtReferenceSize() {
        for page in ["monitor", "terminal", "sftp", "rdp", "settings", "empty", "dialog"] {
            captureMatrix(page: page, sizes: [(1440, 900)])
        }
    }

    func testAccessibilityAppearanceOverrides() {
        let variants: [(name: String, flag: String)] = [
            ("reduce-transparency", "--fixture-reduce-transparency"),
            ("reduce-motion", "--fixture-reduce-motion"),
            ("increase-contrast", "--fixture-increase-contrast")
        ]
        for variant in variants {
            capture(
                page: "dashboard",
                theme: "dark",
                width: 1440,
                height: 900,
                flags: [variant.flag],
                artifactSuffix: variant.name
            )
        }
    }

    func testDashboardRefreshActionsRemainReachable() {
        withLaunchedApp(page: "dashboard", theme: "light", width: 1440, height: 900) { app, _ in
            let refresh = app.buttons["dashboard.refresh.all"]
            let options = app.menuButtons["dashboard.refresh.options"]
            let invocationCount = app.staticTexts["dashboard.refresh.invocations"]
            XCTAssertTrue(refresh.waitForExistence(timeout: 8), "仪表盘必须保留刷新全部入口")
            XCTAssertTrue(options.waitForExistence(timeout: 3), "仪表盘必须保留更多刷新入口")
            XCTAssertTrue(invocationCount.waitForExistence(timeout: 3))
            XCTAssertEqual(accessibilityValue(of: invocationCount), "0")
            refresh.click()
            waitForValue("1", on: invocationCount, timeout: 5)
            options.click()
            // The same command is also exposed from the app menu bar. Scope the
            // query to the dashboard menu so XCTest does not see two matches.
            let retryFailed = options.menuItems["仅重试失败的监控"]
            XCTAssertTrue(
                retryFailed.waitForExistence(timeout: 3),
                "失败项刷新必须从更多菜单可达"
            )
            retryFailed.click()
            waitForValue("2", on: invocationCount, timeout: 5)
            app.typeKey("r", modifierFlags: .command)
            waitForValue("3", on: invocationCount, timeout: 5)
        }
    }

    func testSettingsEntriesStayInTheControlledFixtureWindow() {
        withLaunchedApp(page: "dashboard", theme: "light", width: 1440, height: 900) { app, _ in
            let settings = app.buttons["sidebar.settings"]
            let settingsRoot = app.descendants(matching: .any)["macqa.settings.root"]
            XCTAssertTrue(settings.waitForExistence(timeout: 8))
            settings.click()
            XCTAssertTrue(settingsRoot.waitForExistence(timeout: 5))
            XCTAssertEqual(app.windows.count, 1, "侧栏设置必须复用隔离 QA 窗口")

            let back = app.buttons["macqa.settings.back"]
            XCTAssertTrue(back.waitForExistence(timeout: 3))
            back.click()
            XCTAssertTrue(settingsRoot.waitForNonExistence(timeout: 5))
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            app.activate()
            waitForRendering()
            let applicationMenu = app.menuBars.menuBarItems["ServerDash Mac QA"]
            XCTAssertTrue(applicationMenu.waitForExistence(timeout: 3))
            applicationMenu.click()
            let settingsMenuItem = applicationMenu.menuItems["设置…"]
            XCTAssertTrue(settingsMenuItem.waitForExistence(timeout: 3))
            settingsMenuItem.click()
            XCTAssertTrue(settingsRoot.waitForExistence(timeout: 5))
            XCTAssertEqual(app.windows.count, 1, "系统设置菜单必须复用隔离 QA 窗口")
        }
    }

    func testSFTPFixtureUsesStableOfflineRows() {
        withLaunchedApp(page: "sftp", theme: "light", width: 1440, height: 900) { app, _ in
            XCTAssertTrue(
                app.staticTexts["隔离目录 · 未建立网络连接"].waitForExistence(timeout: 8),
                "SFTP 隔离夹具必须直接呈现稳定的离线目录"
            )
            XCTAssertTrue(
                app.staticTexts["部署说明-生产环境.md"].waitForExistence(timeout: 3),
                "SFTP 隔离夹具必须呈现合成文件行"
            )
            XCTAssertFalse(app.staticTexts["无法读取目录"].exists)
            XCTAssertFalse(
                app.staticTexts.matching(
                    NSPredicate(format: "label CONTAINS %@", "NSURLErrorDomain")
                ).firstMatch.exists,
                "SFTP 隔离夹具不得触发生产连接错误"
            )
        }
    }

    func testGridCardHoverUsesExpectedGeometryWithoutClippingTheWindow() {
        withLaunchedApp(page: "machines-grid", theme: "light", width: 1440, height: 900) { app, window in
            let longName = "上海生产环境核心数据库 · 用于检查长中文名称的主机"
            let card = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", longName)
            ).firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 8), "长中文名称主机卡必须存在")

            let grid = app.scrollViews["machines.grid.scroll"]
            XCTAssertTrue(grid.waitForExistence(timeout: 3), "机器网格滚动容器必须可访问")
            let safeWindowFrame = window.frame.insetBy(dx: 20, dy: 20)
            for _ in 0..<6 {
                if card.isHittable, safeWindowFrame.contains(card.frame) { break }
                grid.swipeUp()
                waitForRendering()
            }
            XCTAssertTrue(
                card.isHittable && safeWindowFrame.contains(card.frame),
                "长中文名称主机卡必须完整滚入可见区域"
            )

            let before = card.frame
            card.hover()
            waitForRendering()
            let after = card.frame
            XCTAssertGreaterThan(after.width, before.width * 1.035)
            XCTAssertEqual(after.width / before.width, 1.05, accuracy: 0.025)
            XCTAssertTrue(window.frame.contains(after), "hover 放大内容不得越过窗口边界")
            attach(window.screenshot(), name: "machines-grid-hover-1440-light")
        }
    }

    func testThousandHostsCanFilterAndScroll() {
        withLaunchedApp(
            page: "machines-grid",
            theme: "light",
            width: 1440,
            height: 900,
            additionalArguments: ["--fixture-hosts", "1000"]
        ) { app, window in
            let search = app.textFields["搜索主机、地址、标签或备注"]
            XCTAssertTrue(search.waitForExistence(timeout: 12))
            let resultCount = app.staticTexts["machines.filtered.count"]
            XCTAssertTrue(resultCount.waitForExistence(timeout: 5))
            let unfilteredCount = accessibilityValue(of: resultCount)
            let started = ProcessInfo.processInfo.systemUptime
            search.click()
            search.typeText("999")
            let filteredExpectation = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", "1 台"),
                object: resultCount
            )
            XCTAssertEqual(XCTWaiter.wait(for: [filteredExpectation], timeout: 8), .completed)
            let filteredAt = ProcessInfo.processInfo.systemUptime
            search.typeKey("a", modifierFlags: .command)
            search.typeKey(.delete, modifierFlags: [])
            let restoredExpectation = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", unfilteredCount),
                object: resultCount
            )
            XCTAssertEqual(XCTWaiter.wait(for: [restoredExpectation], timeout: 8), .completed)
            let grid = app.scrollViews["machines.grid.scroll"]
            XCTAssertTrue(grid.waitForExistence(timeout: 8))
            let scrollAnchor = app.staticTexts["machines.scroll.anchor"]
            XCTAssertTrue(scrollAnchor.waitForExistence(timeout: 5))
            let initialAnchor = accessibilityValue(of: scrollAnchor)
            let restoredAt = ProcessInfo.processInfo.systemUptime
            // One continuous wheel gesture exercises lazy-grid realization while
            // avoiding eight separate XCTest idle/AX synchronization barriers.
            // Those barriers measure the test driver rather than scrolling work
            // performed by ServerDash and made the result machine-load dependent.
            grid.scroll(byDeltaX: 0, deltaY: -4_160)
            let scrolledAt = ProcessInfo.processInfo.systemUptime
            let elapsed = scrolledAt - started
            XCTAssertNotEqual(
                accessibilityValue(of: scrollAnchor),
                initialAnchor,
                "连续滚动必须实际移动机器网格"
            )
            let measurement = XCTAttachment(
                string: String(
                    format: "1,000 hosts: filter %.3f s + restore %.3f s + 4,160pt scroll %.3f s = %.3f s",
                    filteredAt - started,
                    restoredAt - filteredAt,
                    scrolledAt - restoredAt,
                    elapsed
                )
            )
            measurement.name = "machines-grid-1000-performance"
            measurement.lifetime = .keepAlways
            add(measurement)
            XCTAssertLessThan(elapsed, 30, "1,000 台主机筛选与连续滚动应保持交互可用")
            attach(window.screenshot(), name: "machines-grid-1000-after-filter-scroll")
        }
    }

    private var standardSizes: [(Int, Int)] {
        [(900, 620), (1440, 900), (1920, 1080)]
    }

    private func accessibilityValue(of element: XCUIElement) -> String {
        element.value as? String ?? ""
    }

    private func captureMatrix(page: String, sizes: [(Int, Int)]) {
        for theme in ["light", "dark"] {
            for (width, height) in sizes {
                capture(page: page, theme: theme, width: width, height: height)
            }
        }
    }

    private func capture(
        page: String,
        theme: String,
        width: Int,
        height: Int,
        flags: [String] = [],
        artifactSuffix: String? = nil
    ) {
        withLaunchedApp(
            page: page,
            theme: theme,
            width: width,
            height: height,
            additionalArguments: flags
        ) { app, window in
            if page == "rdp" {
                XCTAssertTrue(
                    app.descendants(matching: .any)["macqa.rdp.desktop"].waitForExistence(timeout: 8),
                    "RDP 路由必须呈现真实桌面 pane 的离线夹具"
                )
            }
            if page == "dialog" {
                XCTAssertTrue(
                    app.descendants(matching: .any)["monitor.layout.editor"].waitForExistence(timeout: 8),
                    "弹窗路由必须呈现真实的监控布局编辑器"
                )
            }
            let suffix = artifactSuffix.map { "-\($0)" } ?? ""
            attach(window.screenshot(), name: "\(page)-\(width)x\(height)-\(theme)\(suffix)")
            if app.alerts.firstMatch.exists {
                attach(app.alerts.firstMatch.screenshot(), name: "\(page)-alert-\(theme)\(suffix)")
            }
        }
    }

    private func withLaunchedApp(
        page: String,
        theme: String,
        width: Int,
        height: Int,
        additionalArguments: [String] = [],
        body: (XCUIApplication, XCUIElement) -> Void
    ) {
        let app = XCUIApplication()
        app.launchArguments = [
            // These are NSUserDefaults launch arguments, not environment keys.
            // Keep AppKit restoration from reopening any unrelated window while
            // the QA delegate creates its one controlled review surface.
            "-ApplePersistenceIgnoreState", "YES",
            "-NSQuitAlwaysKeepsWindows", "NO",
            "--mac-ui-fixture",
            "--fixture-page", page,
            "--fixture-theme", theme,
            "--fixture-width", String(width),
            "--fixture-height", String(height)
        ] + additionalArguments
        app.launch()
        defer { app.terminate() }

        let window = app.windows["serverdash.macqa.window"]
        XCTAssertTrue(window.waitForExistence(timeout: 12), "隔离 QA 窗口必须启动")
        XCTAssertEqual(app.windows.count, 1, "隔离 QA 进程必须只有一个受控窗口")
        waitForRendering()
        XCTAssertGreaterThanOrEqual(window.frame.width, CGFloat(width - 4))
        XCTAssertGreaterThanOrEqual(window.frame.height, CGFloat(height - 4))
        body(app, window)
    }

    private func waitForRendering() {
        let expectation = expectation(description: "等待 SwiftUI 与 AppKit 合成稳定")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)
    }

    private func waitForValue(_ value: String, on element: XCUIElement, timeout: TimeInterval) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value),
            object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
    }

    private func attach(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
