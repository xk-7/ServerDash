import AppKit
import Foundation
import SwiftTerm

/// A budget shared by all panes. Reservations cover copied output and unencoded display grids.
final class RecordingWriteBudget: @unchecked Sendable {
    static let shared = RecordingWriteBudget()
    let limit: Int
    private let lock = NSLock()
    private var bytes = 0
    init(limit: Int = 32 * 1024 * 1024) { self.limit = limit }
    func reserve(_ count: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard count <= limit - bytes else { return false }
        bytes += count; return true
    }
    func release(_ count: Int) { lock.lock(); bytes -= count; lock.unlock() }
    var used: Int { lock.lock(); defer { lock.unlock() }; return bytes }
}

final class RecordingDirectoryLease: @unchecked Sendable {
    let url: URL
    private let scoped: Bool
    init(_ url: URL, scoped: Bool) { self.url = url; self.scoped = scoped }
    deinit { if scoped { url.stopAccessingSecurityScopedResource() } }
}

@MainActor
final class RecordingSettings: ObservableObject {
    static let shared = RecordingSettings()
    private let defaults: UserDefaults
    @Published var filenameTemplate: String { didSet { defaults.set(filenameTemplate, forKey: "recordingFilenameTemplate") } }
    @Published private(set) var directoryLabel: String
    var consent: Bool {
        get { defaults.bool(forKey: "recordingOutputConsent") }
        set { defaults.set(newValue, forKey: "recordingOutputConsent") }
    }
    static var defaultDirectory: URL {
        if MacUIFixture.isEnabled { return MacUIFixture.root.appendingPathComponent("Recordings", isDirectory: true) }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ServerDash/recordings", isDirectory: true)
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        filenameTemplate = defaults.string(forKey: "recordingFilenameTemplate") ?? "{date}_{time}_{name}_{id}"
        directoryLabel = defaults.string(forKey: "recordingDirectoryLabel") ?? Self.defaultDirectory.path
    }
    func lease() throws -> RecordingDirectoryLease {
        if let bookmark = defaults.data(forKey: "recordingDirectoryBookmark") {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                                     relativeTo: nil, bookmarkDataIsStale: &stale), !stale else { throw RecordingError.directory }
            let scoped = url.startAccessingSecurityScopedResource()
            guard FileManager.default.isWritableFile(atPath: url.path) else {
                if scoped { url.stopAccessingSecurityScopedResource() }
                throw RecordingError.directory
            }
            return RecordingDirectoryLease(url, scoped: scoped)
        }
        do {
            try FileManager.default.createDirectory(at: Self.defaultDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            return RecordingDirectoryLease(Self.defaultDirectory, scoped: false)
        } catch { throw RecordingError.directory }
    }
    func selectDirectory() throws {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.isWritableFile(atPath: url.path) else { throw RecordingError.directory }
        let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(bookmark, forKey: "recordingDirectoryBookmark")
        defaults.set(url.path, forKey: "recordingDirectoryLabel"); directoryLabel = url.path
    }
    func restoreDefault() {
        defaults.removeObject(forKey: "recordingDirectoryBookmark")
        defaults.removeObject(forKey: "recordingDirectoryLabel")
        directoryLabel = Self.defaultDirectory.path
    }
    static func filename(template: String, header: RecordingHeader) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"; let date = formatter.string(from: header.date)
        formatter.dateFormat = "HH-mm-ss"; let time = formatter.string(from: header.date)
        var value = String(template.prefix(256))
        for (token, replacement) in [("date", date), ("time", time), ("name", header.name), ("id", header.id.uuidString)] {
            value = value.replacingOccurrences(of: "{\(token)}", with: replacement)
        }
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:*?\"<>|{}"))
        value = String(value.unicodeScalars.map { forbidden.contains($0) ? "_" : String($0) }.joined().prefix(140))
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        // A UUID suffix is mandatory even when omitted from a user template; never overwrite a recording.
        while value.utf8.count > 160 { value.removeLast() }
        let stem = value.isEmpty ? "recording" : value
        return stem + (stem.hasSuffix(header.id.uuidString) ? "" : "_" + header.id.uuidString) + ".sdrec"
    }
}

/// Ordered I/O independent of the main actor, including finalization during application shutdown.
final class RecordingWriter: @unchecked Sendable {
    static let pendingWrites = DispatchGroup()
    let partialURL: URL
    let finalURL: URL
    private let queue = DispatchQueue(label: "com.serverdash.recording.writer", qos: .utility)
    private let budget: RecordingWriteBudget
    private let lease: RecordingDirectoryLease
    private var handle: FileHandle?
    private var previous: RecordingFrame?
    private var index: [RecordingIndexEntry] = []
    private var lastKeyframe = -Double.infinity
    private var lastTime = 0.0
    private var failure: Error?
    private let onFailure: @Sendable () -> Void
    private let writeBlock: @Sendable (FileHandle, Data) throws -> Void
    // enqueue/finish are called by the owning main-actor controller; queue state is private to queue.
    init(header: RecordingHeader, lease: RecordingDirectoryLease, filename: String,
         budget: RecordingWriteBudget = .shared,
         writeBlock: @escaping @Sendable (FileHandle, Data) throws -> Void = { try $0.write(contentsOf: $1) },
         onFailure: @escaping @Sendable () -> Void) {
        self.lease = lease; self.budget = budget; self.onFailure = onFailure
        self.writeBlock = writeBlock
        finalURL = lease.url.appendingPathComponent(filename)
        partialURL = finalURL.appendingPathExtension("partial")
        submit(reservation: 0) { [self] in
            let descriptor = Darwin.open(partialURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw RecordingError.write }
            handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try handle?.write(contentsOf: RecordingCodec.magic)
            try write(.init(kind: .header, time: 0, header: header))
        }
    }

    @discardableResult
    func append(output: Data, time: Double) -> Bool {
        guard budget.reserve(output.count + 256) else { return false }
        submit(reservation: output.count + 256) { [self] in
            try write(.init(kind: .output, time: time, output: output))
        }
        return true
    }
    @discardableResult
    func append(frame: RecordingFrame, time: Double) -> Bool {
        let bytes = frame.estimatedBytes
        guard budget.reserve(bytes) else { return false }
        submit(reservation: bytes) { [self] in
            try frame.validate()
            var delta = frame
            let full = previous == nil || time - lastKeyframe >= 5 ||
                previous?.screen.columns != frame.screen.columns || previous?.screen.rows != frame.screen.rows
            if !full, let previous {
                let changed = frame.screen.lines.indices.filter { frame.screen.lines[$0] != previous.screen.lines[$0] }
                delta.changedRows = changed; delta.screen.lines = changed.map { frame.screen.lines[$0] }
                if previous == frame { return }
            }
            guard let handle else { throw RecordingError.write }
            if full { index.append(.init(time: max(lastTime, time), offset: try handle.offset())); lastKeyframe = time }
            try write(.init(kind: .screen, time: time, frame: delta))
            previous = frame
        }
        return true
    }
    func finish(time: Double, reason: String, completion: @escaping @Sendable (Result<URL, Error>) -> Void) {
        Self.pendingWrites.enter()
        queue.async { [self] in
            defer { Self.pendingWrites.leave() }
            do {
                if let failure { throw failure }
                guard !index.isEmpty else { throw RecordingError.write }
                try write(.init(kind: .end, time: time, index: index, reason: reason))
                try handle?.synchronize(); try handle?.close(); handle = nil
                if reason != "interrupted" {
                    try FileManager.default.moveItem(at: partialURL, to: finalURL)
                    completion(.success(finalURL))
                } else { completion(.success(partialURL)) }
            } catch {
                try? handle?.synchronize(); try? handle?.close(); handle = nil
                completion(.failure(RecordingError.write))
            }
        }
    }
    private func submit(reservation: Int, work: @escaping @Sendable () throws -> Void) {
        Self.pendingWrites.enter()
        queue.async { [self] in
            defer { budget.release(reservation); Self.pendingWrites.leave() }
            guard failure == nil else { return }
            do { try autoreleasepool(invoking: work) }
            catch { failure = error; onFailure() }
        }
    }
    private func write(_ value: RecordingEvent) throws {
        guard let handle else { throw RecordingError.write }
        var event = value
        event.time = max(lastTime, event.time); lastTime = event.time
        try writeBlock(handle, RecordingCodec.encode(event))
    }
}

struct RecordingListItem: Identifiable, Sendable {
    var id: URL { url }
    var url: URL
    var date: Date
    var size: Int
    var partial: Bool { url.pathExtension == "partial" }
}

@MainActor
final class RecordingStore: ObservableObject {
    static let shared = RecordingStore()
    @Published private(set) var items: [RecordingListItem] = []
    @Published private(set) var activePaneIDs: Set<UUID> = []
    @Published private(set) var activeURLs: Set<URL> = []
    @Published var message: String?
    @Published var loading = false
    private var refreshTask: Task<Void, Never>?
    private var lease: RecordingDirectoryLease?
    private var generation = UUID()

    func began(pane: UUID, url: URL) { activePaneIDs.insert(pane); activeURLs.insert(url) }
    func stopping(pane: UUID) { activePaneIDs.remove(pane) }
    func finished(url: URL) { activeURLs.remove(url); refresh() }
    func refresh() {
        refreshTask?.cancel(); let token = UUID(); generation = token; loading = true
        do {
            let access = try RecordingSettings.shared.lease(); lease = access
            refreshTask = Task {
                do {
                    let scan = Task.detached(priority: .utility) {
                        let urls = try FileManager.default.contentsOfDirectory(at: access.url,
                            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .creationDateKey, .fileSizeKey], options: [.skipsHiddenFiles])
                        return try urls.compactMap { url -> RecordingListItem? in
                            try Task.checkCancellation()
                            guard url.pathExtension == "sdrec" || url.lastPathComponent.hasSuffix(".sdrec.partial") else { return nil }
                            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .creationDateKey, .fileSizeKey])
                            guard info.isRegularFile == true, info.isSymbolicLink != true else { return nil }
                            return .init(url: url, date: info.creationDate ?? .distantPast, size: info.fileSize ?? 0)
                        }.sorted { $0.date > $1.date }
                    }
                    let values = try await withTaskCancellationHandler { try await scan.value } onCancel: { scan.cancel() }
                    guard generation == token, !Task.isCancelled else { return }
                    items = values; loading = false
                } catch { if generation == token { loading = false; message = "无法读取录制目录。" } }
            }
        } catch { loading = false; message = RecordingError.directory.localizedDescription }
    }
    func trash(_ item: RecordingListItem) {
        guard !activeURLs.contains(item.url) else { return }
        do { try FileManager.default.trashItem(at: item.url, resultingItemURL: nil); refresh() }
        catch { message = "无法移到废纸篓，请检查文件权限。" }
    }
}

@MainActor
final class TerminalRecordingController: ObservableObject {
    enum State { case idle, recording, saving }
    let paneID: UUID
    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed = 0.0
    @Published var message: String?
    @Published private(set) var hasImages = false
    private var writer: RecordingWriter?
    private var clockStart = 0.0
    private var timer: Timer?
    private var dirty = false
    private var lastCapture = 0.0
    private var generation = UUID()
    private var capture: (() -> RecordingFrame)?
    init(paneID: UUID) { self.paneID = paneID }
    var isRecording: Bool { state == .recording }

    func start(name: String, connected: Bool, initial: RecordingFrame,
               capture: @escaping () -> RecordingFrame,
               lease: RecordingDirectoryLease? = nil) {
        guard connected, state == .idle else { return }
        do {
            try initial.validate()
            let access = try lease ?? RecordingSettings.shared.lease()
            let header = RecordingHeader(name: String(name.prefix(128)))
            let filename = RecordingSettings.filename(template: RecordingSettings.shared.filenameTemplate, header: header)
            let token = UUID(); generation = token
            let writer = RecordingWriter(header: header, lease: access, filename: filename) { [weak self] in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.fail(.write)
                }
            }
            self.writer = writer; self.capture = capture
            clockStart = ProcessInfo.processInfo.systemUptime; elapsed = 0; lastCapture = 0
            state = .recording; message = nil; hasImages = initial.screen.hasImages
            RecordingStore.shared.began(pane: paneID, url: writer.partialURL)
            guard writer.append(frame: initial, time: 0) else { fail(.overloaded); return }
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        } catch { message = error is RecordingError ? error.localizedDescription : RecordingError.directory.localizedDescription }
    }
    func output(_ data: Data) {
        guard isRecording, let writer else { return }
        let time = now
        // Bound single events independently of the native PTY read size.
        for start in stride(from: 0, to: data.count, by: 64 * 1024) {
            let chunk = data.subdata(in: start..<min(start + 64 * 1024, data.count))
            if !writer.append(output: chunk, time: time) { fail(.overloaded); return }
        }
        dirty = true
    }
    func displayChanged() { if isRecording { dirty = true } }
    private var now: Double { max(0, ProcessInfo.processInfo.systemUptime - clockStart) }
    private func tick() {
        guard isRecording else { return }
        let time = now
        if time - elapsed >= 0.25 { elapsed = time }
        if dirty || time - lastCapture >= 5 { captureFrame(time: time) }
    }
    private func captureFrame(time: Double) {
        guard let frame = capture?(), let writer else { return }
        hasImages = hasImages || frame.screen.hasImages
        dirty = false; lastCapture = time
        if !writer.append(frame: frame, time: time) { fail(.overloaded) }
    }
    func stop(reason: String = "user") {
        guard isRecording, let writer else { return }
        let duration = now
        // Capture the last parsed output even when stop occurs before the next display tick.
        var endReason = reason
        if let frame = capture?(), !writer.append(frame: frame, time: duration) {
            message = RecordingError.overloaded.localizedDescription
            endReason = "interrupted"
        }
        state = .saving; timer?.invalidate(); timer = nil; capture = nil; self.writer = nil; elapsed = duration
        RecordingStore.shared.stopping(pane: paneID)
        writer.finish(time: duration, reason: endReason) { [self] result in
            Task { @MainActor in
                state = .idle
                switch result {
                case .success: if message == nil { message = "录制已保存，可在侧栏“录制”中回放。" }
                case .failure: message = RecordingError.write.localizedDescription
                }
                RecordingStore.shared.finished(url: writer.partialURL)
                if case .failure = result { RecordingStore.shared.message = message }
            }
        }
    }
    private func fail(_ error: RecordingError) {
        message = error.localizedDescription
        RecordingStore.shared.message = message
        stop(reason: "interrupted")
    }
}
