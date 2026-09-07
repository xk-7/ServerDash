import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RecordingToolbarButton: View {
    @ObservedObject var controller: TerminalSessionController
    @ObservedObject var recording: TerminalRecordingController
    @State private var consent = false
    init(controller: TerminalSessionController) {
        self.controller = controller; recording = controller.recording
    }
    var body: some View {
        HStack(spacing: 5) {
            if recording.isRecording { Text(recordingTime(recording.elapsed)).monospacedDigit().foregroundStyle(.red) }
            Button {
                if recording.isRecording { recording.stop() }
                else if RecordingSettings.shared.consent { controller.startRecording() }
                else { consent = true }
            } label: {
                Label(recording.state == .saving ? "保存中" : recording.isRecording ? "停止" : "录制",
                      systemImage: recording.isRecording ? "stop.circle.fill" : "record.circle")
                    .foregroundStyle(recording.isRecording ? .red : .primary)
                    .frame(minHeight: 44)
            }
            .disabled(recording.state == .saving || (!recording.isRecording && controller.status != .connected))
            .help("仅录制当前 SSH 面板；其他面板需分别开始录制")
            if recording.hasImages {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    .help("检测到终端内嵌图片，首版录制不能完整还原图片。")
            }
        }
        .alert("开始终端录制？", isPresented: $consent) {
            Button("取消", role: .cancel) {}
            Button("了解风险并开始") { RecordingSettings.shared.consent = true; controller.startRecording() }
        } message: {
            Text("将保存当前可见屏幕和此后的终端输出，不保存原始键盘事件或隐藏的密码输入。屏幕与服务器输出仍可能含密码、令牌和业务数据，不提供自动可靠脱敏。录制仅存本机，不具备防篡改审计保证。")
        }
        .popover(isPresented: Binding(get: { recording.message != nil }, set: { if !$0 { recording.message = nil } })) {
            VStack(alignment: .leading, spacing: 12) {
                Text(recording.message ?? "").fixedSize(horizontal: false, vertical: true)
                Button("知道了") { recording.message = nil }
            }.padding().frame(width: 300)
        }
    }
}

struct RecordingPaneIndicator: View {
    @ObservedObject var recording: TerminalRecordingController
    var body: some View {
        if recording.isRecording {
            Label(recordingTime(recording.elapsed), systemImage: "record.circle.fill")
                .foregroundStyle(.red).monospacedDigit().accessibilityLabel("正在录制 \(recordingTime(recording.elapsed))")
        }
    }
}

func recordingTime(_ value: Double) -> String {
    let seconds = max(0, Int(value.isFinite ? value : 0))
    return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
}

struct RecordingSettingsView: View {
    @ObservedObject private var settings = RecordingSettings.shared
    @State private var error: String?
    var body: some View {
        Form {
            Section("保存位置") {
                Text(settings.directoryLabel).font(.callout.monospaced()).textSelection(.enabled)
                HStack {
                    Button("选择目录…") {
                        do { try settings.selectDirectory() } catch { self.error = RecordingError.directory.localizedDescription }
                    }
                    Button("恢复默认目录") { settings.restoreDefault() }
                }
                Text("修改目录仅影响新录制，不移动旧文件。可通过“打开录制文件”访问旧目录；失效的目录授权必须重新选择。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("文件命名") {
                TextField("文件名模板", text: $settings.filenameTemplate)
                Text("支持 {date}、{time}、{name}、{id}。非法字符会替换，始终附加唯一 ID，不覆盖已有文件。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("隐私与兼容性") {
                Text("仅录制 macOS SSH 终端，不录制原始键盘输入。当前屏幕及服务器输出可能包含敏感数据，请在分享前完整预览。")
                Text(".sdrec 为 ServerDash 本地录制格式，不是屏幕录像；内嵌图片协议、工具栏、搜索标记及补全弹窗不包含在回放中。文件校验不等同于防篡改证明。")
                Button("下次录制时重新显示安全提示") { settings.consent = false }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.formStyle(.grouped)
    }
}

struct RecordingLibraryView: View {
    @ObservedObject private var store = RecordingStore.shared
    @StateObject private var player = RecordingPlayer()
    @State private var search = ""
    @State private var selection: URL?
    @State private var pendingTrash: RecordingListItem?
    @State private var export = false
    private var items: [RecordingListItem] {
        store.items.filter { search.isEmpty || $0.url.lastPathComponent.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("录制").font(.title2.bold())
                    Spacer()
                    Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("刷新录制列表")
                }
                TextField("搜索录制名称", text: $search).textFieldStyle(.roundedBorder)
                Button("打开录制文件…", action: openFile)
                if store.loading { ProgressView() }
                List(selection: $selection) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(item.url.deletingPathExtension().lastPathComponent,
                                  systemImage: item.partial ? "exclamationmark.circle" : "play.rectangle")
                                .lineLimit(2)
                            Text(item.date, style: .date).font(.caption).foregroundStyle(.secondary)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)).font(.caption)
                            if store.activeURLs.contains(item.url) { Text("正在录制或保存").font(.caption).foregroundStyle(.red) }
                            else if item.partial { Text("未正常结束 · 选择后恢复有效片段").font(.caption).foregroundStyle(.orange) }
                        }.padding(.vertical, 4).tag(item.url)
                            .contextMenu {
                                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                                Button("移到废纸篓", role: .destructive) { pendingTrash = item }
                                    .disabled(store.activeURLs.contains(item.url))
                            }
                    }
                }
                if let message = store.message {
                    Text(message).font(.caption).foregroundStyle(.orange)
                    Button("关闭提示") { store.message = nil }
                }
                Text("录制只保存在本机，不会自动上传。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding().frame(minWidth: 230, idealWidth: 290, maxWidth: 370)
            VStack(spacing: 12) {
                if let document = player.document {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(document.header.name).font(.headline)
                            Text(document.header.date, style: .date).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("导出 GIF…") { player.pause(); export = true }.disabled(document.duration <= 0)
                        Button { NSWorkspace.shared.activateFileViewerSelecting([document.url]) } label: { Image(systemName: "folder") }
                            .accessibilityLabel("在 Finder 中显示")
                    }
                    if let image = player.image {
                        Image(decorative: image, scale: 1).resizable().interpolation(.high).scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityLabel("只读终端录制回放")
                    }
                    if document.hasImages { Text("包含终端内嵌图片，回放无法完整还原。 ").font(.caption).foregroundStyle(.orange) }
                    playbackControls(duration: document.duration)
                } else if player.loading { ProgressView("正在校验录制文件…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                else {
                    ContentUnavailableView("选择一段录制", systemImage: "play.rectangle",
                        description: Text("连接 SSH 后，在终端工具栏点击“录制”。也可以打开本地 .sdrec 文件。"))
                }
                if let message = player.message { Text(message).foregroundStyle(.orange).font(.callout) }
            }.padding().frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { store.refresh() }
        .onDisappear { player.close() }
        .onChange(of: selection) { _, url in
            guard let url else { return }
            guard !store.activeURLs.contains(url) else { player.close(); player.message = "请先停止并保存录制。"; return }
            do { player.open(url, lease: try RecordingSettings.shared.lease()) }
            catch { store.message = RecordingError.directory.localizedDescription }
        }
        .sheet(isPresented: $export) {
            if let doc = player.document { GIFExportView(document: doc) }
        }
        .confirmationDialog("将录制移到废纸篓？", isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } })) {
            Button("移到废纸篓", role: .destructive) {
                if let item = pendingTrash {
                    if player.document?.url == item.url { player.close(); selection = nil }
                    store.trash(item)
                }
                pendingTrash = nil
            }
            Button("取消", role: .cancel) { pendingTrash = nil }
        } message: { Text("可以从系统废纸篓恢复。") }
    }
    private func playbackControls(duration: Double) -> some View {
        VStack {
            Slider(value: Binding(get: { player.position }, set: { player.seek($0) }), in: 0...max(0.001, duration))
                .accessibilityLabel("回放时间轴")
            HStack {
                Button { player.seek(player.position - 10) } label: { Image(systemName: "gobackward.10") }.accessibilityLabel("后退十秒")
                Button { player.toggle() } label: { Image(systemName: player.playing ? "pause.fill" : "play.fill") }
                    .accessibilityLabel(player.playing ? "暂停" : "播放")
                Button { player.seek(player.position + 10) } label: { Image(systemName: "goforward.10") }.accessibilityLabel("前进十秒")
                Text("\(recordingTime(player.position)) / \(recordingTime(duration))").font(.caption.monospacedDigit())
                Spacer()
                Picker("速度", selection: $player.speed) {
                    ForEach([0.25, 0.5, 1, 2, 4, 8], id: \.self) { Text("\($0.formatted())×").tag($0) }
                }.frame(width: 120)
                Toggle("跳过空闲", isOn: $player.skipIdle).help("将超过两秒的输出空闲压缩为两秒")
            }.controlSize(.regular)
        }
    }
    private func openFile() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "sdrec") ?? .data, UTType(filenameExtension: "partial") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        player.open(url, lease: RecordingDirectoryLease(url, scoped: scoped))
    }
}

struct GIFExportView: View {
    let document: RecordingDocument
    @Environment(\.dismiss) private var dismiss
    @State private var options = GIFExportOptions()
    @State private var progress = 0.0
    @State private var running = false
    @State private var task: Task<Void, Never>?
    @State private var error: String?
    @State private var savedURL: URL?
    @State private var preview: CGImage?
    @State private var previewGeneration = UUID()
    @State private var previewTask: Task<Void, Never>?
    var body: some View {
        VStack(spacing: 12) {
            Text("导出 GIF 片段").font(.title2.bold())
            if let preview { Image(decorative: preview, scale: 1).resizable().scaledToFit().frame(height: 190) }
            Form {
                HStack {
                    TextField("开始（秒）", value: $options.start, format: .number.grouping(.never))
                    TextField("结束（秒）", value: $options.end, format: .number.grouping(.never))
                }
                Stepper("帧率：\(options.fps) FPS", value: $options.fps, in: 1...30)
                Stepper("画质：\(options.quality) / 30", value: $options.quality, in: 1...30)
                TextField("水印（可选）", text: $options.watermark)
                let size = options.dimensions(document)
                Text("\(size.width) × \(size.height) 像素 · 原尺寸 \(Int(options.scale * 100))% · 最多五分钟")
                    .font(.caption).foregroundStyle(.secondary)
                Text("画质决定像素缩放，水印占用独立底部区域。分享前请检查画面中是否包含敏感信息。")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(running)
            if running { ProgressView(value: progress) }
            if let error { Text(error).foregroundStyle(.orange) }
            if let savedURL {
                HStack {
                    Button("复制 GIF 文件") { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([savedURL as NSURL]) }
                    ShareLink(item: savedURL) { Label("分享", systemImage: "square.and.arrow.up") }
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([savedURL]) }
                }
            }
            HStack {
                Button(running ? "取消导出" : "关闭") { if running { task?.cancel() } else { dismiss() } }
                Spacer()
                Button("选择保存位置并导出…", action: startExport).disabled(running)
                    .buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 620).background(.background)
        .interactiveDismissDisabled(running)
        .onAppear { options.end = min(300, document.duration); updatePreview() }
        .onChange(of: options.start) { _, _ in updatePreview() }
        .onChange(of: options.quality) { _, _ in updatePreview() }
        .onChange(of: options.watermark) { _, _ in updatePreview() }
        .onDisappear { task?.cancel(); previewTask?.cancel() }
    }
    private func updatePreview() {
        previewTask?.cancel(); let id = UUID(); previewGeneration = id
        let value = options, doc = document
        guard value.start.isFinite, value.start >= 0 else { preview = nil; return }
        previewTask = Task {
            let render = Task.detached(priority: .utility) {
                let cursor = try RecordingCursor(doc), size = value.dimensions(doc)
                return try RecordingRenderer.image(frame: cursor.seek(max(0, value.start)), time: max(0, value.start),
                                                   width: size.width, height: size.height, watermark: String(value.watermark.prefix(256)))
            }
            let result = try? await withTaskCancellationHandler { try await render.value } onCancel: { render.cancel() }
            if id == previewGeneration, !Task.isCancelled { preview = result }
        }
    }
    private func startExport() {
        do { try options.validate(duration: document.duration) }
        catch { self.error = RecordingError.exportRange.localizedDescription; return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.gif]; panel.nameFieldStringValue = "ServerDash-recording.gif"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        let lease = RecordingDirectoryLease(url, scoped: scoped), value = options
        running = true; progress = 0; error = nil; savedURL = nil
        task = Task {
            defer { _ = lease; running = false }
            do {
                try await GIFExporter.shared.export(document: document, options: value, to: url) { value in
                    Task { @MainActor in progress = value }
                }
                savedURL = url
            } catch is CancellationError { error = "导出已取消，临时文件已清理。" }
            catch RecordingError.exportResources { error = RecordingError.exportResources.localizedDescription }
            catch { self.error = "GIF 导出失败，请检查磁盘空间、文件权限或录制数据。" }
        }
    }
}
