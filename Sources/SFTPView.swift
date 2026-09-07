import AppKit
import SwiftUI

struct SFTPBrowserView: View {
    @ObservedObject var controller: MacSFTPController
    var body: some View {
        VStack(spacing: 0) {
            browserToolbar
            Divider()

            if controller.items.isEmpty, controller.busyMessage == nil {
                ContentUnavailableView {
                    Label(
                        controller.hasLoadedDirectory ? "此目录为空" : "尚未读取远程目录",
                        systemImage: controller.hasLoadedDirectory ? "folder" : "folder.badge.questionmark"
                    )
                } description: {
                    Text(controller.hasLoadedDirectory
                         ? "上传文件、文件夹或创建新项目以开始使用 SFTP。"
                         : "检查服务器连接后重试，即可浏览和传输文件。")
                } actions: {
                    if controller.hasLoadedDirectory {
                        Button("上传文件", systemImage: "square.and.arrow.up") {
                            controller.chooseItemsToUpload(directories: false)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button("重新连接", systemImage: "arrow.clockwise") {
                            Task { await controller.loadDirectory(controller.currentPath) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                fileTable
            }

            Divider()
            statusBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appGround)
        .onAppear { controller.beginIfNeeded() }
        .alert("新建文件夹", isPresented: $controller.showingNewFolderPrompt) {
            TextField("文件夹名称", text: $controller.promptText)
            Button("取消", role: .cancel) {}
            Button("创建") { controller.createFolder(named: controller.promptText) }
        } message: {
            Text("将在 \(controller.currentPath) 中创建文件夹。")
        }
        .alert("新建文件", isPresented: $controller.showingNewFilePrompt) {
            TextField("文件名称", text: $controller.promptText)
            Button("取消", role: .cancel) {}
            Button("创建") { controller.createFile(named: controller.promptText) }
        }
        .alert("重命名", isPresented: $controller.showingRenamePrompt) {
            TextField("新名称", text: $controller.promptText)
            Button("取消", role: .cancel) {}
            Button("重命名") { controller.renameSelectedItem(to: controller.promptText) }
        } message: {
            Text(controller.selectedItem?.name ?? "")
        }
        .alert("移动到", isPresented: $controller.showingMovePrompt) {
            TextField("目标目录", text: $controller.promptText)
            Button("取消", role: .cancel) {}
            Button("移动") { controller.moveSelectedItem(to: controller.promptText) }
        } message: {
            Text("将 \(controller.selectedItem?.name ?? "项目") 移动到指定远程目录。")
        }
        .confirmationDialog(
            "删除 \(controller.itemPendingDeletion?.name ?? "项目")？",
            isPresented: Binding(
                get: { controller.itemPendingDeletion != nil },
                set: { if !$0 { controller.itemPendingDeletion = nil } }
            )
        ) {
            Button("删除", role: .destructive) {
                guard let item = controller.itemPendingDeletion else { return }
                controller.delete(item)
            }
            Button("取消", role: .cancel) {
                controller.itemPendingDeletion = nil
            }
        } message: {
            Text(deletionMessage)
        }
        .confirmationDialog(
            "目标已存在",
            isPresented: $controller.showingConflict
        ) {
            Button("覆盖") { controller.resolveConflict(.overwrite) }
            Button("跳过") { controller.resolveConflict(.skip) }
            Button("重命名") { controller.resolveConflict(.rename) }
            Button("取消", role: .cancel) {
                controller.pendingUploads = []
                controller.pendingDownload = nil
            }
        } message: {
            Text("同名文件或文件夹已存在。覆盖会替换目标，跳过会保留现有内容，重命名会自动加序号。")
        }
        .alert(
            "SFTP 操作失败",
            isPresented: Binding(
                get: { controller.errorMessage != nil },
                set: { if !$0 { controller.errorMessage = nil } }
            )
        ) {
            Button("重新连接") {
                controller.errorMessage = nil
                Task { await controller.loadDirectory(controller.currentPath) }
            }
            Button("好") { controller.errorMessage = nil }
        } message: {
            Text(controller.errorMessage ?? "")
        }
    }

    private var deletionMessage: String {
        if controller.itemPendingDeletion?.isDirectory == true {
            return "将删除文件夹及其全部内容，此操作无法撤销。"
        }
        return "远程文件将被永久删除，此操作无法撤销。"
    }

    private var browserToolbar: some View {
        VStack(spacing: AppleDesign.Spacing.sm) {
            HStack(spacing: AppleDesign.Spacing.xs) {
                Button {
                    Task { await controller.loadDirectory(".") }
                } label: {
                    Image(systemName: "house")
                }
                .help("主目录")
                .accessibilityLabel("前往主目录")

                Button {
                    Task { await controller.loadDirectory(RemotePath.parent(of: controller.currentPath)) }
                } label: {
                    Image(systemName: "arrow.up")
                }
                .help("上级目录")
                .accessibilityLabel("前往上级目录")
                .disabled(controller.currentPath == "/" || controller.busyMessage != nil)

                TextField("远程路径", text: $controller.pathText)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .onSubmit {
                        Task { await controller.loadDirectory(controller.pathText) }
                    }

                Button {
                    Task { await controller.loadDirectory(controller.currentPath) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("刷新")
                .accessibilityLabel("刷新远程目录")
            }

            HStack(spacing: AppleDesign.Spacing.xs) {
                Menu {
                    Button("上传文件", systemImage: "doc.badge.plus") {
                        controller.chooseItemsToUpload(directories: false)
                    }
                    Button("上传文件夹", systemImage: "folder.badge.plus") {
                        controller.chooseItemsToUpload(directories: true)
                    }
                } label: {
                    Label("上传", systemImage: "square.and.arrow.up")
                }
                Button("下载", systemImage: "square.and.arrow.down") {
                    controller.downloadSelectedItem()
                }
                .disabled(controller.selectedItem == nil)

                Spacer(minLength: AppleDesign.Spacing.xs)
                Text(controller.selectedItem.map { "已选择 \($0.name)" } ?? "远程文件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if controller.busyMessage != nil {
                    Button("取消", role: .destructive) {
                        controller.transferTask?.cancel()
                    }
                }

                Menu {
                    Button("新建文件夹", systemImage: "folder.badge.plus") {
                        controller.promptText = ""
                        controller.showingNewFolderPrompt = true
                    }
                    Button("新建文件", systemImage: "doc.badge.plus") {
                        controller.promptText = ""
                        controller.showingNewFilePrompt = true
                    }
                    Button("重命名", systemImage: "pencil") {
                        controller.beginRename()
                    }
                    .disabled(controller.selectedItem == nil)
                    Button("移动…", systemImage: "arrow.right") {
                        controller.promptText = RemotePath.parent(of: controller.selectedItem?.path ?? controller.currentPath)
                        controller.showingMovePrompt = true
                    }
                    .disabled(controller.selectedItem == nil)
                    Divider()
                    Button("删除", systemImage: "trash", role: .destructive) {
                        controller.itemPendingDeletion = controller.selectedItem
                    }
                    .disabled(controller.selectedItem == nil)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .help("更多操作")
                .accessibilityLabel("文件操作")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(controller.busyMessage != nil && controller.transferTask == nil)
        .padding(.horizontal, AppleDesign.Spacing.md)
        .padding(.vertical, AppleDesign.Spacing.sm)
        .background(Color.appGround)
    }

    private var fileTable: some View {
        Table(controller.items, selection: $controller.selection) {
            TableColumn("名称") { item in
                Label(item.name, systemImage: icon(for: item))
                    .symbolRenderingMode(.monochrome)
                    .lineLimit(1)
            }
            .width(min: 140, ideal: 260)
            TableColumn("大小") { item in
                Text(item.isDirectory ? "—" : DisplayFormat.bytes(Double(item.size)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 75, ideal: 95, max: 120)
            TableColumn("修改时间") { item in
                Text(item.modifiedText)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 135, max: 170)
            TableColumn("权限") { item in
                Text(item.permissions)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .width(105)
            TableColumn("所有者") { item in
                Text(item.owner)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 100, max: 140)
        }
        .contextMenu(forSelectionType: String.self) { selectedIDs in
            let item = controller.items.first { selectedIDs.contains($0.id) }
            if let item {
                if item.isDirectory {
                    Button("打开", systemImage: "folder") {
                        Task { await controller.loadDirectory(item.path) }
                    }
                }
                Button("下载", systemImage: "square.and.arrow.down") {
                    controller.selection = [item.id]
                    controller.downloadSelectedItem()
                }
                Button("重命名", systemImage: "pencil") {
                    controller.selection = [item.id]
                    controller.beginRename()
                }
                Divider()
                Button("删除", systemImage: "trash", role: .destructive) {
                    controller.selection = [item.id]
                    controller.itemPendingDeletion = item
                }
            }
        } primaryAction: { selectedIDs in
            guard let item = controller.items.first(where: { selectedIDs.contains($0.id) }) else { return }
            if item.isDirectory {
                Task { await controller.loadDirectory(item.path) }
            } else {
                controller.selection = [item.id]
                controller.downloadSelectedItem()
            }
        }
        .overlay {
            if let busyMessage = controller.busyMessage {
                ZStack {
                    Color.appGround.opacity(0.72)
                    VStack(spacing: AppleDesign.Spacing.sm) {
                        if let progress = controller.progress {
                            ProgressView(value: progress.fraction)
                        } else {
                            ProgressView()
                        }
                        Text(busyMessage)
                            .font(.callout)
                        if let progress = controller.progress {
                            Text(
                                "\(DisplayFormat.speed(progress.speedBytesPerSecond)) · 剩余 \(DisplayFormat.integer(Int(progress.remaining))) 秒"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Button("取消") {
                            controller.transferTask?.cancel()
                        }
                    }
                    .padding(AppleDesign.Spacing.lg)
                    .background(AppleChromeBackground())
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: AppleDesign.Radius.thumbnail,
                            style: .continuous
                        )
                    )
                }
            }
        }
    }

    private var statusBar: some View {
        HStack {
            if controller.busyMessage != nil {
                ProgressView().controlSize(.small)
            }
            Text(controller.busyMessage ?? controller.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Text("\(DisplayFormat.integer(controller.items.count)) 个项目")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, AppleDesign.Spacing.md)
        .frame(height: 32)
        .background(AppleChromeBackground())
    }

    private func icon(for item: RemoteFileItem) -> String {
        switch item.kind {
        case .directory: "folder"
        case .symbolicLink: "arrow.triangle.turn.up.right.diamond"
        case .file: "doc"
        case .other: "questionmark.square.dashed"
        }
    }

}

@MainActor
final class MacSFTPController: ObservableObject {
    let server: ServerRecord
    private weak var appState: AppState?
    private var started = false
    private var closed = false
    private var generation = UUID()
    private var directoryTask: Task<Void, Never>?
    private var directoryGeneration = UUID()
    private var transferGeneration = UUID()
    var hasActiveTransfer: Bool { transferTask != nil }
    @Published var items: [RemoteFileItem] = []
    @Published var hasLoadedDirectory = false
    @Published var currentPath = "."
    @Published var pathText = "."
    @Published var selection: Set<String> = []
    @Published var busyMessage: String?
    @Published var errorMessage: String?
    @Published var statusMessage = "尚未读取远程目录"
    @Published var showingNewFolderPrompt = false
    @Published var showingNewFilePrompt = false
    @Published var showingRenamePrompt = false
    @Published var showingMovePrompt = false
    @Published var showingConflict = false
    @Published var promptText = ""
    @Published var itemPendingDeletion: RemoteFileItem?
    @Published var progress: SFTPProgress?
    @Published var transferTask: Task<Void, Never>?
    @Published var pendingUploads: [URL] = []
    @Published var pendingDownload: (item: RemoteFileItem, url: URL)?
    @Published var conflictPolicy: SFTPConflictPolicy = .overwrite

    var selectedItem: RemoteFileItem? {
        guard let id = selection.first else { return nil }
        return items.first { $0.id == id }
    }

    private var connectionConfig: ServerConnectionConfig { appState?.connectionConfig(for: server) ?? server.connectionConfig }


    init(server: ServerRecord, appState: AppState) {
        self.server = server; self.appState = appState
        currentPath = server.defaultSFTPPath.isEmpty ? "." : server.defaultSFTPPath
        pathText = currentPath
    }
    func beginIfNeeded() {
        guard !started, !closed else { return }
        started = true
        Task { [self] in await loadDirectory(currentPath) }
    }
    func close() {
        closed = true
        generation = UUID()
        directoryTask?.cancel()
        transferTask?.cancel()
        pendingUploads = []
        pendingDownload = nil
        progress = nil
    }
    func loadDirectory(_ path: String) async {
        guard !closed, transferTask == nil || busyMessage == nil else { return }
        directoryTask?.cancel()
        let request = UUID()
        directoryGeneration = request
        let task = Task { [self] in await readDirectory(path, request: request) }
        directoryTask = task
        await task.value
        if directoryGeneration == request { directoryTask = nil }
    }

    private func readDirectory(_ path: String, request: UUID) async {
        guard !closed, !Task.isCancelled, directoryGeneration == request else { return }
        let connection = generation
        defer { if generation == connection, directoryGeneration == request { busyMessage = nil } }
        busyMessage = "正在读取 \(path)"
        errorMessage = nil
        do {
            guard let appState else { throw CancellationError() }
            let config = connectionConfig
            let listing = try await appState.performTrustedConnection(
                config,
                source: .sftp
            ) {
                try await SFTPService.list(config: config, path: path)
            }
            guard generation == connection, directoryGeneration == request, !Task.isCancelled else { return }
            currentPath = listing.path
            pathText = listing.path
            items = listing.items
            hasLoadedDirectory = true
            selection.removeAll()
            statusMessage = "已连接 \(server.username)@\(server.host)"
        } catch {
            guard generation == connection, directoryGeneration == request else { return }
            errorMessage = error.localizedDescription
            statusMessage = "无法读取远程目录"
            EventLogStore.shared.append(
                serverID: server.id,
                module: .sftp,
                level: "error",
                message: "SFTP 目录读取失败"
            )
        }
        busyMessage = nil
        progress = nil
    }

    func chooseItemsToUpload(directories: Bool) {
        let panel = NSOpenPanel()
        panel.title = directories ? "选择要上传的文件夹" : "选择要上传的文件"
        panel.prompt = "上传"
        panel.canChooseFiles = !directories
        panel.canChooseDirectories = directories
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let existing = Set(items.map(\.name))
        if panel.urls.contains(where: { existing.contains($0.lastPathComponent) }) {
            pendingUploads = panel.urls
            showingConflict = true
        } else {
            upload(panel.urls, policy: .overwrite)
        }
    }

    func upload(_ urls: [URL], policy: SFTPConflictPolicy) {
        guard !closed, transferTask == nil else { return }
        let request = generation, transfer = UUID()
        transferGeneration = transfer
        busyMessage = urls.count == 1
            ? "正在上传 \(urls[0].lastPathComponent)"
            : "正在上传 \(DisplayFormat.integer(urls.count)) 个项目"
        transferTask = Task { [self] in
            defer { if generation == request { transferTask = nil; busyMessage = nil; progress = nil } }
            do {
                guard let appState else { throw CancellationError() }
                let config = connectionConfig
                try await appState.performTrustedConnection(config, source: .sftp) {
                    try await SFTPService.upload(
                        localURLs: urls,
                        to: currentPath,
                        config: config,
                        policy: policy,
                        existingNames: Set(items.map(\.name))
                    ) { [self] update in
                        Task { @MainActor [self] in
                            guard self.generation == request, self.transferGeneration == transfer, self.transferTask?.isCancelled == false else { return }
                            self.progress = update
                            self.busyMessage = update.message
                        }
                    }
                }
                guard generation == request, !Task.isCancelled else { return }
                busyMessage = nil
                progress = nil
                statusMessage = "上传完成"
                await loadDirectory(currentPath)
            } catch {
                guard generation == request else { return }
                busyMessage = nil
                progress = nil
                errorMessage = error.localizedDescription
            }
            transferTask = nil
        }
    }

    func downloadSelectedItem() {
        guard let item = selectedItem else { return }
        if item.isDirectory {
            let panel = NSOpenPanel()
            panel.title = "选择下载文件夹的位置"
            panel.prompt = "下载"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            let destination = folder.appendingPathComponent(item.name)
            enqueueDownload(item, to: destination)
        } else {
            let panel = NSSavePanel()
            panel.title = "下载 \(item.name)"
            panel.nameFieldStringValue = item.name
            panel.prompt = "下载"
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            enqueueDownload(item, to: destination)
        }
    }

    func enqueueDownload(_ item: RemoteFileItem, to destination: URL) {
        if FileManager.default.fileExists(atPath: destination.path) {
            pendingDownload = (item, destination)
            showingConflict = true
        } else {
            download(item, to: destination, policy: .overwrite)
        }
    }

    func download(_ item: RemoteFileItem, to destination: URL, policy: SFTPConflictPolicy) {
        guard !closed, transferTask == nil else { return }
        let request = generation, transfer = UUID()
        transferGeneration = transfer
        busyMessage = "正在下载 \(item.name)"
        transferTask = Task { [self] in
            defer { if generation == request { transferTask = nil; busyMessage = nil; progress = nil } }
            do {
                guard let appState else { throw CancellationError() }
                let config = connectionConfig
                try await appState.performTrustedConnection(config, source: .sftp) {
                    try await SFTPService.download(
                        item: item,
                        to: destination,
                        config: config,
                        policy: policy
                    ) { [self] update in
                        Task { @MainActor [self] in
                            guard self.generation == request, self.transferGeneration == transfer, self.transferTask?.isCancelled == false else { return }
                            self.progress = update
                            self.busyMessage = update.message
                        }
                    }
                }
                guard generation == request, !Task.isCancelled else { return }
                statusMessage = "已下载到 \(destination.path)"
            } catch {
                guard generation == request else { return }
                errorMessage = error.localizedDescription
            }
            busyMessage = nil
            progress = nil
            transferTask = nil
        }
    }

    func resolveConflict(_ policy: SFTPConflictPolicy) {
        conflictPolicy = policy
        if !pendingUploads.isEmpty {
            let urls = pendingUploads
            pendingUploads = []
            upload(urls, policy: policy)
        } else if let pendingDownload {
            download(pendingDownload.item, to: pendingDownload.url, policy: policy)
            self.pendingDownload = nil
        }
    }

    func createFolder(named name: String) {
        runMutation("正在创建文件夹") { [self] in
            try await SFTPService.createDirectory(
                named: name,
                in: currentPath,
                config: connectionConfig
            )
        } success: {
            "文件夹已创建"
        }
    }

    func createFile(named name: String) {
        runMutation("正在创建文件") { [self] in
            try await SFTPService.createFile(
                named: name,
                in: currentPath,
                config: connectionConfig
            )
        } success: {
            "文件已创建"
        }
    }

    func beginRename() {
        guard let item = selectedItem else { return }
        promptText = item.name
        showingRenamePrompt = true
    }

    func renameSelectedItem(to name: String) {
        guard let item = selectedItem else { return }
        runMutation("正在重命名 \(item.name)") { [self] in
            try await SFTPService.rename(item: item, to: name, config: connectionConfig)
        } success: {
            "重命名完成"
        }
    }

    func moveSelectedItem(to directory: String) {
        guard let item = selectedItem else { return }
        runMutation("正在移动 \(item.name)") { [self] in
            try await SFTPService.move(item: item, to: directory, config: connectionConfig)
        } success: {
            "移动完成"
        }
    }

    func delete(_ item: RemoteFileItem) {
        itemPendingDeletion = nil
        runMutation("正在删除 \(item.name)") { [self] in
            try await SFTPService.delete(
                item: item,
                config: connectionConfig,
                recursive: item.isDirectory
            )
        } success: {
            "已删除 \(item.name)"
        }
    }

    func runMutation(_ message: String, work: @escaping () async throws -> Void, success: @escaping () -> String) {
        guard !closed, transferTask == nil else { return }
        let request = generation, transfer = UUID()
        transferGeneration = transfer
        busyMessage = message
        transferTask = Task { [self] in
            defer { if generation == request { transferTask = nil; busyMessage = nil; progress = nil } }
            do {
                guard let appState else { throw CancellationError() }
                let config = connectionConfig
                try await appState.performTrustedConnection(config, source: .sftp) {
                    try await work()
                }
                guard generation == request, !Task.isCancelled else { return }
                busyMessage = nil
                statusMessage = success()
                await loadDirectory(currentPath)
            } catch {
                guard generation == request, !Task.isCancelled else { return }
                busyMessage = nil
                errorMessage = error.localizedDescription
            }
            transferTask = nil
        }
    }
}
