#if os(macOS)
import AppKit
import SwiftUI

/// UTF-16 line starts are updated from the edited range, never by scanning the
/// document prefix while drawing a gutter or scrolling near the end of a file.
struct EditorLineIndex: Sendable {
    private(set) var starts: [Int] = [0]
    private(set) var length = 0
    init(_ text: String = "") {
        let units = text.utf16
        length = units.count
        for (offset, unit) in units.enumerated() where unit == 10 { starts.append(offset + 1) }
    }
    mutating func replace(_ range: NSRange, with replacement: String) {
        let end = NSMaxRange(range), units = Array(replacement.utf16), delta = units.count - range.length
        let lower = upperBound(range.location), upper = upperBound(end)
        let inserted = units.enumerated().compactMap { $0.element == 10 ? range.location + $0.offset + 1 : nil }
        starts.replaceSubrange(lower..<upper, with: inserted)
        for index in (lower + inserted.count)..<starts.count { starts[index] += delta }
        length += delta
    }
    func line(at offset: Int) -> Int { max(1, upperBound(max(0, min(offset, length)))) }
    private func upperBound(_ value: Int) -> Int {
        var low = 0, high = starts.count
        while low < high { let middle = (low + high) / 2; if starts[middle] <= value { low = middle + 1 } else { high = middle } }
        return low
    }
}

struct EditorHighlight: Sendable { var range: NSRange; var style: Int }

enum EditorSearchFeedback: Equatable, Sendable {
    case idle
    case noMatches
    case matches(current: Int, total: Int, hasMore: Bool)

    var label: String {
        switch self {
        case .idle: return ""
        case .noMatches: return "无匹配"
        case .matches(let current, let total, let hasMore):
            let count = hasMore ? "\(total)+" : "\(total)"
            return current > 0 ? "\(current) / \(count) 处" : "共 \(count) 处匹配"
        }
    }

    static func scan(text: String, query: String, selectedLocation: Int) throws -> Self {
        try EditorSearchIndex.build(text: text, query: query, revision: 0).feedback(at: selectedLocation)
    }
}

/// Immutable document-version/query snapshot. Cursor movement is a binary search,
/// not another document scan. A capped index never limits search navigation.
struct EditorSearchIndex: Sendable {
    static let maximumMatches = 10_000
    let revision: UInt64
    let query: String
    let ranges: [NSRange]
    let hasMore: Bool

    static func build(text: String, query: String, revision: UInt64) throws -> Self {
        let interval = PerformanceTrace.begin(.editorSearch)
        defer { PerformanceTrace.end(interval) }
        guard !query.isEmpty else { return .init(revision: revision, query: query, ranges: [], hasMore: false) }
        let value = text as NSString
        var cursor = 0, matches: [NSRange] = []
        while cursor < value.length {
            if matches.count.isMultiple(of: 128) { try Task.checkCancellation() }
            let match = value.range(of: query, options: .caseInsensitive,
                                    range: NSRange(location: cursor, length: value.length - cursor))
            guard match.location != NSNotFound else { break }
            if matches.count == maximumMatches {
                return .init(revision: revision, query: query, ranges: matches, hasMore: true)
            }
            matches.append(match)
            cursor = max(NSMaxRange(match), cursor + 1)
        }
        try Task.checkCancellation()
        return .init(revision: revision, query: query, ranges: matches, hasMore: false)
    }

    func feedback(at location: Int) -> EditorSearchFeedback {
        guard !query.isEmpty else { return .idle }
        guard !ranges.isEmpty else { return .noMatches }
        let index = lowerBound(location)
        let current = index < ranges.count && ranges[index].location == location ? index + 1 : 0
        return .matches(current: current, total: ranges.count, hasMore: hasMore)
    }

    /// nil means a directional background lookup is required, including the
    /// uncached tail and backwards searches that may find overlapping matches.
    func cachedMatch(from selection: NSRange, backwards: Bool) -> NSRange? {
        guard !ranges.isEmpty else { return nil }
        if backwards { return nil }
        let selectedIndex = lowerBound(selection.location)
        guard selection == NSRange(location: 0, length: 0)
                || (selectedIndex < ranges.count && ranges[selectedIndex] == selection) else { return nil }
        let index = lowerBound(NSMaxRange(selection))
        if index < ranges.count { return ranges[index] }
        return hasMore ? nil : ranges.first
    }

    private func lowerBound(_ location: Int) -> Int {
        var low = 0, high = ranges.count
        while low < high {
            let middle = (low + high) / 2
            if ranges[middle].location < location { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// Kept separate from the bounded counter: every match remains reachable.
    /// NSString preserves the existing case-insensitive UTF-16/overlap semantics.
    static func directionalMatch(text: String, query: String, selection: NSRange, backwards: Bool) throws -> NSRange? {
        try Task.checkCancellation()
        guard !query.isEmpty else { return nil }
        let interval = PerformanceTrace.begin(.editorSearch)
        defer { PerformanceTrace.end(interval) }
        let value = text as NSString
        let start = min(value.length, max(0, backwards ? selection.location : NSMaxRange(selection)))
        let scope = backwards ? NSRange(location: 0, length: start) : NSRange(location: start, length: value.length - start)
        var options: NSString.CompareOptions = [.caseInsensitive]
        if backwards { options.insert(.backwards) }
        var result = value.range(of: query, options: options, range: scope)
        if result.location == NSNotFound { result = value.range(of: query, options: options) }
        try Task.checkCancellation()
        return result.location == NSNotFound ? nil : result
    }
}

enum EditorSyntax {
    static let maximumLength = 200_000
    // NSRegularExpression is immutable and safe for concurrent matching.
    static let expressions: [NSRegularExpression] = [
        #"</?[A-Za-z][A-Za-z0-9:-]*"#,
        #"\b[A-Za-z_][\w-]*(?=\s*[:=])"#,
        #"\b(?:if|else|for|while|return|func|function|class|struct|import|from|let|var|const|true|false|null|nil|def|try|catch|throw|async|await|public|private)\b"#,
        #"\b[0-9]+(?:\.[0-9]+)?\b"#,
        #"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'"#,
        #"(?m)(?://[^\n]*|#[^\n]*|<!--[^\n]*-->)"#
    ].compactMap { try? NSRegularExpression(pattern: $0) }
    static func highlights(_ text: String) throws -> [EditorHighlight] {
        let range = NSRange(location: 0, length: text.utf16.count)
        guard range.length < maximumLength else { return [] }
        var result: [EditorHighlight] = []
        for (style, expression) in expressions.enumerated() {
            try Task.checkCancellation()
            expression.enumerateMatches(in: text, range: range) { match, _, stop in
                if Task.isCancelled { stop.pointee = true; return }
                if let match { result.append(EditorHighlight(range: match.range, style: style)) }
            }
        }
        try Task.checkCancellation()
        return result
    }
    @MainActor static let colors: [NSColor] = [.systemOrange, .systemTeal, .systemPurple, .systemOrange, .systemGreen, .secondaryLabelColor]
}

@MainActor private final class RemoteDocumentTextView: NSTextView {
    // A window-level undo manager would mix edits from different document tabs.
    private let documentUndoManager = UndoManager()
    override var undoManager: UndoManager? { documentUndoManager }

    // NSTextView records edits in this manager, but does not implement undo:/redo:.
    // Without these responders, a non-NSDocument hosting window handles the menu
    // action using its unrelated (empty) manager and disables the native commands.
    @objc func undo(_ sender: Any?) {
        guard isEditable, documentUndoManager.canUndo else { return }
        documentUndoManager.undo()
    }

    @objc func redo(_ sender: Any?) {
        guard isEditable, documentUndoManager.canRedo else { return }
        documentUndoManager.redo()
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)): return isEditable && documentUndoManager.canUndo
        case #selector(redo(_:)): return isEditable && documentUndoManager.canRedo
        default: return super.validateMenuItem(menuItem)
        }
    }
}

/// Owned by the draft store, so switching tabs or dismissing/reopening the sheet
/// keeps the same text system, selection, scroll position and undo manager.
@MainActor final class RemoteEditorPresentation: NSObject, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
    let scroll = NSScrollView()
    let editor: NSTextView = RemoteDocumentTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
    private(set) var lineIndex: EditorLineIndex
    private(set) var revision: UInt64 = 0
    var onTextChange: ((String) -> Void)?
    var onMetricsChange: ((Int, Int) -> Void)?
    var onSearchFeedbackChange: ((String, EditorSearchFeedback) -> Void)?
    private var modelText: String
    private var pendingExternalText: String?
    private var highlightTask: Task<Void, Never>?
    private var searchFeedbackTask: Task<Void, Never>?
    private var searchNavigationTask: Task<Void, Never>?
    private var searchIndex: EditorSearchIndex?
    private var indexingKey: SearchKey?
    private var navigationGeneration: UInt64 = 0
    private var initialSearchPending = false
    private var activeNavigationStep: Int?
    private(set) var searchIndexBuildCount = 0
    private struct SearchKey: Equatable { let revision: UInt64; let query: String }
    private var hasHighlights = false
    private var lastSearch = ""
    private var lastSearchStep = 0
    private var desiredSearch = ""
    private var desiredSearchStep = 0
    private var applyingExternal = false

    init(text: String) {
        modelText = text; lineIndex = EditorLineIndex(text)
        super.init()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        editor.isRichText = false; editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false; editor.isContinuousSpellCheckingEnabled = false
        editor.allowsUndo = true; editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.textColor = .textColor; editor.backgroundColor = .textBackgroundColor
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = true; editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.minSize = .zero; editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.string = text; editor.delegate = self; editor.textStorage?.delegate = self
        editor.setAccessibilityLabel("远程文件正文")
        scroll.documentView = editor; scroll.hasVerticalRuler = true; scroll.rulersVisible = true
        scroll.verticalRulerView = EditorLineRuler(presentation: self)
        scheduleHighlight()
    }
    func update(text: String, search: String, searchStep: Int) {
        if text != modelText {
            if editor.hasMarkedText() { pendingExternalText = text }
            else { replaceExternalText(text) }
        }
        desiredSearch = search; desiredSearchStep = searchStep
        applySearchIfNeeded()
    }
    private func replaceExternalText(_ value: String) {
        guard editor.string != value else { modelText = value; return }
        let selection = editor.selectedRanges, origin = scroll.contentView.bounds.origin
        applyingExternal = true
        editor.string = value; modelText = value; lineIndex = EditorLineIndex(value)
        applyingExternal = false
        // This is an explicit reload, not a local edit or background save.
        editor.undoManager?.removeAllActions()
        editor.selectedRanges = selection.map { value in
            let range = value.rangeValue, start = min(range.location, lineIndex.length)
            return NSValue(range: NSRange(location: start, length: min(range.length, lineIndex.length - start)))
        }
        scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView)
        revision &+= 1; searchNavigationTask?.cancel(); activeNavigationStep = nil; navigationGeneration &+= 1
        changedMetrics(); scheduleSearchFeedback(); scheduleHighlight()
    }
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters), !applyingExternal else { return }
        let oldRange = NSRange(location: editedRange.location, length: editedRange.length - delta)
        let replacement = (textStorage.string as NSString).substring(with: editedRange)
        lineIndex.replace(oldRange, with: replacement); revision &+= 1
        highlightTask?.cancel(); searchFeedbackTask?.cancel(); indexingKey = nil
        searchNavigationTask?.cancel(); activeNavigationStep = nil; navigationGeneration &+= 1
        changedMetrics()
    }
    func textDidChange(_ notification: Notification) {
        modelText = editor.string; onTextChange?(modelText)
        guard !editor.hasMarkedText() else { return }
        if let pending = pendingExternalText { pendingExternalText = nil; replaceExternalText(pending); onTextChange?(pending) }
        applySearchIfNeeded(); scheduleSearchFeedback(); scheduleHighlight()
    }
    func textViewDidChangeSelection(_ notification: Notification) {
        guard !desiredSearch.isEmpty, !editor.hasMarkedText() else { return }
        if activeNavigationStep != nil {
            // A user selection made while background search runs wins over its result.
            searchNavigationTask?.cancel(); navigationGeneration &+= 1; activeNavigationStep = nil
            initialSearchPending = false; lastSearchStep = desiredSearchStep
        }
        publishSearchFeedback()
    }
    private func changedMetrics() {
        scroll.verticalRulerView?.needsDisplay = true
        onMetricsChange?(lineIndex.starts.count, lineIndex.length)
    }
    private func scheduleHighlight() {
        highlightTask?.cancel()
        guard lineIndex.length < EditorSyntax.maximumLength else {
            if hasHighlights { editor.layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: lineIndex.length)); hasHighlights = false }
            return
        }
        let expected = revision
        highlightTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(180))
                guard let self, !self.editor.hasMarkedText(), self.revision == expected else { return }
                let text = self.editor.string
                let work = Task.detached(priority: .utility) { try EditorSyntax.highlights(text) }
                let highlights = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                try Task.checkCancellation()
                guard self.revision == expected, !self.editor.hasMarkedText(), let manager = self.editor.layoutManager else { return }
                manager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: self.lineIndex.length))
                for item in highlights { manager.addTemporaryAttribute(.foregroundColor, value: EditorSyntax.colors[item.style], forCharacterRange: item.range) }
                self.hasHighlights = !highlights.isEmpty
            } catch { /* Cancelled/stale results never mutate the text system. */ }
        }
    }
    private func applySearchIfNeeded() {
        guard !editor.hasMarkedText() else { return }
        let changed = lastSearch != desiredSearch
        if changed {
            searchNavigationTask?.cancel(); navigationGeneration &+= 1; activeNavigationStep = nil
            lastSearch = desiredSearch; lastSearchStep = desiredSearchStep
            initialSearchPending = !desiredSearch.isEmpty
        }
        scheduleSearchFeedback()
        guard !desiredSearch.isEmpty, initialSearchPending || lastSearchStep != desiredSearchStep,
              activeNavigationStep != desiredSearchStep else { return }
        searchNavigationTask?.cancel(); navigationGeneration &+= 1
        let generation = navigationGeneration, expectedRevision = revision, query = desiredSearch
        let step = desiredSearchStep, delta = step - lastSearchStep, initial = initialSearchPending
        let selection = editor.selectedRange(), text = editor.string
        let cached = searchIndex.flatMap { $0.revision == expectedRevision && $0.query == query ? $0 : nil }
        activeNavigationStep = step
        searchNavigationTask = Task { [weak self] in
            do {
                let work = Task.detached(priority: .userInitiated) {
                    var match: NSRange? = initial
                        ? try EditorSearchIndex.directionalMatch(text: text, query: query,
                                                               selection: NSRange(location: 0, length: 0), backwards: false)
                        : selection
                    for _ in 0..<abs(delta) {
                        try Task.checkCancellation()
                        guard let current = match else { break }
                        if let hit = cached?.cachedMatch(from: current, backwards: delta < 0) { match = hit }
                        else { match = try EditorSearchIndex.directionalMatch(text: text, query: query, selection: current, backwards: delta < 0) }
                    }
                    return match
                }
                let match = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                try Task.checkCancellation()
                guard let self, self.navigationGeneration == generation, self.revision == expectedRevision,
                      self.desiredSearch == query, !self.editor.hasMarkedText() else { return }
                self.activeNavigationStep = nil; self.initialSearchPending = false; self.lastSearchStep = step
                if let match { self.editor.setSelectedRange(match); self.editor.scrollRangeToVisible(match) }
                self.publishSearchFeedback()
            } catch { /* Superseded searches cannot move the cursor. */ }
        }
    }
    private func publishSearchFeedback() {
        guard !editor.hasMarkedText() else { return }
        guard !desiredSearch.isEmpty else { onSearchFeedbackChange?("", .idle); return }
        guard let searchIndex, searchIndex.revision == revision, searchIndex.query == desiredSearch else { return }
        onSearchFeedbackChange?(desiredSearch, searchIndex.feedback(at: editor.selectedRange().location))
    }
    private func scheduleSearchFeedback() {
        let key = SearchKey(revision: revision, query: desiredSearch)
        if let searchIndex, searchIndex.revision == key.revision, searchIndex.query == key.query {
            publishSearchFeedback(); return
        }
        guard indexingKey != key else { return }
        searchFeedbackTask?.cancel(); indexingKey = nil
        guard !key.query.isEmpty else { searchIndex = nil; onSearchFeedbackChange?("", .idle); return }
        indexingKey = key
        searchFeedbackTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(80))
                guard let self else { return }
                defer { if self.indexingKey == key { self.indexingKey = nil } }
                guard self.revision == key.revision, !self.editor.hasMarkedText() else { return }
                let text = self.editor.string
                self.searchIndexBuildCount += 1
                let work = Task.detached(priority: .utility) {
                    try EditorSearchIndex.build(text: text, query: key.query, revision: key.revision)
                }
                let index = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                try Task.checkCancellation()
                guard self.revision == key.revision, self.desiredSearch == key.query, !self.editor.hasMarkedText() else { return }
                self.searchIndex = index; self.indexingKey = nil
                self.publishSearchFeedback()
            } catch { /* A newer query or edit superseded this result. */ }
        }
    }
    func invalidate() {
        highlightTask?.cancel(); searchFeedbackTask?.cancel(); searchNavigationTask?.cancel()
        navigationGeneration &+= 1; searchIndex = nil; indexingKey = nil
        onTextChange = nil; onMetricsChange = nil; onSearchFeedbackChange = nil
    }
}

private final class EditorLineRuler: NSRulerView {
    weak var presentation: RemoteEditorPresentation?
    init(presentation: RemoteEditorPresentation) {
        self.presentation = presentation
        super.init(scrollView: presentation.scroll, orientation: .verticalRuler)
        clientView = presentation.editor; ruleThickness = 56
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let presentation, let manager = presentation.editor.layoutManager, let container = presentation.editor.textContainer else { return }
        let editor = presentation.editor, visible = editor.visibleRect
        guard manager.numberOfGlyphs > 0 else { return }
        let glyphs = manager.glyphRange(forBoundingRect: visible, in: container)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        manager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, glyphRange, _ in
            let character = manager.characterIndexForGlyph(at: glyphRange.location)
            let label = "\(presentation.lineIndex.line(at: character))" as NSString
            label.draw(at: NSPoint(x: 48 - label.size(withAttributes: attributes).width, y: fragment.minY - visible.minY + editor.textContainerInset.height), withAttributes: attributes)
        }
        let trailing = manager.extraLineFragmentRect
        if manager.extraLineFragmentTextContainer != nil, trailing.intersects(visible) {
            let label = "\(presentation.lineIndex.starts.count)" as NSString
            label.draw(at: NSPoint(x: 48 - label.size(withAttributes: attributes).width, y: trailing.minY - visible.minY + editor.textContainerInset.height), withAttributes: attributes)
        }
    }
}

/// Encoding and atomic writes are serialized away from the main actor. Revisions
/// also reject late queued snapshots when a newer flush has already completed.
actor RemoteDraftWriter {
    private var savedRevision: UInt64 = 0
    func write(documents: [RemoteEditorDraft], copies: [RemoteLocalCopy], url: URL?, copiesURL: URL?, revision: UInt64) throws -> [UUID: Bool] {
        guard revision > savedRevision else { return [:] }
        let dirty = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, (try? $0.encoding.encode($0.text, bom: $0.hasBOM)) != $0.original) })
        guard let url else { return dirty }
        let documentsData = try JSONEncoder().encode(documents)
        let copiesData = try JSONEncoder().encode(copies)
        try DesktopFilePreferences.writePrivate(documentsData, to: url)
        if let copiesURL { try DesktopFilePreferences.writePrivate(copiesData, to: copiesURL) }
        savedRevision = revision
        return dirty
    }
}
#endif
