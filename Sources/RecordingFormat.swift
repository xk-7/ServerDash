import Foundation
import Compression
import CryptoKit
import SwiftTerm

enum RecordingError: LocalizedError {
    case invalid, unsupported, directory, overloaded, write, exportRange, exportResources, cancelled
    var errorDescription: String? {
        switch self {
        case .invalid: "录制文件损坏或超出安全限制。"
        case .unsupported: "暂不支持此录制文件版本。"
        case .directory: "录制目录不可访问，请在设置 → 录制中重新选择目录。"
        case .overloaded: "待写入数据超过 32 MiB，录制已停止；SSH 不受影响。"
        case .write: "录制写入失败，请检查磁盘空间和目录权限。已保存部分可在录制列表恢复。"
        case .exportRange: "请选择最多五分钟的片段，帧率和画质必须在 1–30 之间。"
        case .exportResources: "GIF 导出达到资源保护上限，请缩短片段或降低画质和帧率。临时文件已清理。"
        case .cancelled: "操作已取消。"
        }
    }
}

struct RecordingAppearance: Codable, Equatable, Sendable {
    var fontName: String
    var fontSize: Double
    var cellWidth: Double
    var cellHeight: Double

    func validate() throws {
        guard fontName.utf8.count <= 256, fontSize.isFinite, (8...48).contains(fontSize),
              cellWidth.isFinite, cellHeight.isFinite, (1...128).contains(cellWidth),
              (1...256).contains(cellHeight) else { throw RecordingError.invalid }
    }
}

struct RecordingHeader: Codable, Sendable {
    var format = "com.serverdash.recording"
    var version = 1
    var id = UUID()
    var name: String
    var date = Date()
}

struct RecordingFrame: Codable, Equatable, Sendable {
    var screen: TerminalDisplaySnapshot
    var appearance: RecordingAppearance
    // Full frames have nil changedRows. Delta frames contain only the specified rows.
    var changedRows: [Int]?

    func validate() throws {
        try appearance.validate()
        let s = screen
        guard (1...1024).contains(s.columns), (1...512).contains(s.rows), s.columns * s.rows <= 131_072,
              (0...s.columns).contains(s.cursorColumn), (-512...1024).contains(s.cursorRow),
              s.cursorStyle.count <= 32, s.foreground <= 0xffffff, s.background <= 0xffffff else { throw RecordingError.invalid }
        if let changedRows {
            guard changedRows.count == s.lines.count, Set(changedRows).count == changedRows.count,
                  changedRows.allSatisfy({ (0..<s.rows).contains($0) }) else { throw RecordingError.invalid }
        } else if s.lines.count != s.rows { throw RecordingError.invalid }
        for line in s.lines {
            guard line.cells.count == s.columns, (0...3).contains(line.mode) else { throw RecordingError.invalid }
            for cell in line.cells {
                guard (0...2).contains(cell.width), cell.text.utf8.count <= 1024, cell.text.count <= 1,
                      cell.foreground <= 0xffffff, cell.background <= 0xffffff,
                      cell.underline == nil || cell.underline! <= 0xffffff else { throw RecordingError.invalid }
            }
        }
    }

    func applying(to previous: RecordingFrame?) throws -> RecordingFrame {
        try validate()
        guard let changedRows else { return self }
        guard let previous, previous.screen.columns == screen.columns, previous.screen.rows == screen.rows else {
            throw RecordingError.invalid
        }
        var result = self
        result.screen.lines = previous.screen.lines
        for (index, row) in changedRows.enumerated() { result.screen.lines[row] = screen.lines[index] }
        result.changedRows = nil
        return result
    }

    var estimatedBytes: Int { screen.lines.reduce(1024) { $0 + 64 + $1.cells.reduce(0) { $0 + 96 + $1.text.utf8.count } } }
}

struct RecordingIndexEntry: Codable, Equatable, Sendable {
    var time: Double
    var offset: UInt64
}

struct RecordingEvent: Codable, Sendable {
    enum Kind: String, Codable { case header, output, screen, end }
    var kind: Kind
    var time: Double
    var header: RecordingHeader?
    var output: Data?
    var frame: RecordingFrame?
    var index: [RecordingIndexEntry]?
    var reason: String?
}

/// Length-delimited, independently compressed blocks. The hash detects damage, not tampering.
enum RecordingCodec {
    static let magic = Data("SDRC0001".utf8)
    static let maximumBlock = 16 * 1024 * 1024

    static func encode(_ event: RecordingEvent) throws -> Data {
        let raw = try JSONEncoder().encode(event)
        guard raw.count <= maximumBlock else { throw RecordingError.invalid }
        let compressed = try (raw as NSData).compressed(using: .lzfse) as Data
        guard compressed.count <= maximumBlock else { throw RecordingError.invalid }
        var block = Data()
        for number in [compressed.count, raw.count] {
            var length = UInt32(number).littleEndian
            withUnsafeBytes(of: &length) { block.append(contentsOf: $0) }
        }
        block.append(contentsOf: SHA256.hash(data: compressed))
        block.append(compressed)
        return block
    }

    static func read(_ file: FileHandle) throws -> RecordingEvent? {
        guard let prefix = try file.read(upToCount: 40), !prefix.isEmpty else { return nil }
        guard prefix.count == 40 else { throw RecordingError.invalid }
        func length(_ offset: Int) -> Int {
            (0..<4).reduce(0) { $0 | Int(prefix[offset + $1]) << (8 * $1) }
        }
        let packed = length(0), unpacked = length(4)
        guard (1...maximumBlock).contains(packed), (1...maximumBlock).contains(unpacked),
              let data = try file.read(upToCount: packed), data.count == packed,
              Data(SHA256.hash(data: data)) == prefix.subdata(in: 8..<40) else { throw RecordingError.invalid }
        var raw = Data(count: unpacked)
        let decoded = raw.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                compression_decode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, unpacked,
                    input.bindMemory(to: UInt8.self).baseAddress!, packed, nil, COMPRESSION_LZFSE)
            }
        }
        guard decoded == unpacked else { throw RecordingError.invalid }
        do { return try JSONDecoder().decode(RecordingEvent.self, from: raw) }
        catch { throw RecordingError.invalid }
    }
}

struct RecordingDocument: Sendable {
    let url: URL
    let header: RecordingHeader
    let duration: Double
    let index: [RecordingIndexEntry]
    let validEnd: UInt64
    let complete: Bool
    let interrupted: Bool
    let hasImages: Bool
    let maximumWidth: Double
    let maximumHeight: Double

    /// Scans one block at a time; neither output nor the entire recording is retained in memory.
    static func open(_ url: URL, allowPartial: Bool = false) throws -> Self {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard try file.read(upToCount: 8) == RecordingCodec.magic else { throw RecordingError.unsupported }
        guard let first = try RecordingCodec.read(file), first.kind == .header, first.time == 0,
              let header = first.header, header.format == "com.serverdash.recording", header.version == 1,
              header.name.utf8.count <= 1024 else { throw RecordingError.unsupported }
        var index: [RecordingIndexEntry] = [], previous: RecordingFrame?
        var time = 0.0, complete = false, interrupted = false, hasImages = false, width = 1.0, height = 1.0
        var validEnd = try file.offset()
        do {
            while true {
                try Task.checkCancellation()
                let offset = try file.offset()
                guard let event = try RecordingCodec.read(file) else { break }
                guard event.time.isFinite, event.time >= time, event.time <= 365 * 86400 else { throw RecordingError.invalid }
                switch event.kind {
                case .header: throw RecordingError.invalid
                case .output:
                    guard let output = event.output, output.count <= 64 * 1024 else { throw RecordingError.invalid }
                case .screen:
                    guard let frame = event.frame else { throw RecordingError.invalid }
                    previous = try frame.applying(to: previous)
                    if frame.changedRows == nil { index.append(.init(time: event.time, offset: offset)) }
                    guard index.count <= 1_000_000 else { throw RecordingError.invalid }
                    hasImages = hasImages || frame.screen.hasImages
                    width = max(width, Double(frame.screen.columns) * frame.appearance.cellWidth)
                    height = max(height, Double(frame.screen.rows) * frame.appearance.cellHeight)
                    guard width * height <= 32_000_000 else { throw RecordingError.invalid }
                case .end:
                    guard !index.isEmpty, event.index == index,
                          (try file.read(upToCount: 1))?.isEmpty != false else { throw RecordingError.invalid }
                    complete = true
                    interrupted = event.reason == "interrupted"
                }
                time = event.time
                validEnd = try file.offset()
                if complete { break }
            }
        } catch is CancellationError { throw CancellationError() }
        catch { if !allowPartial { throw RecordingError.invalid } }
        guard !index.isEmpty, complete || allowPartial else { throw RecordingError.invalid }
        return .init(url: url, header: header, duration: time, index: index, validEnd: validEnd,
                     complete: complete, interrupted: interrupted, hasImages: hasImages, maximumWidth: width, maximumHeight: height)
    }
}

/// A sequential reader with keyframe seek. Only one full screen is kept in memory.
final class RecordingCursor {
    let document: RecordingDocument
    private let file: FileHandle
    private var pending: RecordingEvent?
    private(set) var frame: RecordingFrame?
    private var time = -1.0
    private var lastEventTime = 0.0

    init(_ document: RecordingDocument) throws {
        self.document = document
        file = try FileHandle(forReadingFrom: document.url)
    }
    deinit { try? file.close() }

    func seek(_ requested: Double) throws -> RecordingFrame {
        guard requested.isFinite else { throw RecordingError.invalid }
        let target = min(document.duration, max(0, requested))
        if frame == nil || target < time || target - time > 5 {
            var low = 0, high = document.index.count
            while low < high {
                let middle = low + (high - low) / 2
                if document.index[middle].time <= target { low = middle + 1 } else { high = middle }
            }
            let entry = document.index[max(0, low - 1)]
            try file.seek(toOffset: entry.offset)
            pending = nil; frame = nil; lastEventTime = entry.time
        }
        while true {
            try Task.checkCancellation()
            if pending == nil, try file.offset() < document.validEnd { pending = try RecordingCodec.read(file) }
            guard let next = pending, next.time <= target else { break }
            guard next.time.isFinite, next.time >= lastEventTime else { throw RecordingError.invalid }
            lastEventTime = next.time
            if next.kind == .screen, let value = next.frame { frame = try value.applying(to: frame) }
            pending = nil
        }
        time = target
        guard let frame else { throw RecordingError.invalid }
        return frame
    }

    /// Look ahead without losing the reader position. Output is activity even without a visual change.
    func nextActivity(after target: Double) throws -> Double? {
        let offset = try file.offset()
        defer { try? file.seek(toOffset: offset) }
        if let pending, pending.time > target, pending.kind == .output { return pending.time }
        while try file.offset() < document.validEnd {
            try Task.checkCancellation()
            guard let event = try RecordingCodec.read(file) else { return nil }
            if event.kind == .output, event.time > target { return event.time }
        }
        return nil
    }
}
