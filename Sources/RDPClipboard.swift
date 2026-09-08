import AppKit
import Darwin
import Foundation
import UniformTypeIdentifiers

struct RDPClipboardFile: Equatable, Sendable {
    let name: String
    let size: UInt64
    static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", name.utf16.count < 260,
              !name.contains("/"), !name.contains("\\"), !name.contains(":"),
              !name.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }) else {
            throw RDPValidationError.invalidShare
        }
    }
    static func decode(_ data: Data) throws -> [Self] {
        guard data.count >= 4 else { throw RDPValidationError.invalidShare }
        let count = Int(data.rdpUInt32(0))
        guard count <= 10000, data.count == 4 + count * 592 else { throw RDPValidationError.invalidShare }
        var files: [Self] = []
        for index in 0..<count {
            let start = 4 + index * 592
            guard data.rdpUInt32(start + 36) & 0x10 == 0, data.rdpUInt32(start) & 0x40 != 0 else {
                throw RDPValidationError.invalidShare // Folders use explicit directory mapping, not recursive paste.
            }
            let units = stride(from: start + 72, to: start + 592, by: 2).map { UInt16(data[$0]) | UInt16(data[$0 + 1]) << 8 }
            guard let end = units.firstIndex(of: 0) else { throw RDPValidationError.invalidShare }
            let name = String(decoding: units[..<end], as: UTF16.self)
            try validateName(name)
            let size = UInt64(data.rdpUInt32(start + 64)) << 32 | UInt64(data.rdpUInt32(start + 68))
            files.append(.init(name: name, size: size))
        }
        guard Set(files.map { $0.name.precomposedStringWithCanonicalMapping.lowercased() }).count == count else { throw RDPValidationError.invalidShare }
        return files
    }
    static func encode(_ files: [Self]) throws -> Data {
        guard files.count <= 10000 else { throw RDPValidationError.invalidShare }
        var data = Data(count: 4 + files.count * 592)
        data.rdpSet32(0, UInt32(files.count))
        for (index, file) in files.enumerated() {
            try validateName(file.name)
            let start = 4 + index * 592
            data.rdpSet32(start, 0x44); data.rdpSet32(start + 36, 0x80)
            data.rdpSet32(start + 64, UInt32(file.size >> 32)); data.rdpSet32(start + 68, UInt32(truncatingIfNeeded: file.size))
            for (offset, unit) in file.name.utf16.enumerated() {
                data[start + 72 + offset * 2] = UInt8(truncatingIfNeeded: unit)
                data[start + 73 + offset * 2] = UInt8(unit >> 8)
            }
        }
        return data
    }
}

private extension Data {
    func rdpUInt32(_ offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(self[offset + $1]) << ($1 * 8) }
    }
    mutating func rdpSet32(_ offset: Int, _ value: UInt32) {
        for byte in 0..<4 { self[offset + byte] = UInt8(truncatingIfNeeded: value >> (byte * 8)) }
    }
}

private final class RDPClipboardSource {
    let fd: Int32
    let file: RDPClipboardFile
    let url: URL
    let scoped: Bool
    init(url: URL) throws {
        self.url = url
        scoped = url.startAccessingSecurityScopedResource()
        fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        var info = stat()
        guard fd >= 0, fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
            if fd >= 0 { Darwin.close(fd) }
            if scoped { url.stopAccessingSecurityScopedResource() }
            throw RDPValidationError.invalidShare
        }
        file = RDPClipboardFile(name: url.lastPathComponent, size: UInt64(info.st_size))
    }
    deinit { Darwin.close(fd); if scoped { url.stopAccessingSecurityScopedResource() } }
    func read(offset: UInt64, count: UInt32, sizeOnly: Bool) -> Data? {
        if sizeOnly { var size = file.size.littleEndian; return Data(bytes: &size, count: 8) }
        guard count <= 1024 * 1024, offset <= file.size, offset <= UInt64(Int64.max) else { return nil }
        var data = Data(count: min(Int(count), Int(file.size - offset)))
        let result = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, off_t(offset)) }
        guard result >= 0 else { return nil }
        data.count = result
        return data
    }
}

/// Each connection owns its clipboard and file descriptors. Only the active owner touches NSPasteboard.
final class RDPClipboardSession: NSObject, ObservableObject, @unchecked Sendable {
    @Published private(set) var message = ""
    @Published private(set) var progress: Double?
    @Published private(set) var uploadProgress: Double?
    private let lock = NSRecursiveLock()
    private var settings: RDPSettings
    private var client: SDRDPClient?
    private var active = false
    private var revision = UUID()
    private var localChange = -1
    private var localText: Data?
    private var sources: [RDPClipboardSource] = []
    private var remoteFiles: [RDPClipboardFile] = []
    private var remoteFormat: UInt32 = 0
    private var timer: Timer?
    private var transfer: RDPFileDownload?
    private var nextStream: UInt32 = 1
    private var promises: [RDPFilePromise] = []
    private var outgoing: [UInt32: Date] = [:]
    private var outgoingOffsets: [UInt32: UInt64] = [:]
    private var uploadUpdateScheduled = false
    private var pending: [(UInt32, URL, UUID, (Error?) -> Void)] = []
    private var fileRevision = UUID()
    @MainActor private static weak var activeOwner: RDPClipboardSession?
    var hasActiveTransfer: Bool { lock.lock(); defer { lock.unlock() }; return transfer != nil || !pending.isEmpty || !outgoing.isEmpty }
    init(settings: RDPSettings) { self.settings = settings; super.init() }
    func reset(settings: RDPSettings) { cancel(); lock.lock(); self.settings = settings; lock.unlock() }
    func attach(_ client: SDRDPClient) {
        lock.lock(); self.client = client; let currentRevision = revision; lock.unlock()
        client.clipboardRequested = { [weak self] format in self?.localData(format: format, revision: currentRevision) }
        client.fileRequested = { [weak self] index, offset, count, sizeOnly in
            guard let self else { return nil }
            self.lock.lock(); defer { self.lock.unlock() }
            guard self.revision == currentRevision, self.active || self.outgoing[index] != nil,
                  self.sources.indices.contains(Int(index)) else { return nil }
            let source = self.sources[Int(index)]
            let data = source.read(offset: offset, count: count, sizeOnly: sizeOnly)
            guard let data else { self.outgoing.removeValue(forKey: index); self.outgoingOffsets.removeValue(forKey: index); self.updateUpload(); return nil }
            self.outgoingOffsets[index] = sizeOnly ? (self.outgoingOffsets[index] ?? 0) : max(self.outgoingOffsets[index] ?? 0, offset + UInt64(data.count))
            if !sizeOnly, offset + UInt64(data.count) >= source.file.size {
                self.outgoing.removeValue(forKey: index); self.outgoingOffsets.removeValue(forKey: index)
            }
            else {
                let activity = Date(); self.outgoing[index] = activity
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) { [weak self] in
                    guard let self else { return }; self.lock.lock(); defer { self.lock.unlock() }
                    if self.revision == currentRevision, self.outgoing[index] == activity {
                        self.outgoing.removeValue(forKey: index); self.outgoingOffsets.removeValue(forKey: index); self.updateUpload()
                    }
                }
            }
            self.updateUpload()
            if !self.active && self.outgoing.isEmpty {
                self.sources = []; _ = self.client?.announceClipboard(false, files: false)
            }
            return data
        }
        client.clipboardFormats = { [weak self, weak client] format in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            guard self.revision == currentRevision else { return }
            self.fileRevision = UUID(); self.remoteFormat = format; self.remoteFiles = []
            self.cancelDownloads()
            if format != 0 && self.active && self.settings.fileClipboard { _ = client?.requestClipboard(format) }
        }
        client.clipboardReceived = { [weak self] data, format in
            Task { @MainActor [weak self] in self?.receive(data, format: format, revision: currentRevision) }
        }
        client.fileReceived = { [weak self] stream, data, success in self?.receiveFile(stream: stream, data: data, success: success, revision: currentRevision) }
    }
    @MainActor func setActive(_ value: Bool) {
        if value {
            if let previous = Self.activeOwner, previous !== self { previous.setActive(false) }
            Self.activeOwner = self
        } else if Self.activeOwner === self { Self.activeOwner = nil }
        lock.lock(); let changed = active != value; active = value; lock.unlock()
        guard changed else { return }
        timer?.invalidate(); timer = nil
        localChange = NSPasteboard.general.changeCount
        if value {
            timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.publishLocalClipboard() }
            }
        } else {
            lock.lock(); localText = nil
            // Previously requested file chunks may finish after focus changes; new files cannot start.
            if outgoing.isEmpty { sources = []; _ = client?.announceClipboard(false, files: false) }
            lock.unlock()
        }
    }
    @MainActor func publishLocalClipboard(explicit: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        guard active, NSApp.isActive, outgoing.isEmpty, let client else { return }
        let pasteboard = NSPasteboard.general
        guard explicit || localChange != pasteboard.changeCount else { return }
        localChange = pasteboard.changeCount
        localText = nil; sources = []
        do {
            if settings.fileClipboard, let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
                guard urls.count <= 10000 else { throw RDPValidationError.invalidShare }
                sources = try urls.map(RDPClipboardSource.init)
                _ = try RDPClipboardFile.encode(sources.map(\.file))
            } else if settings.textClipboard, let text = pasteboard.string(forType: .string), text.utf8.count <= 8 * 1024 * 1024 {
                localText = text.data(using: .utf16LittleEndian).map { $0 + Data([0, 0]) }
            }
            _ = client.announceClipboard(localText != nil, files: !sources.isEmpty)
        } catch { message = "无法共享此剪贴板内容。文件夹请使用目录映射。"; sources = [] }
    }
    private func localData(format: UInt32, revision: UUID) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard active, self.revision == revision else { return nil }
        if format == 13 { return localText }
        if format == 0xC001 { return try? RDPClipboardFile.encode(sources.map(\.file)) }
        return nil
    }
    @MainActor private func receive(_ data: Data, format: UInt32, revision: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard self.revision == revision, active, NSApp.isActive else { return }
        let pasteboard = NSPasteboard.general
        if format == 13, settings.textClipboard, data.count.isMultiple(of: 2), data.count <= 16 * 1024 * 1024,
           let text = String(data: data, encoding: .utf16LittleEndian) {
            pasteboard.clearContents()
            pasteboard.setString(text.components(separatedBy: "\0")[0], forType: .string)
        } else if format == remoteFormat, settings.fileClipboard {
            do {
                remoteFiles = try RDPClipboardFile.decode(data)
                promises = remoteFiles.enumerated().map { RDPFilePromise(owner: self, index: UInt32($0.offset), file: $0.element, revision: fileRevision) }
                let providers = promises.map { NSFilePromiseProvider(fileType: UTType.data.identifier, delegate: $0) }
                pasteboard.clearContents(); pasteboard.writeObjects(providers)
            } catch { message = "远端文件列表无效或包含不支持的路径／文件夹。"; remoteFiles = [] }
        }
        localChange = pasteboard.changeCount // Do not echo the remote clipboard back to the server.
    }
    func download(index: UInt32, destination: URL, revision: UUID, completion: @escaping (Error?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard self.fileRevision == revision, remoteFiles.indices.contains(Int(index)), let client else {
            completion(RDPValidationError.invalidShare); return
        }
        if transfer != nil {
            guard pending.count < 10000 else { completion(RDPValidationError.invalidShare); return }
            pending.append((index, destination, revision, completion)); return
        }
        do {
            let file = remoteFiles[Int(index)]
            let download = try RDPFileDownload(index: index, file: file, destination: destination, completion: completion)
            transfer = download
            if file.size == 0 { finishTransfer(error: nil); return }
            let stream = nextStream; nextStream &+= 1; download.stream = stream
            if !client.requestFile(index, offset: 0, count: UInt32(min(file.size, 1024 * 1024)), stream: stream) { finishTransfer(error: CancellationError()) }
            updateProgress(0)
            watch(download)
        } catch { completion(error) }
    }
    private func receiveFile(stream: UInt32, data: Data, success: Bool, revision: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard self.revision == revision, let transfer, transfer.stream == stream else { return }
        guard success, !data.isEmpty, data.count <= 1024 * 1024,
              UInt64(data.count) <= transfer.file.size - transfer.offset else { finishTransfer(error: RDPValidationError.invalidShare); return }
        do {
            try transfer.handle.write(contentsOf: data)
            transfer.offset += UInt64(data.count); transfer.lastActivity = .now
            updateProgress(Double(transfer.offset) / Double(transfer.file.size))
            if transfer.offset == transfer.file.size { finishTransfer(error: nil) }
            else {
                transfer.stream = nextStream; nextStream &+= 1
                if client?.requestFile(transfer.index, offset: transfer.offset,
                    count: UInt32(min(transfer.file.size - transfer.offset, 1024 * 1024)), stream: transfer.stream) != true {
                    finishTransfer(error: CancellationError())
                }
            }
        } catch { finishTransfer(error: error) }
    }
    private func watch(_ download: RDPFileDownload) {
        let current = revision
        let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        watchdog.schedule(deadline: .now() + 30, repeating: 5)
        watchdog.setEventHandler { [weak self, weak download] in
            guard let self, let download else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            if self.revision == current, self.transfer === download, Date().timeIntervalSince(download.lastActivity) >= 30 {
                self.finishTransfer(error: URLError(.timedOut))
            }
        }
        download.watchdog = watchdog; watchdog.resume()
    }
    private func updateProgress(_ value: Double?) {
        let current = revision
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; self.lock.lock(); defer { self.lock.unlock() }
            if self.revision == current { self.progress = value }
        }
    }
    private func updateUpload() {
        guard !uploadUpdateScheduled else { return }; uploadUpdateScheduled = true
        let current = revision
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }; self.lock.lock(); defer { self.lock.unlock() }
            guard self.revision == current else { return }; self.uploadUpdateScheduled = false
            var completed = 0.0, total = 0.0
            for (index, offset) in self.outgoingOffsets where self.sources.indices.contains(Int(index)) {
                completed += Double(offset); total += Double(self.sources[Int(index)].file.size)
            }
            self.uploadProgress = self.outgoing.isEmpty ? nil : (total > 0 ? min(1, completed / total) : 0)
        }
    }
    private func finishTransfer(error: Error?) {
        guard let transfer else { return }
        self.transfer = nil
        transfer.watchdog?.cancel(); transfer.watchdog = nil
        var failure = error
        do { try transfer.handle.close() } catch { failure = error }
        if failure == nil {
            // Link is an atomic no-overwrite operation on the same volume.
            if link(transfer.temporary.path, transfer.destination.path) != 0 { failure = CocoaError(.fileWriteFileExists) }
        }
        try? FileManager.default.removeItem(at: transfer.temporary)
        updateProgress(nil)
        transfer.completion(failure)
        if !pending.isEmpty {
            let next = pending.removeFirst()
            download(index: next.0, destination: next.1, revision: next.2, completion: next.3)
        }
    }
    private func cancelDownloads() {
        let requests = pending; pending = []
        requests.forEach { $0.3(CancellationError()) }
        finishTransfer(error: CancellationError())
    }
    func cancelTransfer() {
        lock.lock(); defer { lock.unlock() }
        cancelDownloads(); outgoing = [:]; outgoingOffsets = [:]; sources = []; updateUpload()
        _ = client?.announceClipboard(false, files: false)
    }
    func cancel() {
        lock.lock(); revision = UUID(); fileRevision = UUID(); let current = revision
        active = false; client = nil; localText = nil; sources = []; remoteFiles = []; outgoing = [:]; outgoingOffsets = [:]
        uploadUpdateScheduled = false; updateUpload()
        cancelDownloads(); updateProgress(nil); lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; self.lock.lock(); defer { self.lock.unlock() }
            guard self.revision == current else { return }
            self.timer?.invalidate(); self.timer = nil; self.promises = []
        }
    }
}

private final class RDPFileDownload {
    let index: UInt32
    let file: RDPClipboardFile
    let destination: URL
    let temporary: URL
    let handle: FileHandle
    let completion: (Error?) -> Void
    var offset: UInt64 = 0
    var stream: UInt32 = 0
    var lastActivity = Date()
    var watchdog: DispatchSourceTimer?
    init(index: UInt32, file: RDPClipboardFile, destination: URL, completion: @escaping (Error?) -> Void) throws {
        self.index = index; self.file = file; self.destination = destination; self.completion = completion
        temporary = destination.deletingLastPathComponent().appendingPathComponent(".serverdash-rdp-\(UUID().uuidString).partial")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
}

private final class RDPFilePromise: NSObject, NSFilePromiseProviderDelegate {
    weak var owner: RDPClipboardSession?
    let index: UInt32
    let file: RDPClipboardFile
    let revision: UUID
    init(owner: RDPClipboardSession, index: UInt32, file: RDPClipboardFile, revision: UUID) {
        self.owner = owner; self.index = index; self.file = file; self.revision = revision
    }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { file.name }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        guard let owner else { completionHandler(CancellationError()); return }
        owner.download(index: index, destination: url, revision: revision, completion: completionHandler)
    }
}
