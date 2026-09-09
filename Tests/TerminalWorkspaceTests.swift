import XCTest
import SwiftTerm
#if os(macOS)
import AppKit
@testable import ServerDash
#else
import UIKit
@testable import ServerDashMobile
#endif

@MainActor
final class TerminalWorkspaceTests: XCTestCase {
    func testRecentUseIsIndependentOfTabOrderAndAuxiliarySelection() {
        let workspace = TerminalWorkspace(), server = UUID(), a = UUID(), b = UUID()
        workspace.add(sessionID: a, serverID: server, title: "A")
        workspace.add(sessionID: b, serverID: server, title: "B")
        XCTAssertEqual(workspace.mostRecentTerminal(for: server), b)
        workspace.select(pane: a)
        workspace.move(workspace.tabs[1].id, before: workspace.tabs[0].id)
        XCTAssertEqual(workspace.mostRecentTerminal(for: server), a)
        workspace.add(serverID: server, title: "Files", kind: .sftp)
        XCTAssertEqual(workspace.mostRecentTerminal(for: server), a)
        workspace.remove(pane: a)
        XCTAssertEqual(workspace.mostRecentTerminal(for: server), b)
    }

    func testBackgroundCloseKeepsAuxiliarySelectionAndZoomDoesNotLeak() {
        let workspace = TerminalWorkspace(), first = UUID()
        workspace.add(sessionID: first, serverID: UUID(), title: "SSH")
        workspace.toggleZoom(pane: first)
        workspace.add(serverID: UUID(), title: "Files", kind: .sftp)
        let selected = workspace.selectedTabID
        XCTAssertNil(workspace.zoomedPane)
        workspace.remove(pane: first)
        XCTAssertEqual(workspace.selectedTabID, selected)
        XCTAssertNil(workspace.mostRecentTerminal(for: UUID()))
    }

    func testCrossServerSplitSelectionUpdatesReuseForEachHost() {
        let workspace = TerminalWorkspace(), a = UUID(), b = UUID(), firstHost = UUID(), secondHost = UUID()
        workspace.add(sessionID: a, serverID: firstHost, title: "A")
        workspace.add(sessionID: b, serverID: secondHost, title: "B")
        XCTAssertTrue(workspace.split(a, inserting: b, axis: .below))
        workspace.select(pane: a)
        XCTAssertEqual(workspace.mostRecentTerminal(for: firstHost), a)
        XCTAssertEqual(workspace.mostRecentTerminal(for: secondHost), b)
        workspace.remove(pane: a)
        XCTAssertEqual(workspace.activePane, b)
        XCTAssertNil(workspace.mostRecentTerminal(for: firstHost))
    }

    func testSixteenIndependentPanelsAndLimit() {
        let workspace = TerminalWorkspace(), server = UUID(), first = UUID()
        workspace.add(sessionID: first, serverID: server, title: "Web")
        let tab = workspace.selectedTabID
        for index in 1..<16 {
            let pane = UUID()
            workspace.add(sessionID: pane, serverID: UUID(), title: "DB")
            XCTAssertTrue(workspace.split(first, inserting: pane, axis: index.isMultiple(of: 2) ? .right : .below))
        }
        XCTAssertEqual(workspace.tabs.count, 1)
        XCTAssertEqual(workspace.selectedTabID, tab)
        XCTAssertEqual(workspace.selectedTab?.layout.panes.count, 16)
        XCTAssertEqual(Set(workspace.selectedTab!.layout.panes).count, 16)
        XCTAssertFalse(workspace.canSplit(first))
        let extra = UUID()
        workspace.add(sessionID: extra, serverID: server, title: "Extra")
        XCTAssertFalse(workspace.split(first, inserting: extra, axis: .right))
        XCTAssertEqual(workspace.tabs.count, 2)
    }

    func testClosingLeafCollapsesOnlyItsBranch() {
        let workspace = TerminalWorkspace(), a = UUID(), b = UUID(), c = UUID()
        for id in [a, b, c] { workspace.add(sessionID: id, serverID: UUID(), title: "SSH") }
        XCTAssertTrue(workspace.split(a, inserting: b, axis: .right))
        XCTAssertTrue(workspace.split(b, inserting: c, axis: .below))
        workspace.select(pane: b)
        workspace.remove(pane: b)
        XCTAssertEqual(workspace.selectedTab?.layout.panes, [a, c])
        XCTAssertEqual(workspace.activePane, a)
        workspace.remove(pane: a)
        XCTAssertEqual(workspace.selectedTab?.layout, .pane(c))
        workspace.remove(pane: c)
        XCTAssertNil(workspace.selectedTabID)
    }

    func testTabsHaveNoArtificialLimitAndReorderKeepsSelection() {
        let workspace = TerminalWorkspace()
        for _ in 0..<100 { workspace.add(serverID: UUID(), title: "SSH") }
        let selected = workspace.selectedTabID!, first = workspace.tabs[0].id
        workspace.move(selected, before: first)
        XCTAssertEqual(workspace.tabs.first?.id, selected)
        XCTAssertEqual(workspace.selectedTabID, selected)
        workspace.advance(-1)
        XCTAssertEqual(workspace.selectedTabID, workspace.tabs.last?.id)
        workspace.advance(1)
        XCTAssertEqual(workspace.selectedTabID, selected)
    }

    func testStaleSplitTargetAndAuxiliaryTabsCannotConsumeSessions() {
        let workspace = TerminalWorkspace(), session = UUID()
        workspace.add(sessionID: session, serverID: UUID(), title: "SSH")
        XCTAssertFalse(workspace.split(UUID(), inserting: session, axis: .below))
        workspace.add(serverID: UUID(), title: "Files", kind: .sftp)
        XCTAssertFalse(workspace.canSplit(workspace.activePane!))
        XCTAssertFalse(workspace.split(workspace.activePane!, inserting: session, axis: .right))
        XCTAssertEqual(workspace.tabs.count, 2)
    }

    func testDividerRatiosClampAndRejectNonfiniteValues() {
        let id = UUID(), a = UUID(), b = UUID()
        let tree = TerminalSplitNode.split(id: id, axis: .right, ratio: 0.5, first: .pane(a), second: .pane(b))
        XCTAssertEqual(tree.resizing(id, ratio: .nan), tree)
        XCTAssertEqual(tree.resizing(id, ratio: .infinity), tree)
        guard case .split(_, _, let ratio, _, _) = tree.resizing(id, ratio: -10) else { return XCTFail() }
        XCTAssertEqual(ratio, 0.1)
    }

    func testClosingActiveTabSelectsNeighborAndDoesNotChangeOtherLayouts() {
        let workspace = TerminalWorkspace()
        for _ in 0..<3 { workspace.add(serverID: UUID(), title: "SSH") }
        let survivor = workspace.tabs[0]
        for tab in workspace.tabs where tab.id != survivor.id { workspace.remove(tab: tab.id) }
        XCTAssertEqual(workspace.selectedTabID, survivor.id)
        XCTAssertEqual(workspace.selectedTab?.layout, survivor.layout)
    }

    func testGridAndZoomPreserveEverySession() throws {
        let workspace = TerminalWorkspace(), first = UUID()
        workspace.add(sessionID: first, serverID: UUID(), title: "first")
        for _ in 1..<16 {
            let pane = UUID()
            workspace.add(sessionID: pane, serverID: UUID(), title: "SSH")
            XCTAssertTrue(workspace.split(first, inserting: pane, axis: .right))
        }
        let before = workspace.selectedTab!.layout.panes
        workspace.arrangeGrid()
        XCTAssertEqual(workspace.selectedTab?.layout.panes, before)
        workspace.toggleZoom(pane: first)
        XCTAssertEqual(workspace.renderedLayout, .pane(first))
        XCTAssertEqual(workspace.selectedTab?.layout.panes.count, 16)
        workspace.toggleZoom(pane: first)
        XCTAssertEqual(workspace.renderedLayout?.panes.count, 16)
    }
}

@MainActor
final class TerminalToolsTests: XCTestCase {
    func testPersistentHistoryDeduplicatesAndIsolatesServers() throws {
        let suite = "ServerDash-history-tests-\(UUID())", server = UUID()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CommandHistoryStore(defaults: defaults)
        store.record("ls -lah", serverID: server)
        store.record("pwd", serverID: server)
        store.record("ls -lah", serverID: server)
        store.record("ls -lah", serverID: UUID())
        XCTAssertEqual(store.entries.count, 3)
        XCTAssertEqual(CommandHistoryStore(defaults: defaults).entries, store.entries)
        store.enabled = false
        store.record("top", serverID: server)
        XCTAssertEqual(store.entries.count, 3)
        store.clear()
        XCTAssertTrue(CommandHistoryStore(defaults: defaults).entries.isEmpty)
    }

    func testHistoryRejectsSensitiveCommandsAndControlSequences() {
        for command in [" password", "sudo passwd user", "curl -H 'Authorization: Bearer abc'", "mysql -pabc", "export KEY=abc", "echo abc=def", "sshpass -p abc ssh host", "echo secret", "ls\nreboot", "\u{1b}[A", " ", String(repeating: "x", count: 4097)] {
            XCTAssertFalse(CommandHistoryStore.mayPersist(command), command)
        }
        XCTAssertTrue(CommandHistoryStore.mayPersist("journalctl -fu nginx"))
    }

    func testCompletionPrioritizesLocalHistoryAndDeduplicates() {
        let results = TerminalCompletion.suggestions(prefix: "do", history: ["docker ps", "docker logs -f web"], snippets: ["docker ps", "docker compose up -d"])
        XCTAssertEqual(results.first, .init(command: "docker ps", source: "历史"))
        XCTAssertEqual(Set(results.map(\.command)).count, results.count)
        XCTAssertTrue(results.contains { $0.source == "片段" })
        XCTAssertTrue(TerminalCompletion.suggestions(prefix: "", history: [], snippets: []).isEmpty)
    }

    func testAllPresetsMatchExamples() throws {
        let samples = ["https://example.com", "192.168.1.100", "fe80::1", "admin@example.com", "2024-01-15", "Mon Jan 01", "14:30:22", "Jan  1 14:30:22", "c4ff68b0-e7ab-408d-a5cf-b36493660874", "ERROR", "warning", "success", "/var/log/syslog", "AA:BB:CC:DD:EE:FF", "8080"]
        XCTAssertEqual(TerminalHighlightRule.presets.count, 15)
        XCTAssertEqual(TerminalHighlightRule.colors.count, 12)
        for (rule, text) in zip(TerminalHighlightRule.presets, samples) {
            let regex = try NSRegularExpression(pattern: rule.pattern)
            XCTAssertNotNil(regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)), rule.name)
        }
    }

    func testNativeHighlightMappingAndSearchDoNotMutateOutput() throws {
        let terminal = SwiftTerm.TerminalView(frame: .init(x: 0, y: 0, width: 800, height: 400))
        let tools = TerminalTools(serverID: UUID())
        tools.attach(terminal)
        terminal.feed(text: "中文 8080 8080")
        tools.searchText = "8080"
        let line = try XCTUnwrap(terminal.getTerminal().getLine(row: 0))
        let matches = try XCTUnwrap(terminal.cellHighlights?(line))
        XCTAssertTrue(matches.contains { $0.columns == 5..<9 })
        XCTAssertTrue(matches.contains { $0.columns == 10..<14 })
        tools.search()
        XCTAssertEqual(tools.searchFound, true)
        tools.searchText = "not-found"
        tools.search()
        XCTAssertEqual(tools.searchFound, false)
        XCTAssertTrue(line.translateToString(trimRight: true, skipNullCellsFollowingWide: true).contains("8080 8080"))
    }

    func testShellIntegrationIsSingleLineAndDoesNotModifyRemoteFiles() {
        for script in [TerminalShellIntegration.bash, TerminalShellIntegration.zsh] {
            XCTAssertFalse(script.contains("\n"))
            XCTAssertFalse(script.contains(">"))
            XCTAssertFalse(script.contains(".bashrc"))
            XCTAssertFalse(CommandHistoryStore.mayPersist(script))
        }
    }

    func testShellBoundaryRecordsCommandsButNotPasswordInput() throws {
        let suite = "ServerDash-boundary-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = CommandHistoryStore(defaults: defaults)
        let terminal = SwiftTerm.TerminalView(frame: .init(x: 0, y: 0, width: 800, height: 400))
        let tools = TerminalTools(serverID: UUID(), history: history)
        tools.attach(terminal)
        terminal.feed(text: "\u{1b}]133;A\u{7}user$ \u{1b}]133;B\u{7}pwd\r\n\u{1b}]133;C\u{7}Password: ")
        terminal.send(txt: "test-private-response\r")
        XCTAssertEqual(history.entries.map(\.command), ["pwd"])
        terminal.feed(text: "\r\nordinary output without shell markers\r\n")
        XCTAssertEqual(history.entries.count, 1)
        tools.resetCommandBoundary()
        terminal.feed(text: "\u{1b}]133;C\u{7}")
        XCTAssertEqual(history.entries.count, 1)
    }
}
