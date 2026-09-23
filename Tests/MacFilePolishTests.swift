#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import ServerDash

@MainActor
private final class ManualShutdownProgressScheduler {
    var pending: (@MainActor @Sendable () -> Void)?

    func scheduler() -> ShutdownProgressScheduler {
        ShutdownProgressScheduler { [weak self] action in
            self?.pending = action
            return Task {}
        }
    }

    func fire() {
        let action = pending
        pending = nil
        action?()
    }
}

@MainActor
private final class ShutdownProgressProbe {
    var presentations = 0
}

final class MacFilePolishTests: XCTestCase {
    private func item(_ path: String) -> RemoteFileItem {
        RemoteFileItem(path: path, name: (path as NSString).lastPathComponent, kind: .file, size: 10, permissions: "rw-r--r--", owner: "fixture", group: "fixture", modifiedText: "2026-09-10")
    }
    private func draft(_ text: String = "first\n中文\nlast") -> RemoteEditorDraft {
        let data = Data(text.utf8)
        return RemoteEditorDraft(serverID: UUID(), serverName: "isolated fixture", path: "/fixture/file.txt", text: text, encoding: .utf8, hasBOM: false, original: data, revision: RemoteFileRevision(size: Int64(data.count), modifiedNS: 1, inode: 1, mode: 0o600, uid: 1, gid: 1, sha256: DesktopFileOperations.digest(data)))
    }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mac-file-polish-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testSFTPBrowserUsesItsOwnWidthForCompactActionsAndColumns() {
        let narrow = SFTPBrowserLayout(width: 580, chromeMode: .full)
        let wide = SFTPBrowserLayout(width: 1_050, chromeMode: .full)
        let inspector = SFTPBrowserLayout(width: 1_050, chromeMode: .inspector)
        XCTAssertTrue(narrow.compactActions)
        XCTAssertFalse(narrow.showsSecondaryColumns)
        XCTAssertFalse(wide.compactActions)
        XCTAssertTrue(wide.showsSecondaryColumns)
        XCTAssertTrue(inspector.compactActions)
        XCTAssertFalse(inspector.showsSecondaryColumns)

        let columns = TableColumnCustomization<RemoteFileItem>()
        XCTAssertEqual(narrow.tableColumns(from: columns)[visibility: "permissions"], .hidden)
        XCTAssertEqual(narrow.tableColumns(from: columns)[visibility: "owner"], .hidden)
        XCTAssertEqual(wide.tableColumns(from: columns)[visibility: "permissions"], .visible)
        XCTAssertEqual(wide.tableColumns(from: columns)[visibility: "owner"], .visible)
    }
    func testSFTPDialogInputsKeepExactRemoteNamesAndRejectInvalidValues() {
        XCTAssertEqual(SFTPDialogInput.permissionMode(" 0755 "), 0o755)
        XCTAssertEqual(SFTPDialogInput.permissionMode("644"), 0o644)
        XCTAssertNil(SFTPDialogInput.permissionMode("888"))
        XCTAssertNil(SFTPDialogInput.permissionMode("12345"))
        XCTAssertEqual(SFTPDialogInput.archiveName("  中文 配置[*]?  "), "中文 配置[*]?")
        XCTAssertNil(SFTPDialogInput.archiveName(" "))
        XCTAssertNil(SFTPDialogInput.archiveName("../backup"))
        XCTAssertNil(SFTPDialogInput.archiveName(".."))
    }
    @MainActor func testFilteringPrunesInvisibleSelectionAndRefreshRetainsExistingRows() {
        let app = AppState(trustCoordinator: HostTrustCoordinator(), fileServicesEnabled: false)
        let server = ServerRecord(name: "fixture", host: "fixture.invalid", username: "fixture")
        let controller = MacSFTPController(server: server, appState: app, automaticallyConnect: false)
        let a = item("/fixture/a.txt"), b = item("/fixture/b.txt"), hidden = item("/fixture/.hidden")
        controller.applyDirectoryListing(.init(path: "/fixture", items: [a, b, hidden]))
        controller.selection = [a.id, b.id]
        controller.search = "a.txt"
        XCTAssertEqual(controller.selection, [a.id])
        controller.search = ""
        controller.showHidden = true; controller.selection = [a.id, hidden.id]
        controller.showHidden = false
        XCTAssertEqual(controller.selection, [a.id])
        controller.applyDirectoryListing(.init(path: "/fixture", items: [a, item("/fixture/c.txt")]))
        XCTAssertEqual(controller.selection, [a.id])
        controller.applyDirectoryListing(.init(path: "/elsewhere", items: [a]))
        XCTAssertTrue(controller.selection.isEmpty)
        controller.close()
    }
    @MainActor func testMultiSelectionBuildsOneDownloadRequestPerVisibleItem() throws {
        let app = AppState(trustCoordinator: HostTrustCoordinator(), fileServicesEnabled: false)
        let server = ServerRecord(name: "fixture", host: "fixture.invalid", username: "fixture")
        let controller = MacSFTPController(server: server, appState: app, automaticallyConnect: false)
        let a = item("/fixture/a.txt"), b = item("/fixture/含 空格[*].txt")
        controller.applyDirectoryListing(.init(path: "/fixture", items: [a, b]))
        controller.selection = [a.id, b.id]
        let destination = try temporaryDirectory()

        let requests = controller.downloadRequests(to: destination)

        XCTAssertEqual(Set(requests.map(\.item)), Set([a, b]))
        XCTAssertEqual(Set(requests.map(\.destination.lastPathComponent)), Set([a.name, b.name]))
        controller.close()
    }
    func testIncrementalLineIndexMatchesFullIndexThroughUnicodeAndBoundaryEdits() {
        var text = "中文\r\n😀 first\nlast\n", index = EditorLineIndex(text)
        for (range, replacement) in [
            (NSRange(location: 2, length: 0), "\n插入"),
            (NSRange(location: 0, length: 3), "A\nB\n"),
            (NSRange(location: 5, length: 3), ""),
            (NSRange(location: 1, length: 0), "\n")
        ] {
            text = (text as NSString).replacingCharacters(in: range, with: replacement)
            index.replace(range, with: replacement)
            let expected = EditorLineIndex(text)
            XCTAssertEqual(index.starts, expected.starts)
            XCTAssertEqual(index.length, expected.length)
            for offset in 0...index.length { XCTAssertEqual(index.line(at: offset), expected.line(at: offset)) }
        }
    }
    @MainActor func testPresentationPreservesUndoAndSelectionAcrossSearchAndDraftFlush() async throws {
        let url = try temporaryDirectory().appendingPathComponent("documents.json")
        let store = RemoteEditorStore(persistURL: url, restore: false), doc = draft()
        store.documents = [doc]
        let first = try XCTUnwrap(store.presentation(for: doc.id))
        let text = first.editor
        text.setSelectedRange(NSRange(location: text.string.utf16.count, length: 0))
        text.insertText("\nappended", replacementRange: text.selectedRange())
        let edited = text.string
        XCTAssertNotEqual(edited, doc.text)
        XCTAssertTrue(text.undoManager?.canUndo == true)
        first.update(text: edited, search: "中文", searchStep: 0)
        let selected = text.selectedRange()
        XCTAssertEqual((text.string as NSString).substring(with: selected), "中文")
        let flushed = await store.flushDrafts()
        XCTAssertTrue(flushed)
        XCTAssertTrue(first === store.presentation(for: doc.id))
        XCTAssertEqual(text.selectedRange(), selected)
        XCTAssertTrue(text.undoManager?.canUndo == true)
        let other = draft("other document")
        store.documents.append(other); _ = store.presentation(for: other.id)
        XCTAssertTrue(first === store.presentation(for: doc.id))
        XCTAssertEqual(text.string, edited)
        text.undoManager?.undo()
        XCTAssertEqual(text.string, doc.text)
        _ = await store.shutdownAndFlush()
    }
    @MainActor func testMarkedTextIsNotRewrittenBySearchOrExternalRefresh() {
        let presentation = RemoteEditorPresentation(text: "before")
        let editor = presentation.editor
        editor.setSelectedRange(NSRange(location: 6, length: 0))
        editor.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: editor.selectedRange())
        XCTAssertTrue(editor.hasMarkedText())
        let marked = editor.markedRange(), content = editor.string
        presentation.update(text: "external version", search: "before", searchStep: 1)
        XCTAssertEqual(editor.string, content)
        XCTAssertEqual(editor.markedRange(), marked)
        editor.unmarkText()
        presentation.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        XCTAssertEqual(editor.string, "external version")
        presentation.invalidate()
    }
    @MainActor func testLatestDraftFlushWinsAndPersistenceFailurePreservesDocument() async throws {
        let root = try temporaryDirectory(), url = root.appendingPathComponent("documents.json")
        let store = RemoteEditorStore(persistURL: url, restore: false), doc = draft()
        store.documents = [doc]
        for value in 0..<40 { store.updateText("latest \(value)", id: doc.id); store.persist() }
        let flushed = await store.shutdownAndFlush()
        XCTAssertTrue(flushed)
        let restored = RemoteEditorStore(persistURL: url)
        XCTAssertEqual(restored.documents.first?.text, "latest 39")
        XCTAssertTrue(restored.documents.first?.isDirty == true)
        let failure = RemoteEditorStore(persistURL: root.appendingPathComponent("missing/documents.json"), restore: false)
        failure.documents = [doc]
        let failed = await failure.flushDrafts()
        XCTAssertFalse(failed); XCTAssertNotNil(failure.error); XCTAssertEqual(failure.documents.first?.text, doc.text)
    }
    @MainActor func testTerminationPreparationFreezesDraftUntilCancelled() async throws {
        let root = try temporaryDirectory()
        let missing = root.appendingPathComponent("missing/documents.json")
        let store = RemoteEditorStore(persistURL: missing, restore: false)
        let original = draft("latest local draft")
        store.documents = [original]

        let prepared = await store.prepareForApplicationTermination()
        XCTAssertFalse(prepared)
        XCTAssertTrue(store.preparingForApplicationTermination)
        store.updateText("must not replace frozen snapshot", id: original.id)
        XCTAssertEqual(store.documents.first?.text, "latest local draft")

        store.cancelApplicationTermination()
        XCTAssertFalse(store.preparingForApplicationTermination)
        store.updateText("editing resumed", id: original.id)
        XCTAssertEqual(store.documents.first?.text, "editing resumed")
    }
    @MainActor func testShutdownProgressOnlyPresentsWhenDelaySchedulerFires() {
        let manual = ManualShutdownProgressScheduler()
        let probe = ShutdownProgressProbe()
        let controller = ShutdownProgressDelayController(scheduler: manual.scheduler())

        controller.schedule { probe.presentations += 1 }
        XCTAssertEqual(ShutdownProgressScheduler.delay, .milliseconds(300))
        XCTAssertEqual(probe.presentations, 0, "Fast shutdown must not flash a progress panel")
        manual.fire()
        XCTAssertEqual(probe.presentations, 1)

        controller.schedule { probe.presentations += 1 }
        controller.cancel()
        manual.fire()
        XCTAssertEqual(probe.presentations, 1, "A completed shutdown must invalidate a late presentation callback")
    }
    func testShutdownCoordinatorSharesOneDeadlineAcrossComponents() async {
        let clock = ContinuousClock()
        let started = clock.now
        let report = await AppShutdownCoordinator.run(
            operations: [
                AppShutdownOperation(component: .monitoring) { _ in .completed },
                AppShutdownOperation(component: .directorySync) { deadline in
                    let operationClock = ContinuousClock()
                    if operationClock.now < deadline {
                        try? await operationClock.sleep(until: deadline)
                    }
                    return .timedOut
                }
            ],
            timeout: .milliseconds(60)
        )
        let elapsed = started.duration(to: clock.now)

        XCTAssertLessThan(elapsed.seconds, 0.3)
        XCTAssertTrue(report.reachedDeadline)
        XCTAssertEqual(report.results.first(where: { $0.component == .monitoring })?.outcome, .completed)
        XCTAssertEqual(report.results.first(where: { $0.component == .directorySync })?.outcome, .timedOut)
    }
    func testShutdownCoordinatorReturnsWhenComponentIgnoresCancellation() async {
        let clock = ContinuousClock()
        let started = clock.now
        let report = await AppShutdownCoordinator.run(
            operations: [
                AppShutdownOperation(component: .recordings) { _ in
                    await withCheckedContinuation { continuation in
                        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.4) {
                            continuation.resume()
                        }
                    }
                    return .completed
                }
            ],
            timeout: .milliseconds(40)
        )

        XCTAssertLessThan(started.duration(to: clock.now), .milliseconds(200))
        XCTAssertEqual(report.results.first?.outcome, .timedOut)
    }
    func testWriterRejectsOlderRevisionAfterNewerFlush() async throws {
        let url = try temporaryDirectory().appendingPathComponent("documents.json"), writer = RemoteDraftWriter()
        let new = draft("new"), old = draft("old")
        _ = try await writer.write(documents: [new], copies: [], url: url, copiesURL: nil, revision: 2)
        _ = try await writer.write(documents: [old], copies: [], url: url, copiesURL: nil, revision: 1)
        let restored = try JSONDecoder().decode([RemoteEditorDraft].self, from: Data(contentsOf: url))
        XCTAssertEqual(restored.first?.text, "new")
    }
    @MainActor func testTenThousandItemSFTPFilteringSelectionBenchmark() throws {
        let app = AppState(trustCoordinator: HostTrustCoordinator(), fileServicesEnabled: false)
        let server = ServerRecord(name: "10k file fixture", host: "fixture.invalid", username: "fixture")
        let controller = MacSFTPController(server: server, appState: app, automaticallyConnect: false)
        defer { controller.close() }
        let items = (0..<10_000).map { index -> RemoteFileItem in
            let name: String
            if index.isMultiple(of: 10) {
                name = ".hidden-\(index).log"
            } else if index % 20 == 1 {
                name = "needle-中文-\(index).conf"
            } else {
                name = "service-\(index).txt"
            }
            return RemoteFileItem(
                path: "/fixture/\(name)",
                name: name,
                kind: .file,
                size: Int64(index),
                permissions: "rw-r--r--",
                owner: "fixture",
                group: "fixture",
                modifiedText: "2026-09-21"
            )
        }

        let listingStart = ProcessInfo.processInfo.systemUptime
        controller.applyDirectoryListing(.init(path: "/fixture", items: items))
        let listingMS = (ProcessInfo.processInfo.systemUptime - listingStart) * 1_000
        XCTAssertEqual(controller.visibleItems.count, 9_000)

        let showHiddenStart = ProcessInfo.processInfo.systemUptime
        controller.showHidden = true
        let showHiddenMS = (ProcessInfo.processInfo.systemUptime - showHiddenStart) * 1_000
        XCTAssertEqual(controller.visibleItems.count, 10_000)

        let hidden = try XCTUnwrap(items.first { $0.name.hasPrefix(".hidden") })
        let needle = try XCTUnwrap(items.first { $0.name.hasPrefix("needle") })
        let ordinary = try XCTUnwrap(items.first { $0.name.hasPrefix("service") })
        controller.selection = [hidden.id, needle.id, ordinary.id]
        let hideHiddenStart = ProcessInfo.processInfo.systemUptime
        controller.showHidden = false
        let hideHiddenMS = (ProcessInfo.processInfo.systemUptime - hideHiddenStart) * 1_000
        XCTAssertEqual(controller.selection, [needle.id, ordinary.id])

        let searchStart = ProcessInfo.processInfo.systemUptime
        controller.search = "needle-中文"
        let searchMS = (ProcessInfo.processInfo.systemUptime - searchStart) * 1_000
        XCTAssertEqual(controller.visibleItems.count, 500)
        XCTAssertEqual(controller.selection, [needle.id])

        let clearSearchStart = ProcessInfo.processInfo.systemUptime
        controller.search = ""
        let clearSearchMS = (ProcessInfo.processInfo.systemUptime - clearSearchStart) * 1_000
        XCTAssertEqual(controller.visibleItems.count, 9_000)
        XCTAssertEqual(controller.selection, [needle.id], "Clearing a filter must not restore previously pruned selections")

        let totalMS = listingMS + showHiddenMS + hideHiddenMS + searchMS + clearSearchMS
        XCTAssertLessThan(totalMS, 5_000, "Synthetic filtering should not monopolize the main actor for multiple seconds")
        let report: [String: Any] = [
            "items": items.count,
            "mainThread": Thread.isMainThread,
            "listingMilliseconds": listingMS,
            "showHiddenMilliseconds": showHiddenMS,
            "hideHiddenMilliseconds": hideHiddenMS,
            "searchMilliseconds": searchMS,
            "clearSearchMilliseconds": clearSearchMS,
            "totalMeasuredMilliseconds": totalMS,
            "visibleNeedleCount": 500,
            "selectionPruningVerified": true,
            "notes": "In-memory isolated MacSFTPController listing; measures synchronous main-actor projection updates without network or user data."
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let url = URL(fileURLWithPath: "/tmp/serverdash-sftp-list-benchmark.json")
        try data.write(to: url, options: .atomic)
        print("SFTP_LIST_BENCHMARK \(String(decoding: data, as: UTF8.self)); report=\(url.path)")
    }
    func testLargeFileIndexBenchmarkAndHighlightFallback() throws {
        let text = String(repeating: "let 中文配置 = 123 // comment\n", count: 50_000), value = text as NSString
        let offsets = (0..<100).map { value.length - 1 - $0 * 10 }
        var baselineChecksum = 0, optimizedChecksum = 0
        let before = ContinuousClock.now
        for offset in offsets { baselineChecksum += value.substring(to: offset).components(separatedBy: "\n").count }
        let baseline = before.duration(to: .now)
        let index = EditorLineIndex(text), after = ContinuousClock.now
        for offset in offsets { optimizedChecksum += index.line(at: offset) }
        let optimized = after.duration(to: .now)
        XCTAssertEqual(baselineChecksum, optimizedChecksum)
        XCTAssertTrue(try EditorSyntax.highlights(text).isEmpty)
        var edited = text, incremental = index
        let baselineEditStart = ContinuousClock.now
        for _ in 0..<30 {
            edited.append("tail\n")
            _ = EditorLineIndex(edited)
        }
        let baselineEdits = baselineEditStart.duration(to: .now)
        let incrementalStart = ContinuousClock.now
        for _ in 0..<30 { incremental.replace(NSRange(location: incremental.length, length: 0), with: "tail\n") }
        let incrementalEdits = incrementalStart.duration(to: .now)
        XCTAssertEqual(incremental.starts, EditorLineIndex(edited).starts)
        let result: [String: Any] = ["utf16Units": value.length, "lookups": offsets.count, "baselineSeconds": baseline.seconds, "cachedSeconds": optimized.seconds, "baselineIndexEditsSeconds": baselineEdits.seconds, "incrementalIndexEditsSeconds": incrementalEdits.seconds, "edits": 30, "checksum": optimizedChecksum, "note": "Same 100 gutter lookups near EOF; baseline scans NSString prefix, optimized binary-searches cached line starts. Large file syntax skips matching."]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("serverdash-editor-polish-benchmark.json")
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        print("EDITOR_BENCHMARK \(result)")
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
#endif
