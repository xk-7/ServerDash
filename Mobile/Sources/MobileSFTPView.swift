import SwiftUI
import UniformTypeIdentifiers

struct MobileSFTPView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var runtime: MobileRuntime

    let config: ServerConnectionConfig

    @State private var session: (any RemoteSession)?
    @State private var client: (any RemoteFileClient)?
    @State private var path = "."
    @State private var items: [RemoteFileItem] = []
    @State private var loading = true
    @State private var interrupted = false
    @State private var errorMessage: String?
    @State private var showingImporter = false
    @State private var pendingUploadURL: URL?
    @State private var progress: SFTPProgress?
    @State private var showingNewDirectory = false
    @State private var showingNewFile = false
    @State private var showingRename = false
    @State private var showingMove = false
    @State private var showingUploadConflict = false
    @State private var newName = ""
    @State private var pendingDelete: RemoteFileItem?
    @State private var pendingRename: RemoteFileItem?
    @State private var pendingMove: RemoteFileItem?
    @State private var moveDirectory = ""
    @State private var exportDocument: MobileTransferDocument?
    @State private var exportName = "download"
    @State private var showingExporter = false
    @State private var transferTask: Task<Void, Never>?

    var body: some View {
        transferLayer
    }

    private var content: some View {
        Group {
            if interrupted {
                ContentUnavailableView {
                    Label("SFTP 已暂停", systemImage: "pause.circle")
                } description: {
                    Text("应用进入后台时连接已安全关闭。")
                } actions: {
                    Button("重新连接") { Task { await connectAndLoad() } }
                        .buttonStyle(.borderedProminent)
                }
            } else if loading && items.isEmpty {
                ProgressView("正在连接 SFTP…")
            } else if horizontalSizeClass == .regular {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 190), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(items) { item in itemCard(item) }
                    }
                    .padding()
                }
                .background(Color.appGround)
            } else {
                List(items) { item in itemRow(item) }
                    .overlay {
                        if items.isEmpty && !loading {
                            ContentUnavailableView("文件夹为空", systemImage: "folder")
                        }
                    }
            }
        }
    }

    private var navigationLayer: some View {
        content
        .navigationTitle(URL(fileURLWithPath: path).lastPathComponent.isEmpty ? "/" : URL(fileURLWithPath: path).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 10) {
                Button { Task { await open(RemotePath.parent(of: path)) } } label: {
                    Image(systemName: "chevron.up")
                        .frame(width: 44, height: 44)
                }
                .disabled(path == "/" || loading)
                Text(path)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if loading { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal)
            .background(.bar)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { Task { await open(path) } } label: { Image(systemName: "arrow.clockwise") }
                Menu {
                    Button("上传文件", systemImage: "square.and.arrow.up") { showingImporter = true }
                    Button("新建文件夹", systemImage: "folder.badge.plus") {
                        newName = ""
                        showingNewDirectory = true
                    }
                    Button("新建文件", systemImage: "doc.badge.plus") {
                        newName = ""
                        showingNewFile = true
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
    }

    private var lifecycleLayer: some View {
        navigationLayer
        .task { await connectAndLoad() }
        .onDisappear {
            cancelTransfer(showMessage: false)
            Task { await closeConnection() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                Task {
                    cancelTransfer(showMessage: false)
                    await closeConnection()
                    interrupted = true
                    progress = nil
                }
            }
        }
    }

    private var documentLayer: some View {
        lifecycleLayer
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                pendingUploadURL = url
                prepareUpload(url)
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument,
            contentType: .data,
            defaultFilename: exportName
        ) { result in
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
            exportDocument = nil
        }
    }

    private var creationLayer: some View {
        documentLayer
        .alert("新建文件夹", isPresented: $showingNewDirectory) {
            TextField("名称", text: $newName)
            Button("取消", role: .cancel) {}
            Button("创建") { Task { await create(directory: true) } }
        }
        .alert("新建文件", isPresented: $showingNewFile) {
            TextField("名称", text: $newName)
            Button("取消", role: .cancel) {}
            Button("创建") { Task { await create(directory: false) } }
        }
    }

    private var renameMoveLayer: some View {
        creationLayer
        .alert("重命名", isPresented: $showingRename) {
            TextField("新名称", text: $newName)
            Button("取消", role: .cancel) { pendingRename = nil }
            Button("保存") {
                if let item = pendingRename { Task { await rename(item, to: newName) } }
                pendingRename = nil
            }
        }
        .alert("移动到目录", isPresented: $showingMove) {
            TextField("远程目录", text: $moveDirectory)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("取消", role: .cancel) { pendingMove = nil }
            Button("移动") {
                if let item = pendingMove { Task { await move(item, to: moveDirectory) } }
                pendingMove = nil
            }
        } message: {
            Text("可输入绝对路径，或相对于当前目录的路径。")
        }
    }

    private var confirmationLayer: some View {
        renameMoveLayer
        .confirmationDialog(
            "远程目录已有同名项目",
            isPresented: $showingUploadConflict,
            titleVisibility: .visible
        ) {
            Button("覆盖") { startPendingUpload(renameOnConflict: false) }
            Button("自动重命名") { startPendingUpload(renameOnConflict: true) }
            Button("跳过", role: .cancel) { pendingUploadURL = nil }
        } message: {
            Text("选择上传时的冲突处理方式。")
        }
        .confirmationDialog(
            "删除 \(pendingDelete?.name ?? "")？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let item = pendingDelete { Task { await delete(item) } }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete?.isDirectory == true ? "文件夹及其内容将被递归删除。" : "此操作无法撤销。")
        }
    }

    private var transferLayer: some View {
        confirmationLayer
        .alert("SFTP 操作失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "未知错误")
        }
        .overlay(alignment: .bottom) {
            if let progress {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(progress.message).font(.caption)
                        Spacer()
                        Text(DisplayFormat.speed(progress.speedBytesPerSecond))
                            .font(.caption.monospacedDigit())
                    }
                    ProgressView(value: progress.fraction)
                    Button("取消传输", role: .destructive) {
                        cancelTransfer(showMessage: true)
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
        Button { Task { await activate(item) } } label: {
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
        Button { Task { await activate(item) } } label: {
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
                startDownload(item)
            }
        }
        Button("重命名", systemImage: "pencil") {
            pendingRename = item
            newName = item.name
            showingRename = true
        }
        Button("移动", systemImage: "folder") {
            pendingMove = item
            moveDirectory = path
            showingMove = true
        }
        Button("删除", systemImage: "trash", role: .destructive) { pendingDelete = item }
    }

    private func connectAndLoad() async {
        loading = true
        interrupted = false
        await closeConnection()
        do {
            let engine = runtime.engine
            let broker = runtime.trustBroker
            let newSession = try await engine.connect(config) { presentation in
                try await broker.evaluate(presentation)
            }
            let newClient = try await newSession.openSFTP()
            session = newSession
            client = newClient
            await open(path)
        } catch {
            loading = false
            errorMessage = error.localizedDescription
        }
    }

    private func open(_ requestedPath: String) async {
        guard let client else { return }
        loading = true
        defer { loading = false }
        do {
            let listing = try await client.list(path: requestedPath)
            path = listing.path
            items = listing.items
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func activate(_ item: RemoteFileItem) async {
        if item.isDirectory {
            await open(item.path)
        } else {
            startDownload(item)
        }
    }

    private func create(directory: Bool) async {
        guard let client else { return }
        do {
            if directory {
                try await client.createDirectory(named: newName, in: path)
            } else {
                try await client.createFile(named: newName, in: path)
            }
            await open(path)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ item: RemoteFileItem) async {
        guard let client else { return }
        do {
            try await client.delete(item, recursive: item.isDirectory)
            await open(path)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func rename(_ item: RemoteFileItem, to name: String) async {
        guard let client else { return }
        do {
            try await client.rename(item, to: name)
            await open(path)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func move(_ item: RemoteFileItem, to destination: String) async {
        guard let client else { return }
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
            await open(path)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func prepareUpload(_ url: URL) {
        if items.contains(where: { $0.name == url.lastPathComponent }) {
            showingUploadConflict = true
        } else {
            startPendingUpload(renameOnConflict: false)
        }
    }

    private func startPendingUpload(renameOnConflict: Bool) {
        guard let url = pendingUploadURL else { return }
        let remoteName = renameOnConflict
            ? RemotePath.uniquedName(url.lastPathComponent, existing: Set(items.map(\.name)))
            : url.lastPathComponent
        transferTask?.cancel()
        transferTask = Task {
            await upload(url, remoteName: remoteName)
            transferTask = nil
        }
    }

    private func upload(_ url: URL, remoteName: String) async {
        guard let client else { return }
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
            try await client.upload(
                localURL: url,
                to: RemotePath.child(remoteName, of: path)
            ) { value in
                Task { @MainActor in self.progress = value }
            }
            progress = nil
            pendingUploadURL = nil
            await open(path)
        } catch is CancellationError {
            progress = nil
        } catch {
            progress = nil
            errorMessage = error.localizedDescription
        }
    }

    private func startDownload(_ item: RemoteFileItem) {
        transferTask?.cancel()
        transferTask = Task {
            await download(item)
            transferTask = nil
        }
    }

    private func download(_ item: RemoteFileItem) async {
        guard let client else { return }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerDash-download-\(UUID().uuidString)-\(item.name)")
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
                Task { @MainActor in self.progress = value }
            }
            let data = try Data(contentsOf: temporary, options: .mappedIfSafe)
            try? FileManager.default.removeItem(at: temporary)
            exportName = item.name
            exportDocument = MobileTransferDocument(data: data)
            progress = nil
            showingExporter = true
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: temporary)
            progress = nil
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            progress = nil
            errorMessage = error.localizedDescription
        }
    }

    private func cancelTransfer(showMessage: Bool) {
        transferTask?.cancel()
        transferTask = nil
        progress = nil
        let client = self.client
        Task { await client?.cancelCurrentOperation() }
        if showMessage { errorMessage = SFTPError.cancelled.localizedDescription }
    }

    private func closeConnection() async {
        if let client { await client.close() }
        if let session { await session.close() }
        client = nil
        session = nil
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
