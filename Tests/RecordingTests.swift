import AppKit
import ImageIO
import SwiftTerm
import SwiftUI
import XCTest
@testable import ServerDash

private final class RecordingTestDelegate: TerminalDelegate {
    var replies = 0
    func send(source: Terminal, data: ArraySlice<UInt8>) { replies += 1 }
}

final class RecordingFormatTests: XCTestCase {
    private let delegate = RecordingTestDelegate()
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("serverdash-recording-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func terminal(columns: Int = 40, rows: Int = 5) -> Terminal {
        Terminal(delegate: delegate, options: TerminalOptions(cols: columns, rows: rows))
    }
    private func frame(_ term: Terminal) -> RecordingFrame {
        .init(screen: term.displaySnapshot(), appearance: .init(fontName: "Menlo", fontSize: 12, cellWidth: 7, cellHeight: 15))
    }
    private func text(_ frame: RecordingFrame) -> String { frame.screen.lines.flatMap(\.cells).map(\.text).joined() }
    private func file(_ events: [RecordingEvent], name: String = "test.sdrec") throws -> URL {
        let url = directory.appendingPathComponent(name)
        var data = RecordingCodec.magic
        for event in events { data.append(try RecordingCodec.encode(event)) }
        try data.write(to: url)
        return url
    }
    private func recording(duration: Double = 10) throws -> (URL, RecordingFrame, RecordingFrame) {
        let term = terminal(); term.feed(text: "first")
        let initial = frame(term)
        term.feed(text: "\r\n中文 👩🏽‍💻 e\u{301}\u{1b}[38;2;10;20;30m COLOR")
        let last = frame(term)
        var delta = last; delta.changedRows = [0, 1, 2, 3, 4]
        let header = RecordingEvent(kind: .header, time: 0, header: .init(name: "测试"))
        let first = RecordingEvent(kind: .screen, time: 0, frame: initial)
        let offset = UInt64(8 + (try RecordingCodec.encode(header)).count)
        let url = try file([header, first, .init(kind: .output, time: 0.2, output: Data("echo safe\r\n".utf8)),
                            .init(kind: .screen, time: 0.2, frame: delta),
                            .init(kind: .end, time: duration, index: [.init(time: 0, offset: offset)], reason: "user")])
        return (url, initial, last)
    }

    func testSnapshotPreservesUnicodeColorsCursorAndExcludesOldScrollback() throws {
        let term = terminal(columns: 40, rows: 3)
        term.feed(text: "HIDDEN-BEFORE-RECORDING\r\n")
        for _ in 0..<12 { term.feed(text: "new line\r\n") }
        term.feed(text: "\u{1b}[38;2;10;20;30m中👩🏽‍💻 e\u{301}")
        let value = frame(term)
        try value.validate()
        XCTAssertFalse(text(value).contains("HIDDEN-BEFORE-RECORDING"))
        XCTAssertTrue(text(value).contains("中")); XCTAssertTrue(text(value).contains("👩🏽‍💻"))
        XCTAssertTrue(value.screen.lines.flatMap(\.cells).contains { $0.text == "中" && $0.foreground == 0x0a141e && $0.width == 2 })
        let decoded = try JSONDecoder().decode(RecordingFrame.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(decoded, value)
    }
    func testAlternateScreenResizeAndInitialTUICapture() throws {
        let term = terminal(); term.feed(text: "main\u{1b}[?1049h\u{1b}[2J\u{1b}[Htop - processes")
        let alternate = frame(term)
        XCTAssertTrue(text(alternate).contains("top - processes")); XCTAssertFalse(text(alternate).contains("main"))
        term.resize(cols: 20, rows: 8)
        let resized = frame(term); try resized.validate()
        XCTAssertEqual(resized.screen.rows, 8); XCTAssertEqual(resized.screen.columns, 20)
        term.feed(text: "\u{1b}[?1049l")
        XCTAssertTrue(text(frame(term)).contains("main"))
    }
    func testSequentialPlaybackAndArbitrarySeekAreIdentical() throws {
        let (url, first, last) = try recording()
        let doc = try RecordingDocument.open(url), cursor = try RecordingCursor(doc)
        XCTAssertTrue(doc.complete); XCTAssertEqual(doc.duration, 10)
        XCTAssertEqual(try cursor.seek(0), first)
        XCTAssertEqual(try cursor.seek(1), last)
        XCTAssertEqual(try cursor.seek(9), last)
        XCTAssertEqual(try cursor.seek(0), first)
        XCTAssertEqual(try RecordingCursor(doc).seek(9), last)
    }
    func testTruncatedFileRecoversOnlyVerifiedPrefix() throws {
        let (url, _, last) = try recording()
        let handle = try FileHandle(forWritingTo: url)
        let length = try handle.seekToEnd(); try handle.truncate(atOffset: length - 10); try handle.close()
        XCTAssertThrowsError(try RecordingDocument.open(url))
        let recovered = try RecordingDocument.open(url, allowPartial: true)
        XCTAssertFalse(recovered.complete)
        XCTAssertEqual(try RecordingCursor(recovered).seek(recovered.duration), last)
        XCTAssertEqual(try Data(contentsOf: url).count, Int(length - 10), "Recovery must not overwrite its input")
    }
    func testRejectsWrongVersionOversizeHashAndInvalidIndex() throws {
        let (url, _, _) = try recording()
        var data = try Data(contentsOf: url); data[0] = 0
        try data.write(to: url); XCTAssertThrowsError(try RecordingDocument.open(url))
        data = RecordingCodec.magic + Data(repeating: 255, count: 40)
        try data.write(to: url); XCTAssertThrowsError(try RecordingDocument.open(url))
        _ = try recording(); data = try Data(contentsOf: url); data[50] ^= 1
        try data.write(to: url); XCTAssertThrowsError(try RecordingDocument.open(url))
        let term = terminal()
        let bad = try file([.init(kind: .header, time: 0, header: .init(name: "bad")), .init(kind: .screen, time: 0, frame: frame(term)),
                            .init(kind: .end, time: 1, index: [.init(time: 0, offset: 999)])])
        XCTAssertThrowsError(try RecordingDocument.open(bad))
    }
    func testRejectsDimensionsDeltaRowsAndNonMonotonicTimes() throws {
        var value = frame(terminal()); value.screen.columns = Int.max
        XCTAssertThrowsError(try value.validate())
        value = frame(terminal()); value.changedRows = [0, 0, 0, 0, 0]
        XCTAssertThrowsError(try value.validate())
        let url = try file([.init(kind: .header, time: 0, header: .init(name: "bad")),
                            .init(kind: .screen, time: 1, frame: frame(terminal())),
                            .init(kind: .output, time: 0, output: Data([65]))])
        XCTAssertThrowsError(try RecordingDocument.open(url))
    }
    func testPlaybackNeverExecutesRawControlSequences() throws {
        let clipboard = NSPasteboard.general.changeCount
        let term = terminal(), snapshot = frame(term)
        let header = RecordingEvent(kind: .header, time: 0, header: .init(name: "safe"))
        let offset = UInt64(8 + (try RecordingCodec.encode(header)).count)
        let url = try file([header, .init(kind: .screen, time: 0, frame: snapshot),
            .init(kind: .output, time: 0.1, output: Data("\u{1b}]52;c;c2VjcmV0\u{7}\u{1b}[6n\u{1b}]0;evil\u{7}".utf8)),
            .init(kind: .end, time: 1, index: [.init(time: 0, offset: offset)])])
        let doc = try RecordingDocument.open(url)
        let restored = try RecordingCursor(doc).seek(1)
        _ = try RecordingRenderer.image(frame: restored, time: 1, width: 280, height: 75)
        XCTAssertEqual(delegate.replies, 0); XCTAssertEqual(NSPasteboard.general.changeCount, clipboard)
    }
    func testQualityRangeFrameTimingAndWatermarkDimensions() throws {
        let (url, _, _) = try recording(), doc = try RecordingDocument.open(url)
        var options = GIFExportOptions(end: 1, quality: 1)
        XCTAssertEqual(options.scale, 0.5)
        options.quality = 30; XCTAssertEqual(options.scale, 1)
        let before = options.dimensions(doc); options.watermark = "ServerDash"
        XCTAssertEqual(options.dimensions(doc).height, before.height + 30)
        for fps in [1, 10, 30] {
            options.fps = fps
            XCTAssertEqual((0..<fps).reduce(0) { $0 + options.delay(frame: $1, count: fps) }, 1, accuracy: 0.001)
        }
        options.end = 301; XCTAssertThrowsError(try options.validate(duration: 500))
        options.end = 1; options.fps = 0; XCTAssertThrowsError(try options.validate(duration: 500))
        options.fps = 30; options.start = .nan; XCTAssertThrowsError(try options.validate(duration: 500))
    }
    func testGIFDecodesAtOneTenThirtyFPS() async throws {
        let (url, _, _) = try recording(duration: 1), doc = try RecordingDocument.open(url)
        for fps in [1, 10, 30] {
            let target = directory.appendingPathComponent("\(fps).gif")
            try await GIFExporter.shared.export(document: doc, options: .init(end: 1, fps: fps, quality: 1, watermark: "测试"), to: target) { _ in }
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(target as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetCount(source), fps)
            var duration = 0.0
            for index in 0..<fps {
                XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, index, nil))
                let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any])
                let gif = try XCTUnwrap(properties[kCGImagePropertyGIFDictionary as String] as? [String: Any])
                duration += (gif[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double) ?? (gif[kCGImagePropertyGIFDelayTime as String] as? Double) ?? 0
            }
            XCTAssertEqual(duration, 1, accuracy: 0.015)
        }
    }
    func testCancelledGIFDoesNotLeaveTemporaryOrOverwriteTarget() async throws {
        let (url, _, _) = try recording(), doc = try RecordingDocument.open(url)
        let target = directory.appendingPathComponent("cancel.gif")
        try Data("existing".utf8).write(to: target)
        let work = Task {
            try Task.checkCancellation()
            try await GIFExporter.shared.export(document: doc, options: .init(end: 10, fps: 30), to: target) { _ in }
        }
        work.cancel()
        do { try await work.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        XCTAssertEqual(try String(contentsOf: target), "existing")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".serverdash-") })
    }
    func testCancelAfterGIFHasWrittenFrames() async throws {
        let (url, _, _) = try recording(duration: 30), doc = try RecordingDocument.open(url)
        let target = directory.appendingPathComponent("midway.gif")
        let started = expectation(description: "first frame written"), first = RecordingTestOnce()
        let work = Task {
            try await GIFExporter.shared.export(document: doc, options: .init(end: 30, fps: 30), to: target) { _ in
                if first.claim() { started.fulfill() }
            }
        }
        await fulfillment(of: [started], timeout: 5)
        work.cancel()
        do { try await work.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".serverdash-") })
    }
    func testStreamedGIFUsesIndependentFramePalettesAndRejectsMalformedBlocks() throws {
        let url = directory.appendingPathComponent("palettes.gif")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let file = try FileHandle(forWritingTo: url), encoder = try GIFStreamEncoder(file: file, width: 8, height: 8)
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                            space: RecordingRenderer.colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for value: UInt32 in [0xff0000, 0x0000ff] {
            context.setFillColor(RecordingRenderer.color(value)); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            try encoder.append(XCTUnwrap(context.makeImage()), delay: 0.1)
        }
        try encoder.finish(); try file.close()
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 2)
        for (index, expected) in [[255, 0, 0], [0, 0, 255]].enumerated() {
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index, nil))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
            let pixel = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            XCTAssertEqual(Array(UnsafeBufferPointer(start: pixel, count: 3)), expected.map(UInt8.init))
        }
        XCTAssertThrowsError(try GIFStreamEncoder.frameBlock(Data("GIF89a".utf8), width: 8, height: 8, delay: 0.1))
        // More than one image is not accepted as the single-frame ImageIO input.
        XCTAssertThrowsError(try GIFStreamEncoder.frameBlock(Data(contentsOf: url), width: 8, height: 8, delay: 0.1))
    }
    func testGIFResourceLimitKeepsExistingDestinationAndCleansTemporary() async throws {
        let (url, _, _) = try recording(duration: 1), doc = try RecordingDocument.open(url)
        let target = directory.appendingPathComponent("limited.gif")
        try Data("keep".utf8).write(to: target)
        do {
            try await GIFExporter.shared.export(document: doc, options: .init(end: 1), to: target,
                limits: .init(outputBytes: 1)) { _ in }
            XCTFail("Expected resource limit")
        } catch RecordingError.exportResources {}
        XCTAssertEqual(try String(contentsOf: target), "keep")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".serverdash-") })
    }
    func testThirtySecondGIFMemoryAndMainActorResponsiveness() async throws {
        let (url, _, _) = try recording(duration: 30), doc = try RecordingDocument.open(url)
        let baseline = RecordingMemory.residentBytes()
        let counter = RecordingHeartbeatCounter()
        let ready = expectation(description: "main actor heartbeat started")
        let heartbeat = Task { @MainActor in
            ready.fulfill()
            while !Task.isCancelled { counter.count += 1; try? await Task.sleep(for: .milliseconds(10)) }
        }
        await fulfillment(of: [ready], timeout: 2)
        let start = ProcessInfo.processInfo.systemUptime
        try await GIFExporter.shared.export(document: doc, options: .init(end: 30, fps: 30, quality: 30),
                                            to: directory.appendingPathComponent("stress.gif")) { _ in }
        heartbeat.cancel()
        let beats = await MainActor.run { counter.count }
        let resident = RecordingMemory.residentBytes()
        let growth = resident > baseline ? resident - baseline : 0
        print("Recording 900-frame GIF fixture: seconds=\(ProcessInfo.processInfo.systemUptime - start), RSS growth=\(growth), main actor ticks=\(beats)")
        XCTAssertGreaterThan(beats, 1)
        XCTAssertLessThan(growth, 512 * 1024 * 1024)
    }
    func testGlobalBudgetIsSharedAndRecoverable() {
        let budget = RecordingWriteBudget(limit: 1024)
        XCTAssertTrue(budget.reserve(900)); XCTAssertFalse(budget.reserve(200))
        budget.release(900); XCTAssertEqual(budget.used, 0); XCTAssertTrue(budget.reserve(1024))
        XCTAssertFalse(budget.reserve(1)); budget.release(1024)
    }
    func testIdleCompressionPreservesShortWaitsAndCompressesFourSecondGap() {
        var policy = RecordingIdlePolicy(), position = 0.0
        for _ in 0..<20 { position = policy.advance(from: position, by: 0.1, nextActivity: 4) }
        XCTAssertEqual(position, 4, accuracy: 0.001)
        policy = RecordingIdlePolicy()
        XCTAssertEqual(policy.advance(from: 0, by: 0.1, nextActivity: 1), 0.1)
        XCTAssertEqual(policy.advance(from: 0.1, by: 0.2, nextActivity: 1), 0.3, accuracy: 0.001)
    }
    func testWriterFailureKeepsFailureScopedAndInterruptedRecordingMarked() async throws {
        let snapshot = frame(terminal()), failed = expectation(description: "write failure")
        let bad = RecordingWriter(header: .init(name: "bad"), lease: .init(directory.appendingPathComponent("missing"), scoped: false),
                                  filename: "bad.sdrec") { failed.fulfill() }
        XCTAssertTrue(bad.append(frame: snapshot, time: 0))
        let closed = expectation(description: "failure closed")
        bad.finish(time: 1, reason: "interrupted") { result in
            if case .success = result { XCTFail("Expected write error") }; closed.fulfill()
        }
        await fulfillment(of: [failed, closed], timeout: 5)
        let good = RecordingWriter(header: .init(name: "good"), lease: .init(directory, scoped: false), filename: "partial.sdrec") { XCTFail("Unexpected") }
        XCTAssertTrue(good.append(frame: snapshot, time: 0))
        let saved = expectation(description: "interrupted saved")
        good.finish(time: 1, reason: "interrupted") { _ in saved.fulfill() }
        await fulfillment(of: [saved], timeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: good.finalURL.path))
        XCTAssertTrue(try RecordingDocument.open(good.partialURL, allowPartial: true).interrupted)
    }
    func testSyntheticOutputCaptureCostAndStreamingFileSize() throws {
        let chunk = String(repeating: "sample output 8080 中文\r\n", count: 30)
        func run(capture: Bool) -> Double {
            let term = terminal(columns: 100, rows: 32)
            let start = ProcessInfo.processInfo.systemUptime
            for index in 0..<1200 {
                term.feed(text: chunk)
                if capture, index.isMultiple(of: 40) { _ = term.displaySnapshot(followOutput: true) }
            }
            return ProcessInfo.processInfo.systemUptime - start
        }
        _ = run(capture: false)
        let baseline = run(capture: false), recorded = run(capture: true)
        print("Recording synthetic parser+snapshot benchmark: off=\(baseline)s on=\(recorded)s bytes=\(chunk.utf8.count * 1200). Not an end-to-end SSH benchmark.")
        XCTAssertGreaterThan(baseline, 0); XCTAssertGreaterThan(recorded, 0)
    }
    @MainActor
    func testGIFExportSheetAndTerminalRendererFixtures() async throws {
        let (url, _, last) = try recording(duration: 1), doc = try RecordingDocument.open(url)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("serverdash-recording-qa", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = try RecordingRenderer.image(frame: last, time: 0.2, width: 840, height: 255, watermark: "ServerDash · 演示")
        let preview = folder.appendingPathComponent("terminal.png")
        let target = try XCTUnwrap(CGImageDestinationCreateWithURL(preview as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(target, image, nil); XCTAssertTrue(CGImageDestinationFinalize(target))
        for (scheme, name) in [(ColorScheme.light, "light"), (.dark, "dark")] {
            let root = NSHostingView(rootView: GIFExportView(document: doc).environment(\.colorScheme, scheme))
            root.frame = NSRect(x: 0, y: 0, width: 680, height: 650)
            let window = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = root
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.backgroundColor = .windowBackgroundColor
            window.orderFront(nil)
            root.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            let rep = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: rep)
            let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try data.write(to: folder.appendingPathComponent("gif-sheet-\(name).png"))
            window.orderOut(nil); window.contentView = nil
        }
        print("Recording visual QA fixtures: \(folder.path)")
    }
    func testWriterStreamsOutputsAndEmitsKeyframes() async throws {
        let term = terminal(), first = frame(term)
        let budget = RecordingWriteBudget(), header = RecordingHeader(name: "writer")
        let writer = RecordingWriter(header: header, lease: .init(directory, scoped: false), filename: "writer.sdrec", budget: budget) { XCTFail("Unexpected writer failure") }
        XCTAssertTrue(writer.append(frame: first, time: 0))
        for index in 0..<100 { XCTAssertTrue(writer.append(output: Data(repeating: 65, count: 65536), time: Double(index) / 10)) }
        XCTAssertTrue(writer.append(frame: first, time: 10))
        let finished = expectation(description: "finalized")
        writer.finish(time: 12, reason: "user") { result in
            if case .failure = result { XCTFail("Failed writer") }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 10)
        XCTAssertEqual(budget.used, 0)
        let doc = try RecordingDocument.open(writer.finalURL)
        XCTAssertEqual(doc.index.count, 2); XCTAssertEqual(doc.duration, 12)
        XCTAssertEqual(try RecordingCursor(doc).seek(11), first)
        let permissions = try FileManager.default.attributesOfItem(atPath: writer.finalURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }
    func testSimulatedDiskFullPreservesVerifiedPrefixAndReleasesBudget() async throws {
        let budget = RecordingWriteBudget(), failure = expectation(description: "ENOSPC surfaced")
        let gate = RecordingFailAfterTwoBlocks()
        let writer = RecordingWriter(header: .init(name: "ENOSPC"), lease: .init(directory, scoped: false), filename: "disk-full.sdrec",
            budget: budget, writeBlock: { file, data in try gate.write(file, data) }) { failure.fulfill() }
        XCTAssertTrue(writer.append(frame: frame(terminal()), time: 0))
        XCTAssertTrue(writer.append(output: Data("output".utf8), time: 1))
        let finished = expectation(description: "stopped")
        writer.finish(time: 2, reason: "interrupted") { result in
            if case .success = result { XCTFail("Expected disk-full failure") }; finished.fulfill()
        }
        await fulfillment(of: [failure, finished], timeout: 5)
        XCTAssertEqual(budget.used, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.finalURL.path))
        let partial = try RecordingDocument.open(writer.partialURL, allowPartial: true)
        XCTAssertFalse(partial.complete); XCTAssertEqual(partial.duration, 0)
    }
    func testOneHourRecordingIndexAndRandomSeeks() async throws {
        let snapshot = frame(terminal())
        let writer = RecordingWriter(header: .init(name: "one hour"), lease: .init(directory, scoped: false), filename: "hour.sdrec") { XCTFail("Unexpected") }
        for second in stride(from: 0, through: 3600, by: 5) {
            XCTAssertTrue(writer.append(frame: snapshot, time: Double(second)))
        }
        let done = expectation(description: "hour written")
        writer.finish(time: 3600, reason: "user") { _ in done.fulfill() }
        await fulfillment(of: [done], timeout: 10)
        let document = try RecordingDocument.open(writer.finalURL), cursor = try RecordingCursor(document)
        XCTAssertEqual(document.index.count, 721)
        for time in [3599.0, 0, 1800, 5, 3590, 3] { XCTAssertEqual(try cursor.seek(time), snapshot) }
    }
}

@MainActor
final class RecordingLifecycleTests: XCTestCase {
    func testInvalidDirectoryBookmarkDoesNotFallBack() throws {
        let name = "ServerDashRecordingTests.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("invalid bookmark".utf8), forKey: "recordingDirectoryBookmark")
        let settings = RecordingSettings(defaults: defaults)
        XCTAssertThrowsError(try settings.lease())
    }
    func testTerminalControllerDisconnectionAndCloseFinalizeOnlyTheirPane() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("serverdash-recording-controller-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = ServerRecord(name: "Test", host: "invalid.example", username: "test")
        let first = TerminalSessionController(server: server, attachProcess: false)
        let second = TerminalSessionController(server: server, attachProcess: false)
        let lease = RecordingDirectoryLease(directory, scoped: false)
        for controller in [first, second] {
            controller.status = .connected
            controller.recording.start(name: "test", connected: true,
                initial: controller.hostView.recordingFrame(followOutput: false),
                capture: { controller.hostView.recordingFrame(followOutput: true) }, lease: lease)
        }
        first.hostView.onTerminated?(0)
        XCTAssertFalse(first.recording.isRecording); XCTAssertTrue(second.recording.isRecording)
        second.terminate(); XCTAssertFalse(second.recording.isRecording)
        for _ in 0..<200 where [first, second].contains(where: { $0.recording.state == .saving }) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue([first, second].allSatisfy { $0.recording.state == .idle })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
    }
    func testPlayerRapidSeeksKeepLatestSelection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("serverdash-player-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let delegate = RecordingTestDelegate(), term = Terminal(delegate: delegate)
        let frame = RecordingFrame(screen: term.displaySnapshot(), appearance: .init(fontName: "Menlo", fontSize: 12, cellWidth: 7, cellHeight: 15))
        let writer = RecordingWriter(header: .init(name: "seek"), lease: .init(directory, scoped: false), filename: "seek.sdrec") {}
        XCTAssertTrue(writer.append(frame: frame, time: 0))
        let saved = expectation(description: "saved")
        writer.finish(time: 100, reason: "user") { _ in saved.fulfill() }
        await fulfillment(of: [saved], timeout: 5)
        let player = RecordingPlayer(); player.open(writer.finalURL)
        for _ in 0..<200 where player.document == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(player.document)
        for position in [99.0, 1, 72, 18] { player.seek(position) }
        for _ in 0..<200 where player.position != 18 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(player.position, 18)
        player.close(); XCTAssertNil(player.document)
        try await Task.sleep(for: .milliseconds(50)); XCTAssertNil(player.image)
    }
    func testSixteenPanesDuplicateStartAndIndependentStop() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("serverdash-recording-lifecycle-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let delegate = RecordingTestDelegate(), term = Terminal(delegate: delegate)
        let frame = RecordingFrame(screen: term.displaySnapshot(), appearance: .init(fontName: "Menlo", fontSize: 12, cellWidth: 7, cellHeight: 15))
        let controllers = (0..<16).map { _ in TerminalRecordingController(paneID: UUID()) }
        let lease = RecordingDirectoryLease(directory, scoped: false)
        for controller in controllers {
            controller.start(name: "pane", connected: false, initial: frame, capture: { frame }, lease: lease)
            XCTAssertFalse(controller.isRecording)
            controller.start(name: "pane", connected: true, initial: frame, capture: { frame }, lease: lease)
            controller.start(name: "duplicate", connected: true, initial: frame, capture: { frame }, lease: lease)
        }
        XCTAssertTrue(controllers.allSatisfy(\.isRecording))
        controllers[0].stop(reason: "closed"); controllers[0].stop()
        XCTAssertTrue(controllers.dropFirst().allSatisfy(\.isRecording))
        for controller in controllers.dropFirst() { controller.stop(reason: "sleep") }
        for _ in 0..<200 where controllers.contains(where: { $0.state == .saving }) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(controllers.allSatisfy { $0.state == .idle })
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(urls.count, 16)
        XCTAssertTrue(urls.allSatisfy { $0.pathExtension == "sdrec" })
    }
    func testFilenameSanitizationAndUniqueSuffix() {
        let header = RecordingHeader(name: "../../秘密/测试\n")
        let filename = RecordingSettings.filename(template: "../{name}", header: header)
        XCTAssertFalse(filename.contains("/")); XCTAssertFalse(filename.contains("\n"))
        XCTAssertFalse(filename.hasPrefix(".")); XCTAssertTrue(filename.contains(header.id.uuidString))
        XCTAssertTrue(filename.hasSuffix(".sdrec"))
    }
}

@MainActor private final class RecordingHeartbeatCounter: @unchecked Sendable {
    var count = 0
    nonisolated init() {}
}

private final class RecordingTestOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if used { return false }; used = true; return true }
}

private final class RecordingFailAfterTwoBlocks: @unchecked Sendable {
    // Called exclusively on the writer's serial queue.
    private var count = 0
    func write(_ file: FileHandle, _ data: Data) throws {
        count += 1
        if count > 2 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) }
        try file.write(contentsOf: data)
    }
}
