#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import ServerDash

@MainActor
final class SFTPBrowserPresentationTests: XCTestCase {
    private func item(_ name: String, in directory: String = "/fixture") -> RemoteFileItem {
        RemoteFileItem(path: "\(directory)/\(name)", name: name, kind: .file,
                       size: 64, permissions: "rw-r--r--", owner: "fixture",
                       group: "fixture", modifiedText: "2026-09-25")
    }

    func testNarrowTableDoesNotOverwriteWiderColumnChoices() {
        let narrow = SFTPBrowserLayout(width: 580, chromeMode: .full)
        let wide = SFTPBrowserLayout(width: 1_050, chromeMode: .full)
        var saved = TableColumnCustomization<RemoteFileItem>()
        saved[visibility: "owner"] = .hidden

        let compactPresentation = narrow.tableColumns(from: saved)
        XCTAssertEqual(compactPresentation[visibility: "permissions"], .hidden)
        XCTAssertEqual(compactPresentation[visibility: "owner"], .hidden)

        // A Table callback while narrow contains forced visibility. Persisting
        // it must not silently change the user's wider layout preferences.
        saved = narrow.storedColumns(after: compactPresentation, previous: saved)
        XCTAssertEqual(wide.tableColumns(from: saved)[visibility: "permissions"], .automatic)
        XCTAssertEqual(wide.tableColumns(from: saved)[visibility: "owner"], .hidden)
    }

    func testControllerRetainsSelectionScrollAnchorAndColumnsAcrossViews() {
        let app = AppState(trustCoordinator: HostTrustCoordinator(), fileServicesEnabled: false)
        let server = ServerRecord(name: "fixture", host: "fixture.invalid", username: "fixture")
        let controller = MacSFTPController(server: server, appState: app, automaticallyConnect: false)
        defer { controller.close() }
        let first = item("first.txt"), second = item("second.txt")
        controller.applyDirectoryListing(.init(path: "/fixture", items: [first, second]))
        controller.selection = [second.id]
        controller.scrollAnchor = second.id
        controller.tableColumnCustomization[visibility: "owner"] = .hidden

        _ = SFTPBrowserView(controller: controller, chromeMode: .full)
        _ = SFTPBrowserView(controller: controller, chromeMode: .inspector)
        XCTAssertEqual(controller.selection, [second.id])
        XCTAssertEqual(controller.scrollAnchor, second.id)
        XCTAssertEqual(controller.tableColumnCustomization[visibility: "owner"], .hidden)

        controller.applyDirectoryListing(.init(path: "/fixture", items: [first, second]))
        XCTAssertEqual(controller.scrollAnchor, second.id)
        XCTAssertEqual(controller.selection, [second.id])
        controller.search = "first"
        XCTAssertEqual(controller.scrollAnchor, first.id)
        XCTAssertTrue(controller.selection.isEmpty)
        controller.search = ""
        controller.applyDirectoryListing(.init(path: "/other", items: [item("new.txt", in: "/other")]))
        XCTAssertNil(controller.scrollAnchor)
    }

    func testAllInspectorSectionsFitOrRemainAvailableInMenu() {
        XCTAssertEqual(TerminalInspectorSection.allCases.count, 9)
        let threshold = TerminalInspectorNavigationLayout.minimumIconStripWidth
        XCTAssertTrue(TerminalInspectorNavigationLayout.usesMenu(width: threshold - 1, presentation: .sidebar))
        XCTAssertFalse(TerminalInspectorNavigationLayout.usesMenu(width: threshold, presentation: .sidebar))
        XCTAssertTrue(TerminalInspectorNavigationLayout.usesMenu(width: 500, presentation: .popover))
    }

    func testWideTableDoesNotReplaceMeaningfulScrollAnchor() {
        XCTAssertFalse(MacNativeTableScrollMetrics.hasVerticalOverflow(
            documentHeight: 600, viewportHeight: 800))
        XCTAssertFalse(MacNativeTableScrollMetrics.hasVerticalOverflow(
            documentHeight: 600.5, viewportHeight: 600))
        XCTAssertTrue(MacNativeTableScrollMetrics.hasVerticalOverflow(
            documentHeight: 601.5, viewportHeight: 600))
    }

    func testSFTPFixedNativeRowsDisableAutomaticHeightMeasurement() {
        let table = NSTableView()
        table.usesAutomaticRowHeights = true
        table.rowHeight = 18

        MacNativeTableRowSizing.apply(to: table, fixedHeight: SFTPBrowserLayout.tableRowHeight)
        XCTAssertFalse(table.usesAutomaticRowHeights)
        XCTAssertEqual(table.rowHeight, 30)

        // Other Table users leave their native sizing policy untouched.
        table.usesAutomaticRowHeights = true
        table.rowHeight = 18
        MacNativeTableRowSizing.apply(to: table, fixedHeight: nil)
        XCTAssertTrue(table.usesAutomaticRowHeights)
        XCTAssertEqual(table.rowHeight, 18)
    }
}
#endif
