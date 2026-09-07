import SwiftUI
import UniformTypeIdentifiers

struct MobileSFTPView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ObservedObject var controller: MobileSFTPController
    let reconnect: () -> Void
    var body: some View {
        transferLayer
    }

    private var content: some View {
        Group {
            if controller.interrupted || (!controller.loading && controller.client == nil) {
                ContentUnavailableView {
                    Label("SFTP 未连接", systemImage: "pause.circle")
                } description: {
                    Text(controller.errorMessage ?? "连接已关闭，请手动重新连接。")
                } actions: {
                    Button("重新连接", action: reconnect)
                        .buttonStyle(.borderedProminent)
                }
            } else if controller.loading && controller.items.isEmpty {
                ProgressView("正在连接 SFTP…")
            } else if horizontalSizeClass == .regular {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 190), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(controller.items) { item in itemCard(item) }
                    }
                    .padding()
                }
                .background(Color.appGround)
            } else {
                List(controller.items) { item in itemRow(item) }
                    .overlay {
                        if controller.items.isEmpty && !controller.loading {
                            ContentUnavailableView("文件夹为空", systemImage: "folder")
                        }
                    }
            }
        }
    }

    private var navigationLayer: some View {
        content
        .navigationTitle(URL(fileURLWithPath: controller.path).lastPathComponent.isEmpty ? "/" : URL(fileURLWithPath: controller.path).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 10) {
                Button { Task { await controller.open(RemotePath.parent(of: controller.path)) } } label: {
                    Image(systemName: "chevron.up")
                        .frame(width: 44, height: 44)
                }
                .disabled(controller.path == "/" || controller.loading)
                Text(controller.path)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if controller.loading { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal)
            .background(.bar)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { Task { await controller.open(controller.path) } } label: { Image(systemName: "arrow.clockwise") }
                Menu {
                    Button("上传文件", systemImage: "square.and.arrow.up") { controller.showingImporter = true }
                    Button("新建文件夹", systemImage: "folder.badge.plus") {
                        controller.newName = ""
                        controller.showingNewDirectory = true
                    }
                    Button("新建文件", systemImage: "doc.badge.plus") {
                        controller.newName = ""
                        controller.showingNewFile = true
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
    }

    private var lifecycleLayer: some View {
        navigationLayer
        .onAppear { controller.beginIfNeeded() }
        .onDisappear { controller.showingImporter = false; controller.showingExporter = false; controller.showingUploadConflict = false; controller.pendingUploadURL = nil }
    }

    private var documentLayer: some View {
        lifecycleLayer
        .fileImporter(
            isPresented: $controller.showingImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                controller.pendingUploadURL = url
                controller.prepareUpload(url)
            case .failure(let error):
                controller.errorMessage = error.localizedDescription
            }
        }
        .fileExporter(
            isPresented: $controller.showingExporter,
            document: controller.exportDocument,
            contentType: .data,
            defaultFilename: controller.exportName
        ) { result in
            if case .failure(let error) = result { controller.errorMessage = error.localizedDescription }
            controller.exportDocument = nil
        }
    }

    private var creationLayer: some View {
        documentLayer
        .alert("新建文件夹", isPresented: $controller.showingNewDirectory) {
            TextField("名称", text: $controller.newName)
            Button("取消", role: .cancel) {}
            Button("创建") { Task { await controller.create(directory: true) } }
        }
        .alert("新建文件", isPresented: $controller.showingNewFile) {
            TextField("名称", text: $controller.newName)
            Button("取消", role: .cancel) {}
            Button("创建") { Task { await controller.create(directory: false) } }
        }
    }

    private var renameMoveLayer: some View {
        creationLayer
        .alert("重命名", isPresented: $controller.showingRename) {
            TextField("新名称", text: $controller.newName)
            Button("取消", role: .cancel) { controller.pendingRename = nil }
            Button("保存") {
                if let item = controller.pendingRename { Task { await controller.rename(item, to: controller.newName) } }
                controller.pendingRename = nil
            }
        }
        .alert("移动到目录", isPresented: $controller.showingMove) {
            TextField("远程目录", text: $controller.moveDirectory)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("取消", role: .cancel) { controller.pendingMove = nil }
            Button("移动") {
                if let item = controller.pendingMove { Task { await controller.move(item, to: controller.moveDirectory) } }
                controller.pendingMove = nil
            }
        } message: {
            Text("可输入绝对路径，或相对于当前目录的路径。")
        }
    }

    private var confirmationLayer: some View {
        renameMoveLayer
        .confirmationDialog(
            "远程目录已有同名项目",
            isPresented: $controller.showingUploadConflict,
            titleVisibility: .visible
        ) {
            Button("覆盖") { controller.startPendingUpload(renameOnConflict: false) }
            Button("自动重命名") { controller.startPendingUpload(renameOnConflict: true) }
            Button("跳过", role: .cancel) { controller.pendingUploadURL = nil }
        } message: {
            Text("选择上传时的冲突处理方式。")
        }
        .confirmationDialog(
            "删除 \(controller.pendingDelete?.name ?? "")？",
            isPresented: Binding(
                get: { controller.pendingDelete != nil },
                set: { if !$0 { controller.pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let item = controller.pendingDelete { Task { await controller.delete(item) } }
                controller.pendingDelete = nil
            }
            Button("取消", role: .cancel) { controller.pendingDelete = nil }
        } message: {
            Text(controller.pendingDelete?.isDirectory == true ? "文件夹及其内容将被递归删除。" : "此操作无法撤销。")
        }
    }

    private var transferLayer: some View {
        confirmationLayer
        .alert("SFTP 操作失败", isPresented: Binding(
            get: { controller.errorMessage != nil },
            set: { if !$0 { controller.errorMessage = nil } }
        )) {
            Button("好") { controller.errorMessage = nil }
        } message: {
            Text(controller.errorMessage ?? "未知错误")
        }
        .safeAreaInset(edge: .bottom) {
            if controller.exportDocument != nil {
                Button("下载已完成 · 保存到文件") { controller.showingExporter = true }
                    .frame(minHeight: 44)
            }
        }
        .overlay(alignment: .bottom) {
            if let progress = controller.progress {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(progress.message).font(.caption)
                        Spacer()
                        Text(DisplayFormat.speed(progress.speedBytesPerSecond))
                            .font(.caption.monospacedDigit())
                    }
                    ProgressView(value: progress.fraction)
                    Button("取消传输", role: .destructive) {
                        controller.cancelTransfer(showMessage: true)
                    }
                    .frame(minHeight: 44)
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding()
            }
        }
    }

    private func itemRow(_ item: RemoteFileItem) -> some View {
        Button { Task { await controller.activate(item) } } label: {
            HStack(spacing: 12) {
                itemIcon(item)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name).foregroundStyle(.primary).lineLimit(1)
                    Text(item.isDirectory ? "文件夹" : DisplayFormat.bytes(Double(item.size)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if item.isDirectory { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
            }
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .contextMenu { itemActions(item) }
    }

    private func itemCard(_ item: RemoteFileItem) -> some View {
        Button { Task { await controller.activate(item) } } label: {
            VStack(alignment: .leading, spacing: 12) {
                itemIcon(item).font(.title)
                Text(item.name).font(.headline).foregroundStyle(.primary).lineLimit(2)
                Text(item.isDirectory ? "文件夹" : DisplayFormat.bytes(Double(item.size)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .leading)
            .padding()
            .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .contextMenu { itemActions(item) }
    }

    @ViewBuilder
    private func itemIcon(_ item: RemoteFileItem) -> some View {
        Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
            .foregroundStyle(item.isDirectory ? Color.appAccent : .secondary)
            .frame(width: 36, height: 36)
    }

    @ViewBuilder
    private func itemActions(_ item: RemoteFileItem) -> some View {
        if !item.isDirectory {
            Button("下载到文件", systemImage: "square.and.arrow.down") {
                controller.startDownload(item)
            }
        }
        Button("重命名", systemImage: "pencil") {
            controller.pendingRename = item
            controller.newName = item.name
            controller.showingRename = true
        }
        Button("移动", systemImage: "folder") {
            controller.pendingMove = item
            controller.moveDirectory = controller.path
            controller.showingMove = true
        }
        Button("删除", systemImage: "trash", role: .destructive) { controller.pendingDelete = item }
    }


}

struct MobileTransferDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

@MainActor
final class MobileSFTPController: ObservableObject {
    private(set) var config: ServerConnectionConfig
    let engine: any RemoteConnectionEngine
    let broker: MobileHostTrustBroker
    private var started = false
    private var closed = false
    private var generation = UUID()
    private var directoryGeneration = UUID()
    private var transferGeneration = UUID()
    private var connectionTask: Task<Void, Never>?
    var hasActiveTransfer: Bool { transferTask != nil }
    @Published var session: (any RemoteSession)?
    @Published var client: (any RemoteFileClient)?
    @Published var path = "."
    @Published var items: [RemoteFileItem] = []
    @Published var loading = true
    @Published var interrupted = false
    @Published var errorMessage: String?
    @Published var showingImporter = false
    @Published var pendingUploadURL: URL?
    @Published var progress: SFTPProgress?
    @Published var showingNewDirectory = false
    @Published var showingNewFile = false
    @Published var showingRename = false
    @Published var showingMove = false
    @Published var showingUploadConflict = false
    @Published var newName = ""
    @Published var pendingDelete: RemoteFileItem?
    @Published var pendingRename: RemoteFileItem?
    @Published var pendingMove: RemoteFileItem?
    @Published var moveDirectory = ""
    @Published var exportDocument: MobileTransferDocument?
    @Published var exportName = "download"
    @Published var showingExporter = false
    @Published var transferTask: Task<Void, Never>?


    init(config: ServerConnectionConfig, engine: any RemoteConnectionEngine, broker: MobileHostTrustBroker, initialPath: String = ".") {
        self.config = config; self.engine = engine; self.broker = broker
        path = initialPath.isEmpty ? "." : initialPath
    }

    func stop(background: Bool = false) async {
        let stopping = UUID()
        generation = stopping
        transferGeneration = UUID()
        connectionTask?.cancel()
        let transfer = transferTask
        transfer?.cancel()
        closed = !background
        started = true
        interrupted = background
        loading = false
        progress = nil
        pendingUploadURL = nil
        if !background { exportDocument = nil }
        await closeConnection()
        await transfer?.value
        if generation == stopping { transferTask = nil }
    }

    func beginIfNeeded() {
        guard !started, !closed else { return }
        started = true
        connectionTask = Task { [self] in await connectAndLoad() }
    }

    func reconnect(config: ServerConnectionConfig) {
        self.config = config
        connectionTask?.cancel()
        connectionTask = Task { [self] in await connectAndLoad() }
    }

    func connectAndLoad() async {
        guard !closed, !Task.isCancelled else { return }
        started = true
        let request = UUID()
        generation = request
        loading = true
        interrupted = false
        errorMessage = nil
        cancelTransfer(showMessage: false)
        let oldTransfer = transferTask
        await closeConnection()
        await oldTransfer?.value
        guard generation == request, !Task.isCancelled else { return }
        do {
            let newSession = try await engine.connect(config) { [broker] presentation in
                try await broker.evaluate(presentation)
            }
            guard generation == request, !Task.isCancelled else { await newSession.close(); return }
            let newClient: any RemoteFileClient
            do { newClient = try await newSession.openSFTP() }
            catch { await newSession.close(); throw error }
            guard generation == request, !Task.isCancelled else { await newClient.close(); await newSession.close(); return }
            session = newSession
            client = newClient
            guard generation == request, !Task.isCancelled else { return }
            await open(path)
        } catch {
            guard generation == request else { return }
            loading = false
            errorMessage = error.localizedDescription
        }
    }

    func open(_ requestedPath: String) async {
        guard let client, !closed else { return }
        let request = UUID(), connection = generation
        directoryGeneration = request
        loading = true
        defer { if directoryGeneration == request && generation == connection { loading = false } }
        do {
            let listing = try await client.list(path: requestedPath)
            guard directoryGeneration == request, generation == connection, !Task.isCancelled else { return }
            path = listing.path
            items = listing.items
        } catch {
            guard directoryGeneration == request, generation == connection else { return }
            errorMessage = error.localizedDescription
        }
    }

    func activate(_ item: RemoteFileItem) async {
        if item.isDirectory {
            await open(item.path)
        } else {
            startDownload(item)
        }
    }

    func create(directory: Bool) async {
        guard let client, !closed else { return }
        let request = generation
        do {
            if directory {
                try await client.createDirectory(named: newName, in: path)
            } else {
                try await client.createFile(named: newName, in: path)
            }
            guard generation == request, !Task.isCancelled else { return }
            await open(path)
        } catch {
            guard generation == request else { return }
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ item: RemoteFileItem) async {
        guard let client, !closed else { return }
        let request = generation
        do {
            try await client.delete(item, recursive: item.isDirectory)
            guard generation == request, !Task.isCancelled else { return }
            await open(path)
        } catch {
            guard generation == request else { return }
            errorMessage = error.localizedDescription
        }
    }

    func rename(_ item: RemoteFileItem, to name: String) async {
        guard let client, !closed else { return }
        let request = generation
        do {
            try await client.rename(item, to: name)
            guard generation == request, !Task.isCancelled else { return }
            await open(path)
        } catch {
            guard generation == request else { return }
            errorMessage = error.localizedDescription
        }
    }

    func move(_ item: RemoteFileItem, to destination: String) async {
        guard let client, !closed else { return }
        let request = generation
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = SFTPError.invalidName.localizedDescription
            return
        }
        let resolved = trimmed.hasPrefix("/")
            ? RemotePath.normalize(trimmed)
            : RemotePath.child(trimmed, of: path)
        do {
            try await client.move(item, to: resolved)
            guard generation == request, !Task.isCancelled else { return }
            await open(path)
        } catch {
            guard generation == request else { return }
            errorMessage = error.localizedDescription
        }
    }

    func prepareUpload(_ url: URL) {
        if items.contains(where: { $0.name == url.lastPathComponent }) {
            showingUploadConflict = true
        } else {
            startPendingUpload(renameOnConflict: false)
        }
    }

    func startPendingUpload(renameOnConflict: Bool) {
        guard let url = pendingUploadURL else { return }
        let remoteName = renameOnConflict
            ? RemotePath.uniquedName(url.lastPathComponent, existing: Set(items.map(\.name)))
            : url.lastPathComponent
        guard transferTask == nil, !closed, client != nil else { return }
        transferGeneration = UUID()
        transferTask = Task { [self] in
            await upload(url, remoteName: remoteName)
            transferTask = nil
        }
    }

    func upload(_ url: URL, remoteName: String) async {
        guard let client, !closed else { return }
        let request = generation, transfer = transferGeneration
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        progress = SFTPProgress(
            transferredBytes: 0,
            totalBytes: 0,
            speedBytesPerSecond: 0,
            remaining: 0,
            message: "准备上传"
        )
        do {
            let destination = RemotePath.child(remoteName, of: path)
            try await client.upload(
                localURL: url,
                to: destination
            ) { value in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == request, self.transferGeneration == transfer, self.transferTask?.isCancelled == false else { return }
                    self.progress = value
                }
            }
            guard generation == request, !Task.isCancelled else { return }
            progress = nil
            pendingUploadURL = nil
            await open(path)
        } catch is CancellationError {
            guard generation == request else { return }
            progress = nil
        } catch {
            guard generation == request else { return }
            progress = nil
            errorMessage = error.localizedDescription
        }
    }

    func startDownload(_ item: RemoteFileItem) {
        guard exportDocument == nil else {
            errorMessage = "请先保存已下载的文件，再开始新的下载。"
            return
        }
        guard transferTask == nil, !closed, client != nil else { return }
        transferGeneration = UUID()
        transferTask = Task { [self] in
            await download(item)
            transferTask = nil
        }
    }

    func download(_ item: RemoteFileItem) async {
        guard let client, !closed else { return }
        let request = generation, transfer = transferGeneration
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerDash-download-\(UUID().uuidString)-\(item.name)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        progress = SFTPProgress(
            transferredBytes: 0,
            totalBytes: item.size,
            speedBytesPerSecond: 0,
            remaining: 0,
            message: "准备下载"
        )
        do {
            try await client.download(
                remotePath: item.path,
                size: item.size,
                to: temporary
            ) { value in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == request, self.transferGeneration == transfer, self.transferTask?.isCancelled == false else { return }
                    self.progress = value
                }
            }
            try Task.checkCancellation()
            guard generation == request else { return }
            let data = try Data(contentsOf: temporary, options: .mappedIfSafe)
            try? FileManager.default.removeItem(at: temporary)
            exportName = item.name
            exportDocument = MobileTransferDocument(data: data)
            progress = nil
            // Completion is retained until the visible tab explicitly exports it.
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: temporary)
            guard generation == request else { return }
            progress = nil
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            guard generation == request else { return }
            progress = nil
            errorMessage = error.localizedDescription
        }
    }

    func cancelTransfer(showMessage: Bool) {
        transferGeneration = UUID()
        transferTask?.cancel()
        progress = nil
        let client = self.client
        Task { await client?.cancelCurrentOperation() }
        if showMessage { errorMessage = SFTPError.cancelled.localizedDescription }
    }

    func closeConnection() async {
        let oldClient = client, oldSession = session
        client = nil
        session = nil
        if let oldClient { await oldClient.close() }
        if let oldSession { await oldSession.close() }
    }
}
