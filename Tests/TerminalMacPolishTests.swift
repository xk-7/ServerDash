import AppKit
import Darwin
import SwiftData
import SwiftTerm
import SwiftUI
import XCTest
@testable import ServerDash

final class TerminalMacPolishTests: XCTestCase {
    func testCapabilitiesCoverEveryWorkspaceKindWithoutGrantingSSHTools() {
        for kind in WorkspaceTabKind.allCases {
            let capabilities = TerminalCommandCapabilities(kind: kind, hasController: true)
            XCTAssertTrue(capabilities.canClose, kind.rawValue)
            XCTAssertEqual(capabilities.canSearch, [.terminal, .local, .serial].contains(kind), kind.rawValue)
            XCTAssertEqual(capabilities.canChangeAppearance, capabilities.canSearch)
            XCTAssertEqual(capabilities.canSplit, kind == .terminal)
            XCTAssertEqual(capabilities.canUseSSHTools, kind == .terminal)
            XCTAssertEqual(capabilities.canInspect, [.terminal, .rdp].contains(kind))
        }
        XCTAssertFalse(TerminalCommandCapabilities(kind: nil, hasController: false).canClose)
        XCTAssertFalse(TerminalCommandCapabilities(kind: .terminal, hasController: false).canSearch)
        XCTAssertFalse(TerminalCommandCapabilities(kind: .terminal, hasController: true, splitAvailable: false).canSplit)
    }

    func testInspectorUsesContentWidthAfterSidebarConsumesSpace() {
        XCTAssertFalse(TerminalInspectorLayout.usesSidebar(contentWidth: 900 - 220))
        XCTAssertFalse(TerminalInspectorLayout.usesSidebar(contentWidth: 1180 - 240))
        XCTAssertTrue(TerminalInspectorLayout.usesSidebar(contentWidth: 1440 - 240))
        XCTAssertTrue(TerminalInspectorLayout.usesSidebar(contentWidth: 1920 - 260))
    }

    @MainActor func testDisplaySearchFindsExistingOutputAndClearsWithoutShellIntegration() throws {
        let terminal = SwiftTerm.TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        terminal.feed(text: "alpha fixture\r\nbeta fixture\r\n")
        let search = TerminalDisplaySearch()
        search.terminal = terminal
        search.isVisible = true; search.text = "fixture"; search.search()
        XCTAssertEqual(search.found, true)
        XCTAssertEqual(terminal.getSelection(), "fixture")
        search.search(backwards: true); XCTAssertEqual(search.found, true)
        search.text = "not-in-this-buffer"; search.search(); XCTAssertEqual(search.found, false)
        search.close()
        XCTAssertFalse(search.isVisible); XCTAssertNil(search.found); XCTAssertNil(terminal.getSelection())
    }

    @MainActor func testLocalPTYAppearanceUpdatesKeepProcessAndFieldFocus() async throws {
        let suite = "local-polish-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TerminalAppearanceStore(defaults: defaults)
        let config = LocalShellConfiguration(executable: "/bin/cat", arguments: [], environment: ["TERM": "xterm-256color", "PATH": "/usr/bin:/bin"], workingDirectory: NSTemporaryDirectory())
        let controller = WorkbenchSessionController(local: config, appearanceStore: store)
        let terminal = try XCTUnwrap(controller.hostView as? LocalProcessTerminalView)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let field = NSTextField(string: "Keep the path field focused")
        field.frame = NSRect(x: 0, y: 550, width: 500, height: 25)
        let host = NSHostingView(rootView: WorkbenchTerminalRepresentable(controller: controller).environment(\.colorScheme, .light))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 520)
        window.contentView?.addSubview(host); window.contentView?.addSubview(field)
        window.makeKeyAndOrderFront(nil)
        controller.reconnect()
        defer { controller.close(); window.close() }
        XCTAssertEqual(controller.status, .connected)
        let generation = controller.connectionGeneration, pid = terminal.process.shellPid
        terminal.send(txt: "local-polish-marker\r")
        let deadline = Date().addingTimeInterval(3)
        while !String(decoding: terminal.getTerminal().getBufferAsData(), as: UTF8.self).contains("local-polish-marker"), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        window.makeFirstResponder(field)
        let responder = window.firstResponder
        for dark in [true, false, true] {
            host.rootView = WorkbenchTerminalRepresentable(controller: controller).environment(\.colorScheme, dark ? .dark : .light)
            var profile = store.profile; profile.fontSize += 1; profile.letterSpacing = 0.2
            store.profile = profile
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
            XCTAssertEqual(controller.appearanceProfile.fontSize, profile.fontSize)
            XCTAssertEqual(controller.connectionGeneration, generation)
            XCTAssertEqual(terminal.process.shellPid, pid)
            XCTAssertEqual(controller.status, .connected)
            XCTAssertTrue(window.firstResponder === responder, "An appearance update must not steal field/IME focus")
        }
        controller.displaySearch.text = "local-polish-marker"; controller.displaySearch.search()
        XCTAssertEqual(controller.displaySearch.found, true)
        XCTAssertTrue(String(decoding: terminal.getTerminal().getBufferAsData(), as: UTF8.self).contains("local-polish-marker"))
        controller.close(); XCTAssertFalse(terminal.process.running)
    }

    @MainActor func testSerialPTYAppearanceSearchAndResizeKeepTheSameConnection() async throws {
        var master: Int32 = -1, slave: Int32 = -1
        var path = [CChar](repeating: 0, count: 1024)
        XCTAssertEqual(openpty(&master, &slave, &path, nil, nil), 0)
        guard master >= 0, slave >= 0 else { return }
        defer { Darwin.close(master); Darwin.close(slave) }
        let record = SerialConnectionRecord(name: "Serial polish fixture", devicePath: String(cString: path))
        let controller = WorkbenchSessionController(record: record)
        let terminal = try XCTUnwrap(controller.hostView as? LocalProcessTerminalView)
        terminal.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        controller.reconnect(); defer { controller.close() }
        XCTAssertEqual(controller.status, .connected)
        let generation = controller.connectionGeneration
        let message = Data("serial-polish-marker\r\n".utf8)
        XCTAssertEqual(message.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }, message.count)
        let deadline = Date().addingTimeInterval(3)
        while !String(decoding: terminal.getTerminal().getBufferAsData(), as: UTF8.self).contains("serial-polish-marker"), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        for (size, dark) in [(CGFloat(900), false), (CGFloat(1440), true), (CGFloat(1920), false)] {
            terminal.frame.size.width = size
            controller.performFontShortcut(.increase)
            controller.applyAppearance(controller.appearanceProfile, dark: dark)
            controller.displaySearch.text = "serial-polish-marker"; controller.displaySearch.search()
            XCTAssertEqual(controller.displaySearch.found, true)
            XCTAssertEqual(controller.connectionGeneration, generation)
            XCTAssertEqual(controller.status, .connected)
        }
        controller.close(); XCTAssertEqual(controller.status, .disconnected)
        let replacement = SerialPortTransport()
        try replacement.open(record.configuration, output: { _ in }, ended: { _ in })
        replacement.close()
    }
}
