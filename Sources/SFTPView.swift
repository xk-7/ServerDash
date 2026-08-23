import AppKit
import SwiftUI

struct SFTPBrowserView: View {
    let server: ServerRecord

    @State private var items: [RemoteFileItem] = []
    @State private var currentPath = "."
    @State private var pathText = "."
    @State private var selection: Set<String> = []
    @State private var busyMessage: String?
    @State private var errorMessage: String?
    @State private var statusMessage = "尚未读取远程目录"
    @State private var showingNewFolderPrompt = false
    @State private var showingRenamePrompt = false
    @State private var promptText = ""
    @State private var itemPendingDeletion: RemoteFileItem?

    private var selectedItem: RemoteFileItem? {
        guard let id = selection.first else { return nil }
        return items.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            browserToolbar
            Divider()

            if items.isEmpty, busyMessage == nil {
                ContentUnavailableView {
                    Label("此目录为空", systemImage: "folder")
                } description: {
                    Text("上传文件或创建文件夹以开始使用 SFTP。")
                } actions: {
                    Button("上传文件", systemImage: "square.and.arrow.up") {
                        chooseFilesToUpload()
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
            await loadDirectory(".")
        }
        .alert("新建文件夹", isPresented: $showingNewFolderPrompt) {
            TextField("文件夹名称", text: $promptText)
            Button("取消", role: .cancel) {}
            Button("创建") {
                createFolder(named: promptText)
            }
        } message: {
            Text("将在 \(currentPath) 中创建文件夹。")
        }
        .alert("重命名", isPresented: $showingRenamePrompt) {
            TextField("新名称", text: $promptText)
            Button("取消", role: .cancel) {}
            Button("重命名") {
                renameSelectedItem(to: promptText)
            }
        } message: {
            Text(selectedItem?.name ?? "")
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
            Text(
                itemPendingDeletion?.isDirectory == true
                    ? "只能删除空文件夹，此操作无法撤销。"
                    : "远程文件将被永久删除，此操作无法撤销。"
            )
        }
        .alert(
            "SFTP 操作失败",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
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

            Button("上传", systemImage: "square.and.arrow.up") {
                chooseFilesToUpload()
            }
            Button("下载", systemImage: "square.and.arrow.down") {
                downloadSelectedItem()
            }
            .disabled(selectedItem == nil || selectedItem?.isDirectory == true)

            Menu {
                Button("新建文件夹", systemImage: "folder.badge.plus") {
                    promptText = ""
                    showingNewFolderPrompt = true
                }
                Button("重命名", systemImage: "pencil") {
                    beginRename()
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
        .disabled(busyMessage != nil)
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
                } else {
                    Button("下载", systemImage: "square.and.arrow.down") {
                        selection = [item.id]
                        downloadSelectedItem()
                    }
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
                        ProgressView()
                        Text(busyMessage)
                            .font(.callout)
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
            let listing = try await SFTPService.list(config: server.connectionConfig, path: path)
            currentPath = listing.path
            pathText = listing.path
            items = listing.items
            selection.removeAll()
            statusMessage = "已连接 \(server.username)@\(server.host)"
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "无法读取远程目录"
        }
        busyMessage = nil
    }

    private func chooseFilesToUpload() {
        let panel = NSOpenPanel()
        panel.title = "选择要上传到 \(currentPath) 的文件"
        panel.prompt = "上传"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        upload(panel.urls)
    }

    private func upload(_ urls: [URL]) {
        busyMessage = urls.count == 1 ? "正在上传 \(urls[0].lastPathComponent)" : "正在上传 \(urls.count) 个文件"
        Task {
            do {
                try await SFTPService.upload(
                    localURLs: urls,
                    to: currentPath,
                    config: server.connectionConfig
                )
                busyMessage = nil
                statusMessage = "上传完成"
                await loadDirectory(currentPath)
            } catch {
                busyMessage = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func downloadSelectedItem() {
        guard let item = selectedItem, !item.isDirectory else { return }
        let panel = NSSavePanel()
        panel.title = "下载 \(item.name)"
        panel.nameFieldStringValue = item.name
        panel.prompt = "下载"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        busyMessage = "正在下载 \(item.name)"
        Task {
            do {
                try await SFTPService.download(
                    item: item,
                    to: destination,
                    config: server.connectionConfig
                )
                statusMessage = "已下载到 \(destination.path)"
            } catch {
                errorMessage = error.localizedDescription
            }
            busyMessage = nil
        }
    }

    private func createFolder(named name: String) {
        busyMessage = "正在创建文件夹"
        Task {
            do {
                try await SFTPService.createDirectory(
                    named: name,
                    in: currentPath,
                    config: server.connectionConfig
                )
                busyMessage = nil
                statusMessage = "文件夹已创建"
                await loadDirectory(currentPath)
            } catch {
                busyMessage = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func beginRename() {
        guard let item = selectedItem else { return }
        promptText = item.name
        showingRenamePrompt = true
    }

    private func renameSelectedItem(to name: String) {
        guard let item = selectedItem else { return }
        busyMessage = "正在重命名 \(item.name)"
        Task {
            do {
                try await SFTPService.rename(
                    item: item,
                    to: name,
                    config: server.connectionConfig
                )
                busyMessage = nil
                statusMessage = "重命名完成"
                await loadDirectory(currentPath)
            } catch {
                busyMessage = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func delete(_ item: RemoteFileItem) {
        itemPendingDeletion = nil
        busyMessage = "正在删除 \(item.name)"
        Task {
            do {
                try await SFTPService.delete(item: item, config: server.connectionConfig)
                busyMessage = nil
                statusMessage = "已删除 \(item.name)"
                await loadDirectory(currentPath)
            } catch {
                busyMessage = nil
                errorMessage = error.localizedDescription
            }
        }
    }
}
