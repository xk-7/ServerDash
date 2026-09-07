import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers
import SwiftTerm

/// Only draws validated character cells. It cannot send SSH data or execute escape sequences.
enum RecordingRenderer {
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    static func color(_ value: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: colorSpace, components: [CGFloat((value >> 16) & 255) / 255,
            CGFloat((value >> 8) & 255) / 255, CGFloat(value & 255) / 255, alpha])!
    }
    static func image(frame: RecordingFrame, time: Double, width: Int, height: Int, watermark: String = "") throws -> CGImage {
        try frame.validate()
        guard time.isFinite, time >= 0, time <= 365 * 86400,
              width > 0, height > 0, width <= 16384, height <= 16384, width * height <= 32_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw RecordingError.invalid
        }
        let screen = frame.screen, a = frame.appearance
        let footer: CGFloat = watermark.isEmpty ? 0 : 30
        context.setFillColor(color(screen.background)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let naturalWidth = Double(screen.columns) * a.cellWidth, naturalHeight = Double(screen.rows) * a.cellHeight
        let scale = min(Double(width) / naturalWidth, (Double(height) - footer) / naturalHeight)
        guard scale > 0 else { throw RecordingError.invalid }
        context.saveGState()
        context.translateBy(x: (Double(width) - naturalWidth * scale) / 2,
                            y: footer + (Double(height) - footer - naturalHeight * scale) / 2)
        context.scaleBy(x: scale, y: scale)
        context.textMatrix = .identity
        let font = CTFontCreateWithName(a.fontName as CFString, a.fontSize, nil)
        var fonts: [UInt8: CTFont] = [0: font]
        for traits: UInt8 in [1, 64, 65] {
            var symbolic: CTFontSymbolicTraits = []
            if traits & 1 != 0 { symbolic.insert(.boldTrait) }
            if traits & 64 != 0 { symbolic.insert(.italicTrait) }
            fonts[traits] = CTFontCreateCopyWithSymbolicTraits(font, a.fontSize, nil, symbolic, symbolic) ?? font
        }
        let blinkVisible = Int(time * 2).isMultiple(of: 2)
        for (row, line) in screen.lines.enumerated() {
            try Task.checkCancellation()
            let y = naturalHeight - Double(row + 1) * a.cellHeight
            let wide = line.mode == 0 ? 1.0 : 2.0
            for (column, cell) in line.cells.enumerated() {
                if cell.width == 0 { continue }
                let x = Double(column) * a.cellWidth * wide
                if x >= naturalWidth { break }
                let inverted = cell.style & 8 != 0
                let fg = inverted ? cell.background : cell.foreground
                let bg = inverted ? cell.foreground : cell.background
                let rect = CGRect(x: x, y: y, width: a.cellWidth * Double(max(1, cell.width)) * wide, height: a.cellHeight)
                context.setFillColor(color(bg)); context.fill(rect)
                guard cell.text != " " || cell.style & 130 != 0, cell.style & 16 == 0,
                      cell.style & 4 == 0 || blinkVisible else { continue }
                context.saveGState(); context.clip(to: rect)
                context.translateBy(x: x, y: y)
                let doubled = line.mode == 2 || line.mode == 3
                if line.mode == 2 { context.translateBy(x: 0, y: -a.cellHeight) }
                context.scaleBy(x: wide, y: doubled ? 2 : 1)
                let actualFont = fonts[cell.style & 65] ?? font
                let attributes: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): actualFont,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(fg, alpha: cell.style & 32 == 0 ? 1 : 0.55)
                ]
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: cell.text, attributes: attributes))
                let baseline = (a.cellHeight - CTFontGetAscent(actualFont) - CTFontGetDescent(actualFont)) / 2 + CTFontGetDescent(actualFont)
                context.textPosition = CGPoint(x: 0, y: baseline); CTLineDraw(line, context)
                context.setStrokeColor(color(cell.underline ?? fg)); context.setLineWidth(max(1, a.fontSize / 16))
                let decorations: [CGFloat?] = [cell.style & 2 != 0 ? baseline - 2 : nil,
                                              cell.style & 128 != 0 ? CGFloat(a.cellHeight * 0.5) : nil]
                for offset in decorations.compactMap({ $0 }) {
                    context.move(to: CGPoint(x: 0, y: offset))
                    context.addLine(to: CGPoint(x: a.cellWidth * Double(max(1, cell.width)), y: offset)); context.strokePath()
                }
                context.restoreGState()
            }
        }
        if screen.cursorVisible, !screen.cursorStyle.hasPrefix("blink") || blinkVisible {
            let x = min(Double(screen.columns - 1), Double(screen.cursorColumn)) * a.cellWidth
            let y = naturalHeight - Double(screen.cursorRow + 1) * a.cellHeight
            var rect = CGRect(x: x, y: y, width: a.cellWidth, height: a.cellHeight)
            if screen.cursorStyle.contains("Bar") { rect.size.width = 2 }
            if screen.cursorStyle.contains("Underline") { rect.size.height = 2 }
            context.setFillColor(color(screen.foreground, alpha: 0.65)); context.fill(rect)
        }
        context.restoreGState()
        if !watermark.isEmpty {
            context.setFillColor(color(0x151515)); context.fill(CGRect(x: 0, y: 0, width: width, height: Int(footer)))
            context.saveGState(); context.clip(to: CGRect(x: 8, y: 0, width: max(1, width - 16), height: Int(footer)))
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Menlo" as CFString, 12, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(0xffffff)
            ]
            context.textPosition = CGPoint(x: 10, y: 9)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: watermark, attributes: attributes)), context)
            context.restoreGState()
        }
        guard let image = context.makeImage() else { throw RecordingError.invalid }
        return image
    }
}

actor RecordingPlaybackReader {
    private let cursor: RecordingCursor
    private var nextActivity: Double?
    private var searchedAfter: Double?
    init(_ document: RecordingDocument) throws { cursor = try RecordingCursor(document) }
    func read(time: Double) throws -> RecordingFrame { try cursor.seek(time) }
    func activity(after time: Double) throws -> Double? {
        if let nextActivity, nextActivity > time, let searchedAfter, time >= searchedAfter { return nextActivity }
        if nextActivity == nil, let searchedAfter, time >= searchedAfter { return nil }
        nextActivity = try cursor.nextActivity(after: time); searchedAfter = time
        return nextActivity
    }
}

struct RecordingIdlePolicy {
    private var target: Double?
    private var gap = 0.0
    private var elapsed = 0.0
    mutating func advance(from time: Double, by delta: Double, nextActivity: Double) -> Double {
        if target != nextActivity { target = nextActivity; gap = nextActivity - time; elapsed = 0 }
        if gap > 2 {
            elapsed += delta
            if elapsed >= 2 { return nextActivity }
        }
        return time + delta
    }
}

@MainActor
final class RecordingPlayer: ObservableObject {
    @Published private(set) var document: RecordingDocument?
    @Published private(set) var image: CGImage?
    @Published private(set) var position = 0.0
    @Published private(set) var playing = false
    @Published var speed = 1.0
    @Published var skipIdle = false
    @Published var message: String?
    @Published private(set) var loading = false
    private var reader: RecordingPlaybackReader?
    private var request: Task<Void, Never>?
    private var playback: Task<Void, Never>?
    private var token = UUID()
    private var lease: RecordingDirectoryLease?
    private var lastFrame: RecordingFrame?
    private var lastBlink = -1

    func open(_ url: URL, lease: RecordingDirectoryLease? = nil) {
        close(); self.lease = lease; loading = true
        let id = UUID(); token = id
        request = Task {
            let work = Task.detached(priority: .userInitiated) { try RecordingDocument.open(url, allowPartial: url.pathExtension == "partial") }
            do {
                let doc = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard token == id, !Task.isCancelled else { return }
                reader = try RecordingPlaybackReader(doc); document = doc; loading = false
                if !doc.complete || doc.interrupted { message = "此录制未正常结束，已恢复有效数据段；原文件未被修改。" }
                try await present(0, id: id)
            } catch is CancellationError {} catch {
                if token == id { loading = false; message = "无法打开录制：文件版本不支持或数据损坏。" }
            }
        }
    }
    func close() {
        token = UUID(); request?.cancel(); playback?.cancel(); request = nil; playback = nil
        playing = false; reader = nil; document = nil; image = nil; position = 0
        lastFrame = nil; lastBlink = -1; lease = nil; message = nil; loading = false
    }
    func pause() { playing = false; playback?.cancel(); playback = nil }
    func seek(_ time: Double) {
        pause(); request?.cancel()
        let id = UUID(); token = id
        request = Task {
            do { try await present(time, id: id) }
            catch is CancellationError {} catch { if token == id { message = "无法读取此位置的录制数据。" } }
        }
    }
    func toggle() {
        if playing { pause(); return }
        guard let doc = document, let reader else { return }
        request?.cancel(); let id = UUID(); token = id; playing = true
        playback = Task {
            var previousClock = ProcessInfo.processInfo.systemUptime
            var idle = RecordingIdlePolicy()
            do {
                if position >= doc.duration { try await present(0, id: id) }
                while !Task.isCancelled, playing, token == id {
                    let clock = ProcessInfo.processInfo.systemUptime
                    let delta = max(0, clock - previousClock) * speed
                    previousClock = clock
                    var target = position + delta
                    if skipIdle {
                        let next = try await reader.activity(after: position) ?? doc.duration
                        target = idle.advance(from: position, by: delta, nextActivity: next)
                    } else { idle = RecordingIdlePolicy() }
                    try await present(min(doc.duration, target), id: id)
                    if position >= doc.duration { break }
                    try await Task.sleep(for: .milliseconds(33))
                }
            } catch is CancellationError {} catch { if token == id { message = "回放失败，录制文件可能已更改。" } }
            if token == id { playing = false }
        }
    }
    private func present(_ requested: Double, id: UUID) async throws {
        guard let reader, let doc = document else { return }
        let target = min(doc.duration, max(0, requested))
        let frame = try await reader.read(time: target)
        try Task.checkCancellation()
        let blink = Int(target * 2)
        if lastFrame != frame || lastBlink != blink {
            // Preview is bounded independently of recorded dimensions.
            let scale = min(1, 1920 / (Double(frame.screen.columns) * frame.appearance.cellWidth))
            let width = max(1, Int(Double(frame.screen.columns) * frame.appearance.cellWidth * scale))
            let height = max(1, Int(Double(frame.screen.rows) * frame.appearance.cellHeight * scale))
            let render = Task.detached(priority: .userInitiated) {
                try RecordingRenderer.image(frame: frame, time: target, width: width, height: height)
            }
            let result = try await withTaskCancellationHandler { try await render.value } onCancel: { render.cancel() }
            guard token == id, !Task.isCancelled else { return }
            image = result; lastFrame = frame; lastBlink = blink
        }
        guard token == id, !Task.isCancelled else { return }
        position = target
    }
}

struct GIFExportOptions: Sendable {
    var start = 0.0
    var end = 0.0
    var fps = 10
    var quality = 20
    var watermark = ""
    var scale: Double { 0.5 + Double(quality - 1) / 58 }
    func validate(duration: Double) throws {
        guard start.isFinite, end.isFinite, start >= 0, end > start, end <= duration + 0.001,
              end - start <= 300, (1...30).contains(fps), (1...30).contains(quality),
              watermark.utf8.count <= 1024, !watermark.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw RecordingError.exportRange
        }
    }
    /// GIF timestamps are centiseconds. Rounding cumulative boundaries avoids 30 FPS drift.
    func delay(frame: Int, count: Int) -> Double {
        let duration = end - start
        let a = min(duration, Double(frame) / Double(fps))
        let b = frame == count - 1 ? duration : min(duration, Double(frame + 1) / Double(fps))
        return max(0.01, (b * 100).rounded() / 100 - (a * 100).rounded() / 100)
    }
    func dimensions(_ document: RecordingDocument) -> (width: Int, height: Int) {
        (max(1, Int(ceil(document.maximumWidth * scale))), max(1, Int(ceil(document.maximumHeight * scale))) + (watermark.isEmpty ? 0 : 30))
    }
}

enum RecordingMemory {
    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
}

struct GIFResourceLimits: Sendable {
    var additionalResidentBytes: UInt64 = 512 * 1024 * 1024
    var outputBytes: UInt64 = 512 * 1024 * 1024
}

/// ImageIO compresses one opaque, full-canvas frame at a time. Only its image/LZW
/// blocks are retained; local color tables keep successive frame palettes independent.
/// GIF89a block layout: https://www.w3.org/Graphics/GIF/spec-gif89a.txt
final class GIFStreamEncoder {
    private let file: FileHandle
    private let width: Int
    private let height: Int
    private var frames = 0
    init(file: FileHandle, width: Int, height: Int) throws {
        guard (1...16384).contains(width), (1...16384).contains(height) else { throw RecordingError.invalid }
        self.file = file; self.width = width; self.height = height
        // No global palette: every image carries its own table generated by ImageIO.
        var header = Data("GIF89a".utf8)
        header.append(contentsOf: [UInt8(width & 255), UInt8(width >> 8), UInt8(height & 255), UInt8(height >> 8), 0x70, 0, 0])
        header.append(contentsOf: [0x21, 0xff, 11]); header.append(Data("NETSCAPE2.0".utf8))
        header.append(contentsOf: [3, 1, 0, 0, 0])
        try file.write(contentsOf: header)
    }
    func append(_ image: CGImage, delay: Double) throws {
        guard image.width == width, image.height == height, delay.isFinite, (0.01...655.35).contains(delay) else { throw RecordingError.invalid }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 1, nil) else {
            throw RecordingError.write
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw RecordingError.write }
        let block = try Self.frameBlock(data as Data, width: width, height: height, delay: delay)
        try file.write(contentsOf: block); frames += 1
    }
    func finish() throws {
        guard frames > 0 else { throw RecordingError.invalid }
        try file.write(contentsOf: Data([0x3b])); try file.synchronize()
    }
    static func frameBlock(_ data: Data, width: Int, height: Int, delay: Double) throws -> Data {
        guard data.count >= 13, data.count <= 128 * 1024 * 1024,
              [Data("GIF87a".utf8), Data("GIF89a".utf8)].contains(data.prefix(6)) else { throw RecordingError.invalid }
        func integer(_ start: Int) -> Int { Int(data[start]) | Int(data[start + 1]) << 8 }
        guard integer(6) == width, integer(8) == height else { throw RecordingError.invalid }
        let globalCode = data[10] & 7
        let globalCount = data[10] & 128 == 0 ? 0 : 3 * (1 << (Int(globalCode) + 1))
        var position = 13
        func take(_ count: Int) throws -> Data {
            guard count >= 0, count <= data.count - position else { throw RecordingError.invalid }
            defer { position += count }
            return data.subdata(in: position..<position + count)
        }
        let globalPalette = try take(globalCount)
        var result: Data?, transparent: UInt8 = 0, transparentIndex: UInt8 = 0
        while position < data.count {
            let marker = try take(1)[0]
            switch marker {
            case 0x21:
                let label = try take(1)[0]
                if label == 0xf9 {
                    guard try take(1)[0] == 4 else { throw RecordingError.invalid }
                    let control = try take(4)
                    transparent = control[0] & 1; transparentIndex = control[3]
                    guard try take(1)[0] == 0 else { throw RecordingError.invalid }
                } else {
                    while true { let length = Int(try take(1)[0]); if length == 0 { break }; _ = try take(length) }
                }
            case 0x2c:
                guard result == nil else { throw RecordingError.invalid }
                var descriptor = try take(9)
                func value(_ offset: Int) -> Int { Int(descriptor[offset]) | Int(descriptor[offset + 1]) << 8 }
                guard value(0) == 0, value(2) == 0, value(4) == width, value(6) == height else { throw RecordingError.invalid }
                let local = descriptor[8] & 128 != 0, code = local ? descriptor[8] & 7 : globalCode
                let palette = local ? try take(3 * (1 << (Int(code) + 1))) : globalPalette
                guard !palette.isEmpty else { throw RecordingError.invalid }
                descriptor[8] = (descriptor[8] & 0x40) | 0x80 | code
                let start = position
                guard (2...8).contains(Int(try take(1)[0])) else { throw RecordingError.invalid }
                while true { let length = Int(try take(1)[0]); if length == 0 { break }; _ = try take(length) }
                let hundredths = Int((delay * 100).rounded())
                var block = Data([0x21, 0xf9, 4, 4 | transparent, UInt8(hundredths & 255), UInt8(hundredths >> 8), transparentIndex, 0, 0x2c])
                block.append(descriptor); block.append(palette); block.append(data.subdata(in: start..<position))
                result = block
            case 0x3b:
                guard position == data.count, let result else { throw RecordingError.invalid }
                return result
            default: throw RecordingError.invalid
            }
        }
        throw RecordingError.invalid
    }
}

private final class GIFExportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}

/// A dedicated serial queue keeps synchronous ImageIO work off the main thread,
/// including calls originating from a SwiftUI button or an actor-inherited task.
final class GIFExporter: @unchecked Sendable {
    static let shared = GIFExporter()
    private let queue = DispatchQueue(label: "com.serverdash.gif.export", qos: .utility)
    func export(document: RecordingDocument, options: GIFExportOptions, to url: URL,
                limits: GIFResourceLimits = .init(),
                progress: @escaping @Sendable (Double) -> Void) async throws {
        let cancellation = GIFExportCancellation()
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async {
                    do {
                        try self.performExport(document: document, options: options, to: url, limits: limits,
                                               cancellation: cancellation, progress: progress)
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancellation.cancel() }
    }
    private func performExport(document: RecordingDocument, options: GIFExportOptions, to url: URL,
                               limits: GIFResourceLimits, cancellation: GIFExportCancellation,
                               progress: @escaping @Sendable (Double) -> Void) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        precondition(!Thread.isMainThread, "GIF encoding must never block the main thread")
        try options.validate(duration: document.duration)
        guard url.isFileURL, url.pathExtension.lowercased() == "gif",
              url.standardizedFileURL != document.url.standardizedFileURL else { throw RecordingError.exportRange }
        try cancellation.check()
        let baselineMemory = RecordingMemory.residentBytes()
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".serverdash-\(UUID().uuidString).gif")
        let fd = Darwin.open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw RecordingError.write }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close(); try? FileManager.default.removeItem(at: temporary) }
        let count = max(1, Int(ceil((options.end - options.start) * Double(options.fps))))
        let cursor = try RecordingCursor(document), size = options.dimensions(document)
        let stream = try GIFStreamEncoder(file: file, width: size.width, height: size.height)
        func checkResources() throws {
            let resident = RecordingMemory.residentBytes()
            let bytes = (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.uint64Value ?? 0
            if (resident > baselineMemory && resident - baselineMemory > limits.additionalResidentBytes) || bytes > limits.outputBytes {
                throw RecordingError.exportResources
            }
        }
        for index in 0..<count {
            try cancellation.check()
            try checkResources()
            try autoreleasepool {
                let time = options.start + Double(index) / Double(options.fps)
                let frame = try cursor.seek(time)
                let image = try RecordingRenderer.image(frame: frame, time: time, width: size.width, height: size.height, watermark: options.watermark)
                let delay = options.delay(frame: index, count: count)
                try stream.append(image, delay: delay)
            }
            progress(Double(index + 1) / Double(count))
        }
        try cancellation.check()
        try stream.finish(); try file.close()
        try checkResources()
        try cancellation.check()
        // Replacing a destination is only invoked after NSSavePanel has confirmed that path.
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else { try FileManager.default.moveItem(at: temporary, to: url) }
    }
}
