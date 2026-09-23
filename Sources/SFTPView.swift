import AppKit
import SwiftUI

@MainActor final class DesktopFileClipboard: ObservableObject {
    static let shared = DesktopFileClipboard()
    @Published var serverID: UUID?
    @Published var items: [RemoteFileItem] = []
    @Published var cut = false
    func clear() { items = []; serverID = nil; cut = false }
}

enum FileBrowserChromeMode: Sendable {
    case full
    case inspector
}

/// Responsive decisions use the browser's own width, which can be much
/// smaller than the window when the terminal inspector is open.
struct SFTPBrowserLayout: Equatable {
    let compactActions: Bool
    let showsSecondaryColumns: Bool

    init(width: CGFloat, chromeMode: FileBrowserChromeMode) {
        let narrow = width < MacWorkspaceMetrics.compactWidth
        compactActions = chromeMode == .inspector || narrow
        showsSecondaryColumns = chromeMode == .full && !narrow
    }

    func tableColumns(from existing: TableColumnCustomization<RemoteFileItem>) -> TableColumnCustomization<RemoteFileItem> {
        var columns = existing
        columns[visibility: "permissions"] = showsSecondaryColumns ? .visible : .hidden
        columns[visibility: "owner"] = showsSecondaryColumns ? .visible : .hidden
        return columns
    }
}

enum SFTPDialogInput {
    static func permissionMode(_ input: String) -> UInt16? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 4,
              value.utf8.allSatisfy({ (48...55).contains($0) }) else { return nil }
        return UInt16(value, radix: 8)
    }

    static func archiveName(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != ".", value != "..",
              !value.contains("/"), !value.contains("\0") else { return nil }
        return value
    }
}

private enum InspectorBrowserPopover: String, Identifiable {
    case path
    case search

    var id: String { rawValue }
}

struct SFTPBrowserView: View {
    @ObservedObject var controller: MacSFTPController
    let chromeMode: FileBrowserChromeMode
    @ObservedObject private var clipboard = DesktopFileClipboard.shared
    @ObservedObject private var editor = RemoteEditorStore.shared
    @State private var showingPermissions = false
    @State private var permissions = "644"
    @State private var permissionsError: String?
    @State private var recursivePermissions = false
    @State private var showingArchive = false
    @State private var archiveName = "archive"
    @State private var archiveError: String?
    @State private var archiveFormat = RemoteArchiveFormat.tarGzip
    @State private var showingPasteConflict = false
    @State private var showingEditor = false
    @State private var showingSync = false
    @State private var showingLocalCopies = false
    @State private var showSyncSuggestion = true
    @State private var inspectorPopover: InspectorBrowserPopover?
    @State private var tableColumnCustomization = TableColumnCustomization<RemoteFileItem>()
    @FocusState private var permissionsFocused: Bool
    @FocusState private var archiveNameFocused: Bool

    init(controller: MacSFTPController, chromeMode: FileBrowserChromeMode = .full) {
        _controller = ObservedObject(wrappedValue: controller)
        self.chromeMode = chromeMode
    }

    init(controller: MacSFTPController, compact: Bool) {
        _controller = ObservedObject(wrappedValue: controller)
        chromeMode = compact ? .inspector : .full
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = SFTPBrowserLayout(width: geometry.size.width, chromeMode: chromeMode)
            VStack(spacing: 0) {
                browserToolbar(layout: layout)
                Divider()
                if chromeMode == .full && showSyncSuggestion && DesktopFilePreferences.promptDirectorySync && controller.hasLoadedDirectory {
                    HStack {
                        Button("配置目录同步", systemImage: "arrow.triangle.2.circlepath") { showingSync = true }
                        Spacer()
                        Button { showSyncSuggestion = false } label: { Image(systemName: "xmark") }.help("隐藏本次提示")
                    }.font(.caption).buttonStyle(.borderless).padding(8).background(Color.accentColor.opacity(0.06))
                }
                if let failure = controller.directoryError {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("无法读取目录").font(.callout.bold())
                            Text(failure).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer(minLength: 8)
                        Button("重试") { Task { await controller.retryDirectory() } }
                            .disabled(controller.busyMessage != nil)
                    }
                    .padding(12).background(Color.orange.opacity(0.07))
                }
                // Keep the native table mounted during refreshes, empty results and errors.
                // Stable rows retain the scroll view and its selection/scroll position.
                fileTable(layout: layout).overlay {
                    if controller.visibleItems.isEmpty, controller.busyMessage == nil, controller.directoryError == nil {
                        ContentUnavailableView {
                            Label(controller.search.isEmpty ? (controller.hasLoadedDirectory ? "此目录为空" : "尚未读取远程目录") : "没有匹配文件", systemImage: "folder")
                        } description: {
                            Text(controller.search.isEmpty ? "上传文件或创建项目；隐藏文件可在工具栏显示。" : "尝试其他关键词，或显示隐藏文件。")
                        } actions: {
                            Button("刷新") { Task { await controller.loadDirectory(controller.currentPath) } }
                        }
                    }
                }
                Divider()
                statusBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appGround)
        .onAppear {
            controller.beginIfNeeded()
            // QA fixtures use an in-memory controller and never register the
            // background directory-sync scheduler or a remote edit access.
            if !MacUIFixture.isEnabled, let access = controller.fileAccess {
                editor.register(access)
                DirectorySyncStore.shared.register(access)
            }
        }
        .popover(item: $inspectorPopover) { item in
            inspectorPopoverContent(item)
        }
        .alert("新建文件夹", isPresented: $controller.showingNewFolderPrompt) {
            TextField("文件夹名称", text: $controller.promptText)
            Button("取消", role: .cancel) {}
            Button("创建") { controller.createFolder(named: controller.promptText) }
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
        }
        .alert("移动到", isPresented: $controller.showingMovePrompt) {
            TextField("目标目录", text: $controller.promptText)
            Button("取消", role: .cancel) {}
            Button("移动") { controller.moveSelectedItem(to: controller.promptText) }
        }
        .confirmationDialog("删除 \(controller.itemPendingDeletion?.name ?? "项目")？", isPresented: Binding(get: { controller.itemPendingDeletion != nil }, set: { if !$0 { controller.itemPendingDeletion = nil } })) {
            Button("删除", role: .destructive) { if let item = controller.itemPendingDeletion { controller.delete(item) } }
            Button("取消", role: .cancel) { controller.itemPendingDeletion = nil }
        } message: { Text(controller.itemPendingDeletion?.isDirectory == true ? "文件夹及全部内容将永久删除。" : "远程文件将被永久删除。") }
        .confirmationDialog("目标已存在", isPresented: $controller.showingConflict) {
            Button("覆盖") { controller.resolveConflict(.overwrite) }
            Button("跳过") { controller.resolveConflict(.skip) }
            Button("重命名") { controller.resolveConflict(.rename) }
            Button("取消", role: .cancel) { controller.pendingUploads = []; controller.pendingDownloads = [] }
        }
        .confirmationDialog("粘贴时发现同名项目", isPresented: $showingPasteConflict) {
            Button("覆盖同名项目", role: .destructive) { controller.pasteFiles(policy: .overwrite) }
            Button("跳过同名项目") { controller.pasteFiles(policy: .skip) }
            Button("自动重命名") { controller.pasteFiles(policy: .rename) }
        }
        .alert("SFTP 操作失败", isPresented: Binding(get: { controller.errorMessage != nil }, set: { if !$0 { controller.errorMessage = nil } })) {
            Button("好") { controller.errorMessage = nil }
        } message: { Text(controller.errorMessage ?? "") }
        .sheet(isPresented: $showingEditor) { RemoteEditorView() }
        .sheet(isPresented: $showingLocalCopies) { LocalFileCopiesView(serverID:controller.server.id) }
        .sheet(isPresented: $showingSync) { if let access = controller.fileAccess { DirectorySyncView(access: access, remotePath: controller.currentPath) } }
        .sheet(isPresented: $showingPermissions) { permissionsSheet }
        .sheet(isPresented: $showingArchive) { archiveSheet }
    }

    @ViewBuilder private func browserToolbar(layout: SFTPBrowserLayout) -> some View {
        if chromeMode == .inspector {
            inspectorToolbar
        } else {
            fullToolbar(layout: layout)
        }
    }

    private func fullToolbar(layout: SFTPBrowserLayout) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Button { Task { await controller.loadDirectory(".") } } label: { Image(systemName: "house") }.help("主目录")
                Button { Task { await controller.loadDirectory(RemotePath.parent(of: controller.currentPath)) } } label: { Image(systemName: "chevron.up") }.help("上级目录").disabled(controller.currentPath == "/")
                TextField("远程路径", text: $controller.pathText).textFieldStyle(.roundedBorder).font(.callout.monospaced()).onSubmit { Task { await controller.loadDirectory(controller.pathText) } }
                    .accessibilityIdentifier("sftp.browser.path")
                Button { Task { await controller.loadDirectory(controller.currentPath) } } label: { Image(systemName: "arrow.clockwise") }
                    .help("刷新").accessibilityLabel("刷新远程目录").accessibilityIdentifier("sftp.browser.refresh")
            }
            HStack(spacing: 8) {
                TextField("搜索文件", text: $controller.search).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("sftp.browser.search")
                if layout.compactActions {
                    Menu {
                        Toggle("显示隐藏文件", isOn: $controller.showHidden)
                        Divider()
                        transferFileActions
                        Divider()
                        secondaryFileActions
                    } label: { Image(systemName: "ellipsis.circle") }
                        .help("更多文件操作")
                        .accessibilityLabel("更多文件操作")
                        .accessibilityIdentifier("sftp.browser.more")
                } else {
                    Toggle(isOn: $controller.showHidden) { Image(systemName: controller.showHidden ? "eye" : "eye.slash") }.toggleStyle(.button).help("显示隐藏文件")
                    Menu {
                        Button("上传文件", systemImage: "doc.badge.plus") { controller.chooseItemsToUpload(directories: false) }
                        Button("上传文件夹", systemImage: "folder.badge.plus") { controller.chooseItemsToUpload(directories: true) }
                    } label: { Image(systemName: "square.and.arrow.up") }.help("上传")
                    Button { controller.downloadSelectedItems() } label: { Image(systemName: "square.and.arrow.down") }
                        .help("下载所选项目").accessibilityLabel("下载所选项目").disabled(controller.selectedItems.isEmpty)
                    Menu {
                        secondaryFileActions
                    } label: { Image(systemName: "ellipsis.circle") }
                        .help("文件操作")
                        .accessibilityLabel("更多文件操作")
                        .accessibilityIdentifier("sftp.browser.more")
                }
            }
        }.controlSize(.regular).buttonStyle(.borderless)
            .padding(12).background(.bar)
            .disabled(controller.busyMessage != nil && controller.transferTask == nil)
    }

    @ViewBuilder private var transferFileActions: some View {
        Button("上传文件", systemImage: "doc.badge.plus") { controller.chooseItemsToUpload(directories: false) }
        Button("上传文件夹", systemImage: "folder.badge.plus") { controller.chooseItemsToUpload(directories: true) }
        Button("下载所选项目", systemImage: "square.and.arrow.down") { controller.downloadSelectedItems() }
            .disabled(controller.selectedItems.isEmpty)
    }

    private var inspectorToolbar: some View {
        HStack(spacing: 6) {
            Button {
                Task { await controller.loadDirectory(RemotePath.parent(of: controller.currentPath)) }
            } label: {
                Image(systemName: "chevron.up")
            }
            .help("上级目录")
            .accessibilityLabel("上级目录")
            .disabled(controller.currentPath == "/")

            Button {
                Task { await controller.loadDirectory(controller.currentPath) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("刷新")
            .accessibilityLabel("刷新远程目录")
            .accessibilityIdentifier("sftp.browser.refresh")

            Button {
                inspectorPopover = .path
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                    Text(controller.currentPath)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .help("转到远程路径")
            .accessibilityLabel("当前远程路径 \(controller.currentPath)")
            .accessibilityIdentifier("sftp.browser.path")

            Button {
                inspectorPopover = .search
            } label: {
                Image(systemName: controller.search.isEmpty ? "magnifyingglass" : "line.3.horizontal.decrease.circle.fill")
            }
            .help(controller.search.isEmpty ? "搜索文件" : "正在筛选：\(controller.search)")
            .accessibilityLabel(controller.search.isEmpty ? "搜索文件" : "编辑文件筛选")
            .accessibilityIdentifier("sftp.browser.search")

            Menu {
                Toggle("显示隐藏文件", isOn: $controller.showHidden)
                Divider()
                Button("上传文件", systemImage: "doc.badge.plus") { controller.chooseItemsToUpload(directories: false) }
                Button("上传文件夹", systemImage: "folder.badge.plus") { controller.chooseItemsToUpload(directories: true) }
                Button("下载所选项目", systemImage: "square.and.arrow.down") { controller.downloadSelectedItems() }
                    .disabled(controller.selectedItems.isEmpty)
                Divider()
                secondaryFileActions
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .help("文件操作")
            .accessibilityLabel("更多文件操作")
            .accessibilityIdentifier("sftp.browser.more")
        }
        .controlSize(.small)
        .buttonStyle(.borderless)
        .padding(8)
        .background(.bar)
        .disabled(controller.busyMessage != nil && controller.transferTask == nil)
    }

    @ViewBuilder private var secondaryFileActions: some View {
        Button("新建文件夹", systemImage: "folder.badge.plus") { controller.promptText = ""; controller.showingNewFolderPrompt = true }
        Button("新建文件", systemImage: "doc.badge.plus") { controller.promptText = ""; controller.showingNewFilePrompt = true }
        Divider()
        Button("粘贴", systemImage: "doc.on.clipboard", action: paste)
            .disabled(clipboard.serverID != controller.server.id || clipboard.items.isEmpty)
        Button("目录同步…", systemImage: "arrow.triangle.2.circlepath") { showingSync = true }
        Button("打开编辑器与恢复草稿", systemImage: "doc.text") { showingEditor = true }
        Button("本地副本 / 上传修改…", systemImage: "arrow.up.doc") { showingLocalCopies = true }
        if controller.hasActiveTransfer {
            Button("取消当前操作", role: .destructive) { controller.transferTask?.cancel() }
        }
    }

    @ViewBuilder private func inspectorPopoverContent(_ item: InspectorBrowserPopover) -> some View {
        switch item {
        case .path:
            VStack(alignment: .leading, spacing: 12) {
                Text("转到远程路径").font(.headline)
                TextField("远程路径", text: $controller.pathText)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .onSubmit { openInspectorPath() }
                    .accessibilityIdentifier("sftp.browser.path.input")
                HStack {
                    Button("主目录") {
                        controller.pathText = "."
                        openInspectorPath()
                    }
                    Spacer()
                    Button("打开") { openInspectorPath() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
            .frame(width: 330)
        case .search:
            VStack(alignment: .leading, spacing: 12) {
                Text("筛选当前目录").font(.headline)
                TextField("搜索文件", text: $controller.search)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("sftp.browser.search.input")
                Toggle("显示隐藏文件", isOn: $controller.showHidden)
                HStack {
                    Button("清除") { controller.search = "" }
                        .disabled(controller.search.isEmpty)
                    Spacer()
                    Button("完成") { inspectorPopover = nil }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
            .frame(width: 300)
        }
    }

    private func openInspectorPath() {
        let path = controller.pathText
        inspectorPopover = nil
        Task { await controller.loadDirectory(path) }
    }

    private var permissionsSheet: some View {
        MacEditorSheetScaffold(
            title: "修改权限",
            accessibilityID: "sftp.permissions",
            saveTitle: "应用",
            errorMessage: permissionsError,
            saveDisabled: controller.selectedItems.isEmpty,
            maxContentWidth: 480,
            onCancel: { showingPermissions = false },
            onSave: {
                guard let mode = SFTPDialogInput.permissionMode(permissions) else {
                    permissionsError = "请输入 1 至 4 位八进制权限（0–7）。"
                    return
                }
                controller.changePermissions(mode, recursive: recursivePermissions)
                showingPermissions = false
            },
            onValidationError: { permissionsFocused = true }
        ) {
            VStack(alignment: .leading, spacing: 14) {
                Text("已选择 \(controller.selectedItems.count) 个项目。符号链接不会被跟随。")
                    .foregroundStyle(.secondary)
                TextField("八进制权限，例如 644 或 755", text: $permissions)
                    .textFieldStyle(.roundedBorder)
                    .focused($permissionsFocused)
                    .accessibilityIdentifier("sftp.permissions.value")
                    .onChange(of: permissions) { _, _ in permissionsError = nil }
                Toggle("递归应用到文件夹内的文件和子文件夹", isOn: $recursivePermissions)
                Text("读取 r = 4，写入 w = 2，执行 x = 1；依次为所有者、组、其他用户。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 320, idealWidth: 500, maxWidth: 560,
               minHeight: 230, idealHeight: 320, maxHeight: 500)
        .onAppear { permissionsFocused = true }
    }

    private var archiveSheet: some View {
        MacEditorSheetScaffold(
            title: "创建压缩包",
            accessibilityID: "sftp.archive",
            saveTitle: "压缩",
            errorMessage: archiveError,
            saveDisabled: controller.selectedItems.isEmpty,
            maxContentWidth: 440,
            onCancel: { showingArchive = false },
            onSave: {
                guard let name = SFTPDialogInput.archiveName(archiveName) else {
                    archiveError = "请输入不包含路径分隔符的压缩包名称。"
                    return
                }
                controller.archiveSelection(name: name, format: archiveFormat)
                showingArchive = false
            },
            onValidationError: { archiveNameFocused = true }
        ) {
            VStack(alignment: .leading, spacing: 14) {
                Text("已选择 \(controller.selectedItems.count) 个项目。")
                    .foregroundStyle(.secondary)
                TextField("压缩包名称", text: $archiveName)
                    .textFieldStyle(.roundedBorder)
                    .focused($archiveNameFocused)
                    .accessibilityIdentifier("sftp.archive.name")
                    .onChange(of: archiveName) { _, _ in archiveError = nil }
                Picker("格式", selection: $archiveFormat) {
                    ForEach(RemoteArchiveFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                Text("保存在当前目录，保留符号链接，不覆盖同名压缩包。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 320, idealWidth: 460, maxWidth: 520,
               minHeight: 220, idealHeight: 300, maxHeight: 480)
        .onAppear { archiveNameFocused = true }
    }

    private func fileTable(layout: SFTPBrowserLayout) -> some View {
        tableContent(layout: layout)
        .accessibilityIdentifier("sftp.browser.table")
        .contextMenu(forSelectionType: String.self) { ids in
            let items = controller.items.filter { ids.contains($0.id) }
            if let first = items.first {
                if first.isDirectory { Button("打开", systemImage: "folder") { Task { await controller.loadDirectory(first.path) } } }
                Button("复制", systemImage: "doc.on.doc") { controller.selection = ids; controller.copyFiles(cut: false) }
                Button("剪切", systemImage: "scissors") { controller.selection = ids; controller.copyFiles(cut: true) }
                Button("复制路径", systemImage: "link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(items.map(\.path).joined(separator: "\n"), forType: .string) }
                Button("粘贴", systemImage: "doc.on.clipboard", action: paste).disabled(clipboard.serverID != controller.server.id || clipboard.items.isEmpty)
                Divider()
                Button("压缩…", systemImage: "archivebox") {
                    controller.selection = ids
                    archiveName = items.count == 1 ? first.name : "archive"
                    archiveError = nil
                    showingArchive = true
                }
                Button("编辑", systemImage: "square.and.pencil") { openEditor(items) }.disabled(items.contains { $0.kind != .file })
                Menu("以指定编码编辑") { ForEach(RemoteTextEncoding.allCases) { encoding in Button(encoding.rawValue) { openEditor(items, encoding: encoding) } } }.disabled(items.contains { $0.kind != .file })
                Button("用本地程序打开", systemImage: "arrow.up.forward.app") { controller.openLocalCopy(first);showingLocalCopies=true }.disabled(first.kind != .file || editor.busy)
                Button("下载", systemImage: "square.and.arrow.down") { controller.selection = ids; controller.downloadSelectedItems() }
                Button("重命名…", systemImage: "pencil") { controller.selection = [first.id]; controller.beginRename() }.disabled(items.count != 1)
                Button("移动到…", systemImage: "arrow.right") { controller.selection = [first.id]; controller.promptText = controller.currentPath; controller.showingMovePrompt = true }.disabled(items.count != 1)
                Button("修改权限…", systemImage: "lock.shield") {
                    controller.selection = ids
                    permissions = first.isDirectory ? "755" : "644"
                    permissionsError = nil
                    recursivePermissions = false
                    showingPermissions = true
                }
                Divider()
                Button("删除", systemImage: "trash", role: .destructive) { controller.itemPendingDeletion = first }.disabled(items.count != 1)
            }
        } primaryAction: { ids in
            guard let first = controller.items.first(where: { ids.contains($0.id) }) else { return }
            if first.isDirectory { Task { await controller.loadDirectory(first.path) } } else { openEditor([first]) }
        }
    }
    /// One Table instance survives layout changes; changing column visibility
    /// does not discard the native scroll view or the controller's selection.
    private func tableContent(layout: SFTPBrowserLayout) -> some View {
        Table(controller.visibleItems, selection: $controller.selection,
              columnCustomization: Binding(
                get: { layout.tableColumns(from: tableColumnCustomization) },
                set: { tableColumnCustomization = $0 }
              )) {
            TableColumn("名称") { item in
                Label(item.name, systemImage: item.isDirectory ? "folder" : item.kind == .symbolicLink ? "link" : "doc")
                    .foregroundStyle(item.isDirectory ? Color.accentColor : Color.primary).lineLimit(1)
            }.width(min: 100, ideal: layout.compactActions ? 180 : 280)
                .customizationID("name")
                .disabledCustomizationBehavior(.visibility)
            TableColumn("大小") { item in Text(item.isDirectory ? "—" : DesktopFileOperations.displaySize(item.size)).monospacedDigit().foregroundStyle(.secondary) }.width(min: 55, ideal: 75, max: 100)
                .customizationID("size")
                .disabledCustomizationBehavior(.visibility)
            TableColumn("修改时间") { item in Text(item.modifiedText).font(.caption).foregroundStyle(.secondary) }.width(min: 65, ideal: layout.compactActions ? 90 : 125, max: 170)
                .customizationID("modified")
                .disabledCustomizationBehavior(.visibility)
            TableColumn("权限") { item in Text(item.permissions).font(.caption.monospaced()).foregroundStyle(.secondary) }.width(105)
                .customizationID("permissions")
                .disabledCustomizationBehavior(.visibility)
            TableColumn("所有者") { item in Text(item.owner).font(.caption).foregroundStyle(.secondary) }.width(100)
                .customizationID("owner")
                .disabledCustomizationBehavior(.visibility)
        }
    }
    private var statusBar: some View {
        VStack(spacing: 4) {
            if let progress = controller.progress {
                if progress.isIndeterminate { ProgressView() }
                else { ProgressView(value: progress.fraction) }
            }
            HStack(spacing: 6) {
                if controller.busyMessage != nil, controller.progress == nil { ProgressView().controlSize(.small) }
                Text(controller.busyMessage ?? controller.statusMessage).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 2)
                if controller.hasActiveTransfer { Button("取消") { controller.transferTask?.cancel() } }
                Text("\(controller.visibleItems.count) 项").monospacedDigit()
            }
        }.font(.caption).foregroundStyle(.secondary).padding(8).background(.bar)
    }
    private func openEditor(_ items: [RemoteFileItem], encoding: RemoteTextEncoding? = nil) {
        guard let access = controller.fileAccess else { return }; editor.open(items, access: access, encoding: encoding); showingEditor = true
    }
    private func paste() {
        if controller.items.contains(where: { item in clipboard.items.contains { $0.name == item.name } }) { showingPasteConflict = true }
        else { controller.pasteFiles(policy: .skip) }
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
    @Published var items: [RemoteFileItem] = [] { didSet { rebuildVisibleItems() } }
    @Published var search = "" { didSet { rebuildVisibleItems() } }
    @Published var showHidden = false { didSet { rebuildVisibleItems() } }
    @Published private(set) var visibleItems: [RemoteFileItem] = []
    @Published private(set) var directoryError: String?
    private var failedDirectoryPath: String?
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
    @Published var pendingDownloads: [SFTPDownloadRequest] = []
    @Published var conflictPolicy: SFTPConflictPolicy = .overwrite

    private func rebuildVisibleItems() {
        visibleItems = items.filter { (showHidden || !$0.name.hasPrefix(".")) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
        selection.formIntersection(visibleItems.map(\.id))
    }
    var selectedItems: [RemoteFileItem] { visibleItems.filter { selection.contains($0.id) } }
    var fileAccess: DesktopFileAccess? { appState.map { DesktopFileAccess(server: server, appState: $0) } }

    var selectedItem: RemoteFileItem? {
        guard let id = selection.first else { return nil }
        return visibleItems.first { $0.id == id }
    }

    private var connectionConfig: ServerConnectionConfig { appState?.connectionConfig(for: server) ?? server.connectionConfig }


    init(server: ServerRecord, appState: AppState, automaticallyConnect: Bool = true) {
        self.server = server; self.appState = appState
        started = !automaticallyConnect
        currentPath = server.defaultSFTPPath.isEmpty ? "." : server.defaultSFTPPath
        pathText = currentPath
    }
    func beginIfNeeded() {
        guard !started, !closed else { return }
        started = true
        Task { [self] in await loadDirectory(currentPath) }
    }
    func close() { _ = beginShutdown() }

    /// Freezes this controller, invalidates late UI callbacks, and returns the
    /// active work so the application shutdown coordinator can drain it under
    /// the same absolute deadline as connection processes and other services.
    @discardableResult
    func beginShutdown() -> [Task<Void, Never>] {
        let tasks = [directoryTask, transferTask].compactMap { $0 }
        closed = true
        generation = UUID()
        directoryTask?.cancel()
        transferTask?.cancel()
        pendingUploads = []
        pendingDownloads = []
        progress = nil
        return tasks
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
        directoryError = nil
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
            applyDirectoryListing(listing)
            statusMessage = "已连接 \(server.username)@\(server.host)"
        } catch {
            guard generation == connection, directoryGeneration == request else { return }
            guard !Task.isCancelled else { return }
            directoryError = error.localizedDescription
            failedDirectoryPath = path
            statusMessage = "无法读取远程目录"
            EventLogStore.append(
                serverID: server.id,
                module: .sftp,
                level: "error",
                message: "SFTP 目录读取失败"
            )
        }
        busyMessage = nil
        progress = nil
    }

    func applyDirectoryListing(_ listing: SFTPDirectoryListing) {
        let sameDirectory = hasLoadedDirectory && currentPath == listing.path
        if !sameDirectory { selection.removeAll() }
        currentPath = listing.path
        pathText = listing.path
        items = listing.items
        hasLoadedDirectory = true
        directoryError = nil
        failedDirectoryPath = nil
    }

    func retryDirectory() async {
        await loadDirectory(failedDirectoryPath ?? currentPath)
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

    func downloadSelectedItems() {
        let selected = selectedItems
        guard !selected.isEmpty else { return }
        let preferred = DesktopFilePreferences.downloadDirectory
        if !preferred.isEmpty {
            let directory = URL(fileURLWithPath: preferred, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                enqueueDownloads(downloadRequests(for: selected, to: directory)); return
            } catch { errorMessage = error.localizedDescription; return }
        }
        if selected.count > 1 || selected[0].isDirectory {
            let panel = NSOpenPanel()
            panel.title = selected.count == 1 ? "选择下载文件夹的位置" : "选择 \(selected.count) 个项目的下载位置"
            panel.prompt = "下载"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            enqueueDownloads(downloadRequests(for: selected, to: folder))
        } else {
            let item = selected[0]
            let panel = NSSavePanel()
            panel.title = "下载 \(item.name)"
            panel.nameFieldStringValue = item.name
            panel.prompt = "下载"
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            enqueueDownloads([SFTPDownloadRequest(item: item, destination: destination)])
        }
    }

    func downloadRequests(for selected: [RemoteFileItem]? = nil, to directory: URL) -> [SFTPDownloadRequest] {
        (selected ?? selectedItems).map {
            SFTPDownloadRequest(item: $0, destination: directory.appendingPathComponent($0.name))
        }
    }

    func enqueueDownloads(_ requests: [SFTPDownloadRequest]) {
        guard !requests.isEmpty else { return }
        if requests.contains(where: { FileManager.default.fileExists(atPath: $0.destination.path) }) {
            pendingDownloads = requests
            showingConflict = true
        } else {
            download(requests, policy: .overwrite)
        }
    }

    func download(_ requests: [SFTPDownloadRequest], policy: SFTPConflictPolicy) {
        guard !closed, transferTask == nil else { return }
        guard !requests.isEmpty else { return }
        let request = generation, transfer = UUID()
        transferGeneration = transfer
        busyMessage = requests.count == 1 ? "正在下载 \(requests[0].item.name)" : "正在下载 \(requests.count) 个项目"
        transferTask = Task { [self] in
            defer { if generation == request { transferTask = nil; busyMessage = nil; progress = nil } }
            do {
                guard let appState else { throw CancellationError() }
                let config = connectionConfig
                try await appState.performTrustedConnection(config, source: .sftp) {
                    try await SFTPService.download(
                        requests: requests,
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
                let folder = requests[0].destination.deletingLastPathComponent().path
                statusMessage = requests.count == 1 ? "已下载到 \(requests[0].destination.path)" : "已下载 \(requests.count) 个项目到 \(folder)"
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
        } else if !pendingDownloads.isEmpty {
            let requests = pendingDownloads
            pendingDownloads = []
            download(requests, policy: policy)
        }
    }

    func createFolder(named name: String) {
        guard !items.contains(where: { $0.name == name }) else { errorMessage = "同名项目已存在。"; return }
        let directory = currentPath
        runMutation("正在创建文件夹") { config in
            try await SFTPService.createDirectory(
                named: name,
                in: directory,
                config: config
            )
        } success: {
            "文件夹已创建"
        }
    }

    func createFile(named name: String) {
        guard !items.contains(where: { $0.name == name }) else { errorMessage = "同名项目已存在，不会覆盖原文件。"; return }
        let directory = currentPath
        runMutation("正在创建文件") { config in
            try await SFTPService.createFile(
                named: name,
                in: directory,
                config: config
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
        guard name != item.name else { return }
        guard !items.contains(where: { $0.name == name }) else { errorMessage = "同名项目已存在。"; return }
        runMutation("正在重命名 \(item.name)") { config in
            try await SFTPService.rename(item: item, to: name, config: config)
        } success: {
            "重命名完成"
        }
    }

    func moveSelectedItem(to directory: String) {
        guard let item = selectedItem else { return }
        runMutation("正在移动 \(item.name)") { config in
            try await SFTPService.move(item: item, to: directory, config: config)
        } success: {
            "移动完成"
        }
    }

    func delete(_ item: RemoteFileItem) {
        itemPendingDeletion = nil
        runMutation("正在删除 \(item.name)") { config in
            try await SFTPService.delete(
                item: item,
                config: config,
                recursive: item.isDirectory
            )
        } success: {
            "已删除 \(item.name)"
        }
    }

    func copyFiles(cut: Bool) {
        guard !selectedItems.isEmpty else { return }
        let clipboard = DesktopFileClipboard.shared
        clipboard.serverID = server.id; clipboard.items = selectedItems; clipboard.cut = cut
        statusMessage = cut ? "已剪切，选择目标目录后粘贴" : "已复制，选择目标目录后粘贴"
    }
    func pasteFiles(policy: SFTPConflictPolicy) {
        let clipboard = DesktopFileClipboard.shared
        guard clipboard.serverID == server.id, !clipboard.items.isEmpty else { return }
        let paths = clipboard.items.map(\.path), cut = clipboard.cut, destination = currentPath
        runMutation(cut ? "正在移动项目" : "正在复制项目") { config in
            try await DesktopFileOperations.mutate(action: cut ? "move" : "copy", paths: paths,
                destination: destination, policy: policy, config: config)
        } success: {
            if cut { clipboard.clear() }
            return cut ? "移动完成" : "复制完成"
        }
    }
    func changePermissions(_ mode: UInt16, recursive: Bool) {
        let paths = selectedItems.map(\.path)
        runMutation("正在修改权限") { config in
            try await DesktopFileOperations.mutate(action: "chmod", paths: paths, mode: mode, recursive: recursive, config: config)
        } success: { "权限已更新" }
    }
    func archiveSelection(name: String, format: RemoteArchiveFormat) {
        let paths = selectedItems.map(\.path)
        let destination = RemotePath.child(name.hasSuffix("." + format.rawValue) ? name : name + "." + format.rawValue, of: currentPath)
        runMutation("正在创建压缩包") { config in
            try await DesktopFileOperations.mutate(action: "archive", paths: paths, destination: destination, format: format, config: config)
        } success: { "压缩包已创建" }
    }
    func openLocalCopy(_ item: RemoteFileItem) {
        guard item.kind == .file,let access=fileAccess else{return}
        RemoteEditorStore.shared.openLocalCopy(item,access:access)
    }

    func runMutation(_ message: String, work: @escaping (ServerConnectionConfig) async throws -> Void, success: @escaping () -> String) {
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
                    try await work(config)
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
