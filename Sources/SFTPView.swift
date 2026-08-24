import AppKit
import SwiftUI

struct SFTPBrowserView: View {
    @EnvironmentObject private var appState: AppState

    let server: ServerRecord

    @State private var items: [RemoteFileItem] = []
    @State private var currentPath = "."
    @State private var pathText = "."
    @State private var selection: Set<String> = []
    @State private var busyMessage: String?
    @State private var errorMessage: String?
    @State private var statusMessage = "尚未读取远程目录"
    @State private var showingNewFolderPrompt = false
    @State private var showingNewFilePrompt = false
    @State private var showingRenamePrompt = false
    @State private var showingMovePrompt = false
    @State private var showingConflict = false
    @State private var promptText = ""
    @State private var itemPendingDeletion: RemoteFileItem?
    @State private var progress: SFTPProgress?
    @State private var transferTask: Task<Void, Never>?
    @State private var pendingUploads: [URL] = []
    @State private var pendingDownload: (item: RemoteFileItem, url: URL)?
    @State private var conflictPolicy: SFTPConflictPolicy = .overwrite

    private var selectedItem: RemoteFileItem? {
        guard let id = selection.first else { return nil }
        return items.first { $0.id == id }
    }

    private var connectionConfig: ServerConnectionConfig {
        appState.connectionConfig(for: server)
    }

    var body: some View {
        VStack(spacing: 0) {
            browserToolbar
            Divider()

            if items.isEmpty, busyMessage == nil {
                ContentUnavailableView {
                    Label("此目录为空", systemImage: "folder")
                } description: {
                    Text("上传文件、文件夹或创建新项目以开始使用 SFTP。")
                } actions: {
                    Button("上传文件", systemImage: "square.and.arrow.up") {
                        chooseItemsToUpload(directories: false)
                    }
                    .buttonStyle(.borderedProminent)
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
        .task(id: server.id) {
            await loadDirectory(server.defaultSFTPPath.isEmpty ? "." : server.defaultSFTPPath)
        }
        .alert("新建文件夹", isPresented: $showingNewFolderPrompt) {
            TextField("文件夹名称", text: $promptText)
            Button("取消", role: .cancel) {}
            Button("创建") { createFolder(named: promptText) }
        } message: {
            Text("将在 \(currentPath) 中创建文件夹。")
        }
        .alert("新建文件", isPresented: $showingNewFilePrompt) {
            TextField("文件名称", text: $promptText)
            Button("取消", role: .cancel) {}
            Button("创建") { createFile(named: promptText) }
        }
        .alert("重命名", isPresented: $showingRenamePrompt) {
            TextField("新名称", text: $promptText)
            Button("取消", role: .cancel) {}
            Button("重命名") { renameSelectedItem(to: promptText) }
        } message: {
            Text(selectedItem?.name ?? "")
        }
        .alert("移动到", isPresented: $showingMovePrompt) {
            TextField("目标目录", text: $promptText)
            Button("取消", role: .cancel) {}
            Button("移动") { moveSelectedItem(to: promptText) }
        } message: {
            Text("将 \(selectedItem?.name ?? "项目") 移动到指定远程目录。")
        }
        .confirmationDialog(
            "删除 \(itemPendingDeletion?.name ?? "项目")？",
            isPresented: Binding(
                get: { itemPendingDeletion != nil },
                set: { if !$0 { itemPendingDeletion = nil } }
            )
        ) {
            Button("删除", role: .destructive) {
                guard let item = itemPendingDeletion else { return }
                delete(item)
            }
            Button("取消", role: .cancel) {
                itemPendingDeletion = nil
            }
        } message: {
            Text(deletionMessage)
        }
        .confirmationDialog(
            "目标已存在",
            isPresented: $showingConflict
        ) {
            Button("覆盖") { resolveConflict(.overwrite) }
            Button("跳过") { resolveConflict(.skip) }
            Button("重命名") { resolveConflict(.rename) }
            Button("取消", role: .cancel) {
                pendingUploads = []
                pendingDownload = nil
            }
        } message: {
            Text("同名文件或文件夹已存在。覆盖会替换目标，跳过会保留现有内容，重命名会自动加序号。")
        }
        .alert(
            "SFTP 操作失败",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("重新连接") {
                errorMessage = nil
                Task { await loadDirectory(currentPath) }
            }
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var deletionMessage: String {
        if itemPendingDeletion?.isDirectory == true {
            return "将删除文件夹及其全部内容，此操作无法撤销。"
        }
        return "远程文件将被永久删除，此操作无法撤销。"
    }

    private var browserToolbar: some View {
        HStack(spacing: AppleDesign.Spacing.xs) {
            Button {
                Task { await loadDirectory(".") }
            } label: {
                Image(systemName: "house")
            }
            .help("主目录")

            Button {
                Task { await loadDirectory(RemotePath.parent(of: currentPath)) }
            } label: {
                Image(systemName: "arrow.up")
            }
            .help("上级目录")
            .disabled(currentPath == "/" || busyMessage != nil)

            TextField("远程路径", text: $pathText)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .onSubmit {
                    Task { await loadDirectory(pathText) }
                }

            Button {
                Task { await loadDirectory(currentPath) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("刷新")

            Divider().frame(height: 20)

            Menu {
                Button("上传文件", systemImage: "doc.badge.plus") {
                    chooseItemsToUpload(directories: false)
                }
                Button("上传文件夹", systemImage: "folder.badge.plus") {
                    chooseItemsToUpload(directories: true)
                }
            } label: {
                Label("上传", systemImage: "square.and.arrow.up")
            }
            Button("下载", systemImage: "square.and.arrow.down") {
                downloadSelectedItem()
            }
            .disabled(selectedItem == nil)

            if busyMessage != nil {
                Button("取消", role: .destructive) {
                    transferTask?.cancel()
                }
            }

            Menu {
                Button("新建文件夹", systemImage: "folder.badge.plus") {
                    promptText = ""
                    showingNewFolderPrompt = true
                }
                Button("新建文件", systemImage: "doc.badge.plus") {
                    promptText = ""
                    showingNewFilePrompt = true
                }
                Button("重命名", systemImage: "pencil") {
                    beginRename()
                }
                .disabled(selectedItem == nil)
                Button("移动…", systemImage: "arrow.right") {
                    promptText = RemotePath.parent(of: selectedItem?.path ?? currentPath)
                    showingMovePrompt = true
                }
                .disabled(selectedItem == nil)
                Divider()
                Button("删除", systemImage: "trash", role: .destructive) {
                    itemPendingDeletion = selectedItem
                }
                .disabled(selectedItem == nil)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .help("更多操作")
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(busyMessage != nil && transferTask == nil)
        .padding(.horizontal, AppleDesign.Spacing.md)
        .padding(.vertical, AppleDesign.Spacing.sm)
        .background(AppleChromeBackground())
    }

    private var fileTable: some View {
        Table(items, selection: $selection) {
            TableColumn("名称") { item in
                Label(item.name, systemImage: icon(for: item))
                    .symbolRenderingMode(.monochrome)
                    .lineLimit(1)
            }
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
            let item = items.first { selectedIDs.contains($0.id) }
            if let item {
                if item.isDirectory {
                    Button("打开", systemImage: "folder") {
                        Task { await loadDirectory(item.path) }
                    }
                }
                Button("下载", systemImage: "square.and.arrow.down") {
                    selection = [item.id]
                    downloadSelectedItem()
                }
                Button("重命名", systemImage: "pencil") {
                    selection = [item.id]
                    beginRename()
                }
                Divider()
                Button("删除", systemImage: "trash", role: .destructive) {
                    selection = [item.id]
                    itemPendingDeletion = item
                }
            }
        } primaryAction: { selectedIDs in
            guard let item = items.first(where: { selectedIDs.contains($0.id) }) else { return }
            if item.isDirectory {
                Task { await loadDirectory(item.path) }
            } else {
                selection = [item.id]
                downloadSelectedItem()
            }
        }
        .overlay {
            if let busyMessage {
                ZStack {
                    Color.appGround.opacity(0.72)
                    VStack(spacing: AppleDesign.Spacing.sm) {
                        if let progress {
                            ProgressView(value: progress.fraction)
                        } else {
                            ProgressView()
                        }
                        Text(busyMessage)
                            .font(.callout)
                        if let progress {
                            Text(
                                "\(DisplayFormat.speed(progress.speedBytesPerSecond)) · 剩余 \(Int(progress.remaining)) 秒"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Button("取消") {
                            transferTask?.cancel()
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
            if busyMessage != nil {
                ProgressView().controlSize(.small)
            }
            Text(busyMessage ?? statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Text("\(items.count) 个项目")
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

    @MainActor
    private func loadDirectory(_ path: String) async {
        guard busyMessage == nil else { return }
        busyMessage = "正在读取 \(path)"
        errorMessage = nil
        do {
            let listing = try await SFTPService.list(config: connectionConfig, path: path)
            currentPath = listing.path
            pathText = listing.path
            items = listing.items
            selection.removeAll()
            statusMessage = "已连接 \(server.username)@\(server.host)"
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "无法读取远程目录"
            EventLogStore.shared.append(
                serverID: server.id,
                module: .sftp,
                level: "error",
                message: error.localizedDescription
            )
        }
        busyMessage = nil
        progress = nil
    }

    private func chooseItemsToUpload(directories: Bool) {
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

    private func upload(_ urls: [URL], policy: SFTPConflictPolicy) {
        busyMessage = urls.count == 1 ? "正在上传 \(urls[0].lastPathComponent)" : "正在上传 \(urls.count) 个项目"
        transferTask = Task {
            do {
                try await SFTPService.upload(
                    localURLs: urls,
                    to: currentPath,
                    config: connectionConfig,
                    policy: policy,
                    existingNames: Set(items.map(\.name))
                ) { update in
                    Task { @MainActor in
                        progress = update
                        busyMessage = update.message
                    }
                }
                busyMessage = nil
                progress = nil
                statusMessage = "上传完成"
                await loadDirectory(currentPath)
            } catch {
                busyMessage = nil
                progress = nil
                errorMessage = error.localizedDescription
            }
            transferTask = nil
        }
    }

    private func downloadSelectedItem() {
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

    private func enqueueDownload(_ item: RemoteFileItem, to destination: URL) {
        if FileManager.default.fileExists(atPath: destination.path) {
            pendingDownload = (item, destination)
            showingConflict = true
        } else {
            download(item, to: destination, policy: .overwrite)
        }
    }

    private func download(_ item: RemoteFileItem, to destination: URL, policy: SFTPConflictPolicy) {
        busyMessage = "正在下载 \(item.name)"
        transferTask = Task {
            do {
                try await SFTPService.download(
                    item: item,
                    to: destination,
                    config: connectionConfig,
                    policy: policy
                ) { update in
                    Task { @MainActor in
                        progress = update
                        busyMessage = update.message
                    }
                }
                statusMessage = "已下载到 \(destination.path)"
            } catch {
                errorMessage = error.localizedDescription
            }
            busyMessage = nil
            progress = nil
            transferTask = nil
        }
    }

    private func resolveConflict(_ policy: SFTPConflictPolicy) {
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

    private func createFolder(named name: String) {
        runMutation("正在创建文件夹") {
            try await SFTPService.createDirectory(
                named: name,
                in: currentPath,
                config: connectionConfig
            )
        } success: {
            "文件夹已创建"
        }
    }

    private func createFile(named name: String) {
        runMutation("正在创建文件") {
            try await SFTPService.createFile(
                named: name,
                in: currentPath,
                config: connectionConfig
            )
        } success: {
            "文件已创建"
        }
    }

    private func beginRename() {
        guard let item = selectedItem else { return }
        promptText = item.name
        showingRenamePrompt = true
    }

    private func renameSelectedItem(to name: String) {
        guard let item = selectedItem else { return }
        runMutation("正在重命名 \(item.name)") {
            try await SFTPService.rename(item: item, to: name, config: connectionConfig)
        } success: {
            "重命名完成"
        }
    }

    private func moveSelectedItem(to directory: String) {
        guard let item = selectedItem else { return }
        runMutation("正在移动 \(item.name)") {
            try await SFTPService.move(item: item, to: directory, config: connectionConfig)
        } success: {
            "移动完成"
        }
    }

    private func delete(_ item: RemoteFileItem) {
        itemPendingDeletion = nil
        runMutation("正在删除 \(item.name)") {
            try await SFTPService.delete(
                item: item,
                config: connectionConfig,
                recursive: item.isDirectory
            )
        } success: {
            "已删除 \(item.name)"
        }
    }

    private func runMutation(_ message: String, work: @escaping () async throws -> Void, success: @escaping () -> String) {
        busyMessage = message
        transferTask = Task {
            do {
                try await work()
                busyMessage = nil
                statusMessage = success()
                await loadDirectory(currentPath)
            } catch {
                busyMessage = nil
                errorMessage = error.localizedDescription
            }
            transferTask = nil
        }
    }
}
