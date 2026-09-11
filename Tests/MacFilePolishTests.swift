#if os(macOS)
import AppKit
import XCTest
@testable import ServerDash

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
    func testWriterRejectsOlderRevisionAfterNewerFlush() async throws {
        let url = try temporaryDirectory().appendingPathComponent("documents.json"), writer = RemoteDraftWriter()
        let new = draft("new"), old = draft("old")
        _ = try await writer.write(documents: [new], copies: [], url: url, copiesURL: nil, revision: 2)
        _ = try await writer.write(documents: [old], copies: [], url: url, copiesURL: nil, revision: 1)
        let restored = try JSONDecoder().decode([RemoteEditorDraft].self, from: Data(contentsOf: url))
        XCTAssertEqual(restored.first?.text, "new")
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
