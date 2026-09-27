#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import ServerDash

@MainActor
final class MacTableScrollStateTests: XCTestCase {
    private typealias State = MacNativeTableScrollBridge<String>.Coordinator.AnchorState

    func testNativeRowSizingDoesNotFightHostAfterInitialConfiguration() {
        let table = RowSizingSpyTableView()
        table.usesAutomaticRowHeights = true
        table.rowHeight = 18
        let configuration = MacNativeTableRowSizing.Configuration()
        configuration.applyIfNeeded(to: table, fixedHeight: 30)
        XCTAssertEqual(table.rowHeight, 30)
        XCTAssertFalse(table.usesAutomaticRowHeights)

        // Replay SwiftUI's independent sizing pass. Reasserting 30 here used
        // to trigger another SwiftUI update and an endless pair of layouts.
        table.rowHeight = 24
        table.usesAutomaticRowHeights = true
        let hostWrites = table.rowHeightWriteCount
        for _ in 0..<1_000 {
            configuration.applyIfNeeded(to: table, fixedHeight: 30)
        }
        XCTAssertEqual(table.rowHeightWriteCount, hostWrites)
        XCTAssertEqual(table.rowHeight, 24)
        XCTAssertTrue(table.usesAutomaticRowHeights)
    }

    func testNativeRowSizingMarksConfigurationBeforeReentrantLayout() {
        let table = RowSizingSpyTableView()
        table.rowHeight = 18
        let configuration = MacNativeTableRowSizing.Configuration()
        table.onRowHeightWrite = { configuration.applyIfNeeded(to: table, fixedHeight: 30) }
        let before = table.rowHeightWriteCount
        configuration.applyIfNeeded(to: table, fixedHeight: 30)
        XCTAssertEqual(table.rowHeightWriteCount, before + 1)
        table.onRowHeightWrite = nil
    }

    func testNativeRowSizingReappliesOnlyForNewTableOrRequestedHeight() {
        let first = RowSizingSpyTableView(), second = RowSizingSpyTableView()
        let configuration = MacNativeTableRowSizing.Configuration()
        configuration.applyIfNeeded(to: first, fixedHeight: 30)
        configuration.applyIfNeeded(to: first, fixedHeight: 28)
        XCTAssertEqual(first.rowHeight, 28)
        configuration.applyIfNeeded(to: second, fixedHeight: 30)
        XCTAssertEqual(second.rowHeight, 30)
        first.rowHeight = 20
        configuration.reset()
        configuration.applyIfNeeded(to: first, fixedHeight: 30)
        XCTAssertEqual(first.rowHeight, 30)
    }

    func testBridgeDefersNativeWorkAndRejectsQueuedCallbacksAfterDetach() async {
        let frame = NSRect(x: 0, y: 0, width: 400, height: 220)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: frame), scroll = NSScrollView(frame: frame)
        let table = RowSizingSpyTableView(frame: .init(x: 0, y: 0, width: 400, height: 3_000))
        let source = TableRows()
        table.addTableColumn(NSTableColumn(identifier: .init("name")))
        table.dataSource = source
        scroll.documentView = table
        root.addSubview(scroll)
        let probe = MacNativeTableScrollBridge<String>.ProbeView(frame: frame)
        root.addSubview(probe)
        window.contentView = root
        table.reloadData()
        let box = AnchorBox()
        let binding = Binding<String?>(get: { box.value }, set: { box.value = $0; box.writes += 1 })
        let rows = (0..<100).map { "row-\($0)" }
        let coordinator = MacNativeTableScrollBridge<String>.Coordinator(rowIDs: rows, anchor: binding, fixedRowHeight: 30)
        coordinator.probe = probe
        probe.onHierarchyChange = { [weak coordinator] in coordinator?.scheduleAttach() }
        defer {
            probe.onHierarchyChange = nil
            coordinator.detach()
            window.contentView = nil
            window.close()
        }
        coordinator.scheduleAttach()
        await drainNativeCallbacks()
        XCTAssertEqual(table.rowHeight, 30)

        table.rowHeight = 24
        table.usesAutomaticRowHeights = true
        let writesBeforeUpdate = table.rowHeightWriteCount
        for _ in 0..<100 {
            coordinator.update(rowIDs: rows, anchor: binding, fixedRowHeight: 30)
            probe.layout()
        }
        XCTAssertEqual(table.rowHeightWriteCount, writesBeforeUpdate, "updateNSView/layout must record intent without mutating native sizing")
        await drainNativeCallbacks()
        XCTAssertEqual(table.rowHeightWriteCount, writesBeforeUpdate, "Deferred attachment must not reclaim SwiftUI's sizing on every update")

        let writesBeforeDetach = box.writes
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        coordinator.scheduleAttach()
        coordinator.detach()
        await drainNativeCallbacks()
        XCTAssertEqual(box.writes, writesBeforeDetach, "Callbacks for a detached table must not write a stale anchor")
        withExtendedLifetime(source) {}
    }

    func testScrollNotificationBeforeNarrowLayoutRestoresDeepAnchorFirst() async {
        let fixture = NativeScrollOrderFixture(anchor: "row-50")
        defer { fixture.close() }
        fixture.coordinator.scheduleAttach()
        await drainNativeCallbacks()
        XCTAssertEqual(fixture.anchor.value, "row-50")

        let clip = fixture.scroll.contentView
        clip.setBoundsSize(NSSize(width: clip.bounds.width, height: fixture.table.bounds.height + 100))
        clip.scroll(to: .zero)
        fixture.coordinator.captureTopRow()
        XCTAssertEqual(fixture.anchor.value, "row-50", "A viewport showing every row preserves the meaningful deep anchor")

        clip.setBoundsSize(NSSize(width: clip.bounds.width, height: 220))
        clip.scroll(to: .zero)
        // Deliver the native callback before any scheduled probe/attach layout.
        fixture.coordinator.captureTopRow()
        XCTAssertEqual(fixture.anchor.value, "row-50", "The clamped top row must not win the resize race")
        XCTAssertGreaterThan(clip.bounds.minY, 500, "The callback must restore before a later layout can capture row 0")
        await drainNativeCallbacks()
        XCTAssertEqual(fixture.anchor.value, "row-50")
    }

    func testOldClipCallbackCannotWriteAnchorAfterNativeTableReplacement() async {
        let fixture = NativeScrollOrderFixture(anchor: "row-50")
        defer { fixture.close() }
        fixture.coordinator.scheduleAttach()
        await drainNativeCallbacks()
        let writes = fixture.anchor.writes
        let replacement = RowSizingSpyTableView(frame: fixture.table.frame)
        replacement.headerView = nil
        replacement.addTableColumn(NSTableColumn(identifier: .init("replacement")))
        replacement.dataSource = fixture.source
        let replacementScroll = NSScrollView(frame: fixture.scroll.frame)
        replacementScroll.documentView = replacement
        // Keep the old table AND its enclosing scroll in the same window, but
        // outside the probe. Window/enclosingScroll identity alone still passes.
        fixture.scroll.setFrameOrigin(NSPoint(x: fixture.scroll.frame.maxX + 100, y: 0))
        fixture.window.contentView?.addSubview(replacementScroll)
        replacement.reloadData()
        XCTAssertTrue(fixture.table.window === fixture.window)
        XCTAssertTrue(fixture.scroll.window === fixture.window)
        XCTAssertTrue(fixture.table.enclosingScrollView === fixture.scroll)
        XCTAssertTrue(replacement.window === fixture.window)
        // The old observer's generation is still current until deferred attach.
        fixture.coordinator.captureTopRow()
        XCTAssertEqual(fixture.anchor.writes, writes)
        XCTAssertEqual(fixture.anchor.value, "row-50")
        await drainNativeCallbacks()
        XCTAssertEqual(fixture.anchor.value, "row-50")
        XCTAssertEqual(replacement.rowHeight, 30)
        XCTAssertGreaterThan(replacementScroll.contentView.bounds.minY, 500,
                             "Deferred attach must restore the retained row on the new table")
    }

    func testFloatingHeaderOcclusionUsesMeasuredGeometry() {
        let viewport = NSRect(x: 0, y: 110, width: 400, height: 220)
        let floating = NSRect(x: 0, y: 110, width: 400, height: 28)
        let unobscured = MacNativeTableScrollMetrics.unobscuredViewport(viewport, header: floating)
        XCTAssertEqual(unobscured.minY, 138)
        XCTAssertEqual(unobscured.maxY, viewport.maxY)
        XCTAssertEqual(MacNativeTableScrollMetrics.unobscuredViewport(viewport, header: nil), viewport)
        XCTAssertEqual(MacNativeTableScrollMetrics.unobscuredViewport(viewport,
            header: NSRect(x: 0, y: 82, width: 400, height: 28)), viewport,
            "A standard header outside the clip must not shift row restoration")
    }

    func testHostedSwiftUITableKeepsThirtyPointRowsAcrossResize() async throws {
        let root = NSHostingView(rootView: NativeTableSizingFixture())
        let initial = NSRect(x: 0, y: 0, width: 600, height: 300)
        let window = NSWindow(contentRect: initial, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        root.frame = initial
        window.contentView = root
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        for size in [NSSize(width: 600, height: 300), NSSize(width: 900, height: 620), NSSize(width: 420, height: 220)] {
            window.setContentSize(size)
            root.layoutSubtreeIfNeeded()
            await drainNativeCallbacks()
            let table = try XCTUnwrap(Self.findTable(in: root))
            XCTAssertEqual(table.rowHeight, SFTPBrowserLayout.tableRowHeight,
                           "SwiftUI and the bridge must agree on 30pt after native layout settles")
            let scroll = try XCTUnwrap(table.enclosingScrollView)
            let viewport = table.convert(scroll.contentView.bounds, from: scroll.contentView)
            let header = table.headerView.map { table.convert($0.visibleRect, from: $0) }
            let unobscured = MacNativeTableScrollMetrics.unobscuredViewport(viewport, header: header)
            let firstRow = table.rect(ofRow: 0)
            XCTAssertGreaterThanOrEqual(firstRow.minY + 0.5, unobscured.minY,
                                       "Restoring row 0 must keep its top below a floating header")
            XCTAssertLessThanOrEqual(firstRow.maxY, unobscured.maxY + 0.5)
            let settledHeight = table.rowHeight
            await drainNativeCallbacks()
            XCTAssertEqual(table.rowHeight, settledHeight, "Another layout pass must not alternate native row heights")
        }
    }

    private static func findTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews {
            if let table = findTable(in: child) { return table }
        }
        return nil
    }

    private func drainNativeCallbacks() async {
        // Drain the coalesced attach and capture queue turns without a timed sleep.
        for _ in 0..<3 {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    func testDirectoryResetAfterManualScrollDoesNotRequirePriorRestoration() {
        var state = State()
        state.observed("/first/row-45")
        XCTAssertNil(state.lastAppliedAnchor)
        XCTAssertTrue(state.update(desired: nil, rowsChanged: true))
        XCTAssertNil(state.pendingRestore)
        XCTAssertNil(state.lastObservedAnchor)
        XCTAssertNil(state.lastAppliedAnchor)
        XCTAssertFalse(state.update(desired: nil, rowsChanged: false))
    }

    func testExplicitResetWorksEvenWhenRowsHaveIdenticalIDs() {
        var state = State()
        state.observed("row-45")
        XCTAssertTrue(state.update(desired: nil, rowsChanged: false))
        XCTAssertNil(state.pendingRestore)
    }

    func testSameDirectoryReorderRestoresObservedAnchorAtItsNewIndex() {
        var state = State()
        state.observed("/fixture/row-45")
        XCTAssertFalse(state.update(desired: "/fixture/row-45", rowsChanged: true))
        XCTAssertEqual(state.pendingRestore, "/fixture/row-45")
        state.restored("/fixture/row-45")
        XCTAssertNil(state.pendingRestore)
        XCTAssertEqual(state.lastAppliedAnchor, "/fixture/row-45")
    }

    func testUnchangedInputsDoNotSnapBackAfterScrolling() {
        var state = State(pendingRestore: "row-10")
        state.restored("row-10")
        for row in 11..<1_000 {
            let value = "row-\(row)"
            state.observed(value)
            XCTAssertFalse(state.update(desired: value, rowsChanged: false))
            XCTAssertNil(state.pendingRestore)
        }
    }

    func testFilterReplacementAndRemountRetainPendingAnchorUntilLayout() {
        var state = State(pendingRestore: "row-20")
        XCTAssertFalse(state.update(desired: "row-20", rowsChanged: false))
        XCTAssertEqual(state.pendingRestore, "row-20")
        state.restored("row-20")
        XCTAssertFalse(state.update(desired: "row-99", rowsChanged: true))
        XCTAssertEqual(state.pendingRestore, "row-99")
        XCTAssertTrue(state.update(desired: nil, rowsChanged: true))
        XCTAssertNil(state.pendingRestore)
    }

    func testNewRowsWithNoObservedAnchorStillResetPendingNativeScroll() {
        var state = State()
        // A native wheel notification can still be queued as a directory changes.
        XCTAssertTrue(state.update(desired: nil, rowsChanged: true))
        XCTAssertNil(state.lastObservedAnchor)
        XCTAssertFalse(state.update(desired: nil, rowsChanged: false))
    }
}

private struct NativeTableSizingFixture: View {
    private struct Row: Identifiable { let id: Int }
    @State private var selection: Set<Int> = []
    @State private var anchor: Int? = 0
    private let rows = (0..<100).map { Row(id: $0) }

    var body: some View {
        Table(rows, selection: $selection) {
            TableColumn("名称") { row in Text("File \(row.id)") }
        }
        .environment(\.defaultMinListRowHeight, SFTPBrowserLayout.tableRowHeight)
        .background(MacNativeTableScrollBridge(rowIDs: rows.map(\.id), anchor: $anchor,
                                               fixedRowHeight: SFTPBrowserLayout.tableRowHeight))
    }
}

@MainActor private final class NativeScrollOrderFixture {
    let window: NSWindow
    let scroll: NSScrollView
    let table: RowSizingSpyTableView
    let source = TableRows()
    let probe: MacNativeTableScrollBridge<String>.ProbeView
    let anchor = AnchorBox()
    let coordinator: MacNativeTableScrollBridge<String>.Coordinator

    init(anchor desired: String) {
        let frame = NSRect(x: 0, y: 0, width: 400, height: 220)
        window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        scroll = NSScrollView(frame: frame)
        table = RowSizingSpyTableView(frame: .init(x: 0, y: 0, width: 400, height: 3_000))
        table.headerView = nil
        table.addTableColumn(NSTableColumn(identifier: .init("name")))
        table.dataSource = source
        scroll.documentView = table
        let root = NSView(frame: frame)
        root.addSubview(scroll)
        probe = MacNativeTableScrollBridge<String>.ProbeView(frame: frame)
        root.addSubview(probe)
        window.contentView = root
        table.reloadData()
        let box = anchor
        box.value = desired
        let binding = Binding<String?>(get: { box.value }, set: { box.value = $0; box.writes += 1 })
        coordinator = MacNativeTableScrollBridge<String>.Coordinator(
            rowIDs: (0..<100).map { "row-\($0)" }, anchor: binding, fixedRowHeight: 30)
        coordinator.probe = probe
    }

    func close() {
        coordinator.detach()
        window.contentView = nil
        window.close()
    }
}

@MainActor private final class RowSizingSpyTableView: NSTableView {
    private(set) var rowHeightWriteCount = 0
    var onRowHeightWrite: (() -> Void)?
    override var rowHeight: CGFloat {
        didSet { rowHeightWriteCount += 1; onRowHeightWrite?() }
    }
}

@MainActor private final class TableRows: NSObject, NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { 100 }
}

@MainActor private final class AnchorBox {
    var value: String?
    var writes = 0
}
#endif
