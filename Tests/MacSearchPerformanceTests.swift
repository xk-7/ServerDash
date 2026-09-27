#if os(macOS)
import AppKit
import SwiftTerm
import XCTest
@testable import ServerDash

final class MacSearchPerformanceTests: XCTestCase {
    func testLargeEditorQAFixturesHaveBoundedExactSizes() {
        XCTAssertEqual(MacUIFixture.editorFixtureText(size: "1300000").utf16.count, 1_300_000)
        XCTAssertEqual(MacUIFixture.editorFixtureText(size: "8mib").utf8.count, 8 * 1_024 * 1_024)
        XCTAssertLessThan(MacUIFixture.editorFixtureText(size: "999999999999").utf8.count, 1_024)
        XCTAssertFalse(MacUIFixture.isEnabled, "Production test host cannot enable the QA route")
    }

    func testIndexPreservesUTF16CaseAndExactCap() throws {
        let text = "😀 中文 e\u{301} NEEDLE needle"
        let index = try EditorSearchIndex.build(text: text, query: "needle", revision: 7)
        let expected = (text as NSString).range(of: "NEEDLE")
        XCTAssertEqual(index.revision, 7)
        XCTAssertEqual(index.ranges.first, expected)
        XCTAssertEqual(index.feedback(at: expected.location), .matches(current: 1, total: 2, hasMore: false))
        XCTAssertEqual(index.feedback(at: expected.location + 1), .matches(current: 0, total: 2, hasMore: false))
        let exact = try EditorSearchIndex.build(text: String(repeating: "x ", count: 10_000), query: "x", revision: 0)
        XCTAssertEqual(exact.ranges.count, 10_000)
        XCTAssertFalse(exact.hasMore)
    }

    func testDirectionalNavigationReachesPastCountCapAndWrapsBothWays() throws {
        let text = String(repeating: "😀x ", count: 10_005)
        let index = try EditorSearchIndex.build(text: text, query: "x", revision: 0)
        XCTAssertTrue(index.hasMore)
        let lastCached = try XCTUnwrap(index.ranges.last)
        XCTAssertNil(index.cachedMatch(from: lastCached, backwards: false))
        var match = lastCached
        for _ in 0..<5 {
            match = try XCTUnwrap(EditorSearchIndex.directionalMatch(text: text, query: "x", selection: match, backwards: false))
        }
        XCTAssertEqual(match, NSRange(location: 10_004 * 4 + 2, length: 1))
        let wrapped = try XCTUnwrap(EditorSearchIndex.directionalMatch(text: text, query: "x", selection: match, backwards: false))
        XCTAssertEqual(wrapped, index.ranges.first)
        XCTAssertEqual(try EditorSearchIndex.directionalMatch(text: text, query: "x", selection: wrapped, backwards: true), match)
    }

    func testArbitraryCaretAndBackwardsNavigationPreserveOverlappingSemantics() throws {
        let index = try EditorSearchIndex.build(text: "aaa", query: "aa", revision: 0)
        let caret = NSRange(location: 1, length: 0)
        XCTAssertNil(index.cachedMatch(from: caret, backwards: false))
        XCTAssertEqual(try EditorSearchIndex.directionalMatch(text: "aaa", query: "aa", selection: caret, backwards: false), NSRange(location: 1, length: 2))
        XCTAssertNil(index.cachedMatch(from: .init(location: 3, length: 0), backwards: true))
        XCTAssertEqual(try EditorSearchIndex.directionalMatch(text: "aaa", query: "aa", selection: .init(location: 3, length: 0), backwards: true), NSRange(location: 1, length: 2))
    }

    func testCancelledSearchCannotReturnAResult() async {
        let cancelled = await Task.detached { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try EditorSearchIndex.build(text: "needle", query: "needle", revision: 0); return false }
            catch is CancellationError { return true }
            catch { return false }
        }.value
        XCTAssertTrue(cancelled)
    }

    @MainActor func testCursorMovementReusesIndexAndRapidNavigationKeepsEveryStep() async throws {
        let text = "one one one one one", presentation = RemoteEditorPresentation(text: "one one one one one")
        defer { presentation.invalidate() }
        var feedback: EditorSearchFeedback?
        presentation.onSearchFeedbackChange = { _, value in feedback = value }
        presentation.update(text: text, search: "one", searchStep: 0)
        presentation.update(text: text, search: "one", searchStep: 1)
        presentation.update(text: text, search: "one", searchStep: 2)
        presentation.update(text: text, search: "one", searchStep: 3)
        // The build counter increments when background work starts. Await the
        // completed index's public callback, not that earlier scheduling event.
        try await waitUntil {
            presentation.editor.selectedRange().location == 12
                && feedback == .matches(current: 4, total: 5, hasMore: false)
        }
        for location in [0, 4, 8, 12, 16] {
            presentation.editor.setSelectedRange(.init(location: location, length: 3))
            presentation.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification))
        }
        XCTAssertEqual(feedback, .matches(current: 5, total: 5, hasMore: false))
        XCTAssertEqual(presentation.searchIndexBuildCount, 1)
        presentation.update(text: text, search: "one", searchStep: 4)
        try await waitUntil { presentation.editor.selectedRange().location == 0 }
        XCTAssertEqual(presentation.searchIndexBuildCount, 1)
    }

    @MainActor func testIndexCompletionReportsLatestSelectionInsteadOfInitialCaret() async throws {
        let text = "one one one", presentation = RemoteEditorPresentation(text: "one one one")
        defer { presentation.invalidate() }
        var feedback: EditorSearchFeedback?
        presentation.onSearchFeedbackChange = { _, value in feedback = value }
        presentation.update(text: text, search: "one", searchStep: 0)
        // The task cannot have built its index before this actor yields. A user
        // selection wins over pending navigation and is read at index completion.
        presentation.editor.setSelectedRange(.init(location: 8, length: 3))
        presentation.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification))
        try await waitUntil { feedback == .matches(current: 3, total: 3, hasMore: false) }
        XCTAssertEqual(presentation.editor.selectedRange(), .init(location: 8, length: 3))
        XCTAssertEqual(presentation.searchIndexBuildCount, 1)
    }

    @MainActor func testStaleSearchAndUserSelectionDoNotMoveCursor() async throws {
        let text = "before target after final", presentation = RemoteEditorPresentation(text: "before target after final")
        defer { presentation.invalidate() }
        presentation.update(text: text, search: "target", searchStep: 0)
        presentation.update(text: text, search: "final", searchStep: 0)
        try await waitUntil { presentation.editor.selectedRange().location == 20 }
        presentation.update(text: text, search: "target", searchStep: 0)
        presentation.editor.setSelectedRange(.init(location: 0, length: 0))
        presentation.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(presentation.editor.selectedRange(), .init(location: 0, length: 0))
        var calls = 0
        presentation.onSearchFeedbackChange = { _, _ in calls += 1 }
        presentation.update(text: text, search: "after", searchStep: 0)
        presentation.invalidate()
        let before = calls
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(calls, before)
    }

    func testHighlightCacheEvictsOneLineAtCapacity() {
        var cache = MacTerminalHighlightCache<Int, Int>()
        for value in 0..<256 { cache.insert(value, for: value) }
        cache.insert(256, for: 256)
        XCTAssertEqual(cache.count, 256)
        XCTAssertNil(cache[0])
        for value in 1...256 { XCTAssertEqual(cache[value], value) }
        cache.insert(999, for: 256)
        XCTAssertEqual(cache.count, 256)
        XCTAssertEqual(cache[256], 999)
    }

    @MainActor func testTerminalHitAvoidsColumnMappingAndCompilesSearchOnce() throws {
        let (view, tools, defaults, suite) = try terminalFixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        tools.searchText = "needle"
        view.feed(text: "中文 😀 needle needle")
        let line = try XCTUnwrap(view.getTerminal().getLine(row: 0))
        let first = try XCTUnwrap(view.cellHighlights?(line))
        let count = tools.highlightColumnMapBuildCount
        for _ in 0..<40 { XCTAssertEqual(view.cellHighlights?(line).map(\.columns), first.map(\.columns)) }
        XCTAssertEqual(tools.highlightColumnMapBuildCount, count)
        XCTAssertEqual(tools.searchExpressionBuildCount, 1)
        tools.searchText = "needle"
        _ = view.cellHighlights?(line)
        XCTAssertEqual(tools.highlightColumnMapBuildCount, count)
        XCTAssertEqual(tools.searchExpressionBuildCount, 1)
        tools.searchText = "中文"
        _ = view.cellHighlights?(line)
        XCTAssertEqual(tools.searchExpressionBuildCount, 2)
    }

    @MainActor func testTerminalCacheSeparatesEqualTextWithDifferentCellLayouts() throws {
        let (view, tools, defaults, suite) = try terminalFixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        tools.searchText = "a"
        let narrow = BufferLine(cols: 3), wide = BufferLine(cols: 4), terminal = view.getTerminal()
        narrow[0] = cell("a", width: 1, terminal: terminal); narrow[1] = cell("b", width: 1, terminal: terminal); narrow[2] = cell("c", width: 1, terminal: terminal)
        wide[0] = cell("a", width: 2, terminal: terminal); wide[1] = cell("\0", width: 0, terminal: terminal)
        wide[2] = cell("b", width: 1, terminal: terminal); wide[3] = cell("c", width: 1, terminal: terminal)
        XCTAssertEqual(view.cellHighlights?(narrow).first?.columns, 0..<1)
        XCTAssertEqual(view.cellHighlights?(wide).first?.columns, 0..<2)
        XCTAssertEqual(tools.highlightColumnMapBuildCount, 2)
    }

    /// Run this suite in the same optimized test host as the baseline. No timing
    /// assertions are used: percentile results are reviewed for stable regressions.
    func testEditorSearchCursorBenchmark() throws {
        var fixtures: [[String: Any]] = []
        for size in [1_300_000, 8 * 1_024 * 1_024] {
            let row = "needle " + String(repeating: "x", count: size / 1_000 - 8) + "\n"
            let text = String(repeating: row, count: 1_000)
            let index = try EditorSearchIndex.build(text: text, query: "needle", revision: 0)
            let locations = (0..<12).map { index.ranges[$0 * 80].location }
            var checksum = 0
            let baseline = try sample {
                for location in locations { checksum += try Self.legacySearchCount(text: text, query: "needle", selectedLocation: location) }
            }
            let optimized = try sample {
                for location in locations {
                    if case .matches(let current, _, _) = index.feedback(at: location) { checksum += current }
                }
            }
            let build = try sample { checksum += try EditorSearchIndex.build(text: text, query: "needle", revision: 0).ranges.count }
            XCTAssertGreaterThan(checksum, 0)
            fixtures.append(["utf16Units": text.utf16.count, "cursorMovesPerSample": locations.count,
                             "baseline": baseline, "cached": optimized, "indexBuild": build])
        }
        try report("editor-search", data: ["fixtures": fixtures, "warmups": 3, "iterations": 30,
                   "note": "Exact prior capped case-insensitive counting versus cached binary search, excluding UI/AX and debounce. Index construction reported separately."])
    }

    @MainActor func testTerminalHighlightHotCacheBenchmark() throws {
        var fixtures: [[String: Any]] = []
        for panels in [1, 4, 16] {
            let (view, tools, defaults, suite) = try terminalFixture()
            defer { defaults.removePersistentDomain(forName: suite) }
            tools.searchText = "needle"
            let terminal = view.getTerminal(), legacy = LegacyTerminalSearchHighlighter()
            var lines: [BufferLine] = []
            for index in 0..<32 {
                let text = "中文 😀 needle \(index) " + String(repeating: "plain text ", count: 10)
                let line = BufferLine(cols: text.count)
                for (column, char) in text.enumerated() { line[column] = terminal.makeCharData(attribute: .empty, char: char, size: 1) }
                lines.append(line)
            }
            for line in lines {
                XCTAssertEqual(view.cellHighlights?(line).map(\.columns), legacy.highlights(line, terminal: terminal).map(\.columns))
            }
            var checksum = 0
            let baseline = try sample {
                for _ in 0..<panels { for line in lines { checksum += legacy.highlights(line, terminal: terminal).count } }
            }
            let optimized = try sample {
                for _ in 0..<panels { for line in lines { checksum += view.cellHighlights?(line).count ?? 0 } }
            }
            XCTAssertGreaterThan(checksum, 0)
            XCTAssertEqual(tools.searchExpressionBuildCount, 1)
            fixtures.append(["panels": panels, "linesPerPanel": lines.count, "baseline": baseline, "cached": optimized])
        }
        try report("terminal-highlight", data: ["fixtures": fixtures, "warmups": 3, "iterations": 30,
                   "note": "Exact prior line text/UTF16 mapping and search regex algorithm versus real TerminalTools callback. Synthetic hot display rows; excludes PTY ingestion, rendering and GPU."])
    }

    private func sample(_ operation: () throws -> Void) throws -> [String: Double] {
        for _ in 0..<3 { try operation() }
        var samples: [Double] = []
        for _ in 0..<30 {
            let start = ContinuousClock.now
            try operation()
            let duration = start.duration(to: .now)
            samples.append(Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15)
        }
        samples.sort()
        return ["medianMS": (samples[14] + samples[15]) / 2, "p95MS": samples[28], "maxMS": samples[29]]
    }
    private func report(_ name: String, data: [String: Any]) throws {
        var payload = data
        payload["testHostResourceUsage"] = MacPerformanceResourceMetrics.cumulativeTestHostSnapshot()
        let bytes = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("serverdash-\(name)-benchmark.json")
        try bytes.write(to: url, options: .atomic)
        print("SEARCH_PERFORMANCE_BENCHMARK \(name): \(String(decoding: bytes, as: UTF8.self)); report=\(url.path)")
    }
    private static func legacySearchCount(text: String, query: String, selectedLocation: Int) throws -> Int {
        let value = text as NSString
        var cursor = 0, count = 0, current = 0
        while cursor < value.length {
            if count.isMultiple(of: 128) { try Task.checkCancellation() }
            let match = value.range(of: query, options: .caseInsensitive, range: NSRange(location: cursor, length: value.length - cursor))
            guard match.location != NSNotFound else { break }
            count += 1
            if match.location == selectedLocation { current = count }
            cursor = max(NSMaxRange(match), cursor + 1)
            if count == 10_000 { return current }
        }
        return current
    }
    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }
    @MainActor private func terminalFixture() throws -> (SwiftTerm.TerminalView, TerminalTools, UserDefaults, String) {
        let suite = "ServerDash-search-performance-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let settings = TerminalHighlightSettings(defaults: defaults)
        settings.rules = []
        let view = SwiftTerm.TerminalView(frame: .init(x: 0, y: 0, width: 1_000, height: 600))
        let tools = TerminalTools(serverID: UUID(), history: CommandHistoryStore(defaults: defaults), highlightSettings: settings)
        tools.attach(view)
        return (view, tools, defaults, suite)
    }
    private func cell(_ char: UnicodeScalar, width: Int8, terminal: Terminal) -> CharData {
        terminal.makeCharData(attribute: .empty, scalar: char, size: width)
    }
}

/// Prior implementation's steady-state path, with the same empty preset set as
/// the optimized fixture. This deliberately retains getData/columns allocation.
@MainActor private final class LegacyTerminalSearchHighlighter {
    private var cache: [String: [TerminalCellHighlight]] = [:]
    func highlights(_ line: BufferLine, terminal: Terminal) -> [TerminalCellHighlight] {
        var text = "", columns: [Int] = []
        for (column, data) in line.getData().prefix(2048).enumerated() {
            if line.getWidth(index: column) == 0 { continue }
            let char = terminal.getCharacter(for: data)
            let string = char == "\0" ? " " : String(char)
            text += string
            columns += Array(repeating: column, count: string.utf16.count)
        }
        columns.append(min(line.count, 2048))
        if let cached = cache[text] { return cached }
        var result: [TerminalCellHighlight] = [], occupied = IndexSet()
        let range = NSRange(location: 0, length: text.utf16.count)
        let deadline = Date.timeIntervalSinceReferenceDate + 0.004
        let expression = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: "needle"), options: .caseInsensitive)
        expression?.enumerateMatches(in: text, options: .reportProgress, range: range) { match, _, stop in
            if Date.timeIntervalSinceReferenceDate > deadline || result.count >= 128 { stop.pointee = true; return }
            guard let match, match.range.length > 0, NSMaxRange(match.range) < columns.count else { return }
            let start = columns[match.range.location], end = columns[NSMaxRange(match.range)]
            guard start < end, !occupied.intersects(integersIn: start..<end) else { return }
            occupied.insert(integersIn: start..<end)
            result.append(.init(columns: start..<end, color: CGColor(red: 1, green: 0.8, blue: 0.1, alpha: 0.55)))
        }
        if cache.count >= 256 { cache.removeAll(keepingCapacity: true) }
        cache[text] = result
        return result
    }
}
#endif
