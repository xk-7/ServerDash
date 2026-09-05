import AppKit
import SwiftData
import SwiftUI

struct TerminalShortcutActions {
    let hasSession: Bool
    let canSwitchTabs: Bool
    let newTab: () -> Void
    let font: (TerminalFontShortcut) -> Void
    let find: () -> Void
    let appearance: () -> Void
    let inspector: () -> Void
    let switchTab: (Int) -> Void
}

private struct TerminalShortcutActionsKey: FocusedValueKey {
    typealias Value = TerminalShortcutActions
}

extension FocusedValues {
    var terminalShortcuts: TerminalShortcutActions? {
        get { self[TerminalShortcutActionsKey.self] }
        set { self[TerminalShortcutActionsKey.self] = newValue }
    }
}

struct TerminalCommands: Commands {
    @FocusedValue(\.terminalShortcuts) private var actions

    private func perform(_ action: (TerminalShortcutActions) -> Void) {
        guard let actions, let window = NSApp.keyWindow,
              window.attachedSheet == nil, window.sheetParent == nil,
              NSApp.modalWindow == nil else { return }
        action(actions)
    }

    var body: some Commands {
        CommandMenu("终端") {
            Button("新建 SSH 标签页") { perform { $0.newTab() } }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(actions == nil)
            Divider()
            Button("增大字号") { perform { $0.font(.increase) } }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(actions?.hasSession != true)
            Button("减小字号") { perform { $0.font(.decrease) } }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(actions?.hasSession != true)
            Button("恢复初始字号") { perform { $0.font(.reset) } }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(actions?.hasSession != true)
            Divider()
            Button("查找终端内容…") { perform { $0.find() } }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(actions?.hasSession != true)
            Button("终端外观…") { perform { $0.appearance() } }
                .keyboardShortcut(",", modifiers: [.command, .shift])
                .disabled(actions?.hasSession != true)
            Button("显示 / 隐藏检查器") { perform { $0.inspector() } }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(actions?.hasSession != true)
            Divider()
            Button("下一个标签页") { perform { $0.switchTab(1) } }
                .keyboardShortcut(.tab, modifiers: .control)
                .disabled(actions?.canSwitchTabs != true)
            Button("上一个标签页") { perform { $0.switchTab(-1) } }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .disabled(actions?.canSwitchTabs != true)
        }
    }
}

struct TerminalWorkspaceView: View {
    @EnvironmentObject private var appState: AppState
    let server: ServerRecord

    var body: some View {
        TerminalWorkspaceContent(server: server, registry: appState.terminalRegistry)
    }
}

private struct TerminalWorkspaceContent: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appState: AppState
    @Query(sort: \CommandSnippetRecord.title) private var snippets: [CommandSnippetRecord]
    @State private var snippetPendingExecution: TerminalSnippetRequest?
    @State private var showingAppearance = false
    @SceneStorage("terminal.inspector.visible") private var showingInspector = false
    @SceneStorage("terminal.inspector.tab") private var inspectorTab = "status"

    let server: ServerRecord
    @ObservedObject var registry: TerminalSessionRegistry

    private var selectedSession: TerminalSession? {
        selectedController?.session
    }

    private var selectedController: TerminalSessionController? {
        guard let id = appState.selectedTerminalID else { return nil }
        return registry.controller(for: id)
    }

    private var shortcutActions: TerminalShortcutActions? {
        guard !showingAppearance, snippetPendingExecution == nil else { return nil }
        return TerminalShortcutActions(
            hasSession: selectedController != nil,
            canSwitchTabs: selectedController != nil && registry.controllers.count > 1,
            newTab: { appState.newTerminal(for: server) },
            font: { selectedController?.performFontShortcut($0) },
            find: { selectedController?.hostView.showFindPanel() },
            appearance: { showingAppearance = true },
            inspector: { showingInspector.toggle() },
            switchTab: switchTab
        )
    }

    private func switchTab(by offset: Int) {
        let sessions = registry.sessions
        guard sessions.count > 1,
              let index = sessions.firstIndex(where: { $0.id == appState.selectedTerminalID }) else { return }
        let next = (index + offset + sessions.count) % sessions.count
        appState.selectTerminal(sessions[next])
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppleDesign.Spacing.xs) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: AppleDesign.Spacing.xxs) {
                            ForEach(registry.controllers) { controller in
                                TerminalTab(
                                    controller: controller,
                                    title: tabTitle(for: controller),
                                    isSelected: controller.id == appState.selectedTerminalID,
                                    onSelect: {
                                        appState.selectTerminal(controller.session)
                                        controller.hostView.focusTerminal()
                                    },
                                    onClose: {
                                        appState.closeTerminal(controller.session, context: modelContext)
                                    }
                                )
                                .id(controller.id)
                            }
                        }
                        .padding(.top, AppleDesign.Spacing.xxs)
                    }
                    .onChange(of: appState.selectedTerminalID, initial: true) { _, id in
                        if let id {
                            withAnimation(reduceMotion ? nil : AppleDesign.quick) {
                                proxy.scrollTo(id, anchor: .center)
                            }
                        }
                    }
                }

                Divider()
                    .frame(height: 20)

                Button {
                    appState.newTerminal(for: server)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .frame(width: 32, height: 32)
                .help("为 \(server.displayName) 新建 SSH 标签页（⌘T）")
                .accessibilityLabel("新建 SSH 标签页")
                if let selectedController {
                    Menu {
                        Button("终端外观…", systemImage: "paintpalette") {
                            showingAppearance = true
                        }
                        Divider()
                        Button("增大字号") {
                            selectedController.performFontShortcut(.increase)
                        }
                        Button("减小字号") {
                            selectedController.performFontShortcut(.decrease)
                        }
                        Button("恢复初始字号") {
                            selectedController.performFontShortcut(.reset)
                        }
                        Divider()
                        Text("放大 ⌘+ / ⌘=　缩小 ⌘−　恢复 ⌘0")
                    } label: {
                        Image(systemName: "paintpalette")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 32, height: 32)
                    .help("终端外观")
                    .accessibilityLabel("终端外观与字号")
                    Button {
                        selectedController.hostView.showFindPanel()
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 32, height: 32)
                    .help("查找终端内容（⌘F）")
                    .accessibilityLabel("查找终端内容")
                }
                if let selectedSession, !snippets.isEmpty {
                    Menu {
                        ForEach(snippets) { snippet in
                            Menu(snippet.title) {
                                Button("插入命令", systemImage: "text.cursor") {
                                    requestSnippet(snippet, into: selectedSession.id, execute: false)
                                }
                                Button("执行…", systemImage: "play") {
                                    requestSnippet(snippet, into: selectedSession.id, execute: true)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "curlybraces")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 32, height: 32)
                    .help("插入代码片段")
                    .accessibilityLabel("代码片段")
                }
                Button {
                    showingInspector.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                        .foregroundStyle(showingInspector ? Color.accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                .frame(width: 32, height: 32)
                .disabled(selectedController == nil)
                .help("显示状态与代码片段（⌘⌥I）")
                .accessibilityLabel(showingInspector ? "隐藏终端检查器" : "显示终端检查器")
            }
            .controlSize(.regular)
            .frame(height: 44)
            .padding(.horizontal, AppleDesign.Spacing.xs)
            .background(AppleChromeBackground())

            Rectangle()
                .fill(Color.appHairline.opacity(0.55))
                .frame(height: 1)

            if let selectedController {
                TerminalSessionPane(
                    controller: selectedController,
                    onReconnect: { appState.reconnectTerminal(selectedController.session) }
                )
            } else {
                VStack(spacing: 0) {
                    ServerLocationMapView(server: server)
                        .frame(height: 260)
                        .padding(AppleDesign.Spacing.lg)
                    Divider()
                    ContentUnavailableView {
                        Label("没有打开的终端", systemImage: "terminal")
                    } description: {
                        Text("地图显示服务器公网出口的大致位置。创建标签页以连接 \(server.displayName)。")
                    } actions: {
                        Button("新建 SSH 终端") {
                            appState.newTerminal(for: server)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .inspector(isPresented: $showingInspector) {
            if let selectedController {
                TerminalInspectorView(
                    server: server, controller: selectedController,
                    runtime: appState.runtime(for: server), snippets: snippets,
                    refreshInterval: appState.refreshInterval,
                    selectedTab: $inspectorTab,
                    onInsert: { requestSnippet($0, into: selectedController.id, execute: false) },
                    onRun: { requestSnippet($0, into: selectedController.id, execute: true) }
                )
                .inspectorColumnWidth(min: 280, ideal: 300, max: 360)
            }
        }
        .focusedSceneValue(\.terminalShortcuts, shortcutActions)
        .confirmationDialog(
            "向“\(snippetPendingExecution?.serverName ?? "终端")”发送“\(snippetPendingExecution?.title ?? "代码片段")”？",
            isPresented: Binding(
                get: { snippetPendingExecution != nil },
                set: { if !$0 { snippetPendingExecution = nil } }
            )
        ) {
            Button(snippetPendingExecution?.execute == true ? "执行命令" : "确认插入") {
                guard let request = snippetPendingExecution else { return }
                deliverSnippet(request)
                snippetPendingExecution = nil
            }
            Button("取消", role: .cancel) {
                snippetPendingExecution = nil
            }
        } message: {
            Text("\(snippetPendingExecution?.command ?? "")\n\n命令或控制字符可能立即执行。请确认目标会话及命令内容。")
        }
        .onChange(of: appState.selectedTerminalID) { _, _ in snippetPendingExecution = nil }
        .sheet(isPresented: $showingAppearance, onDismiss: {
            selectedController?.hostView.focusTerminal()
        }) {
            if let selectedController {
                TerminalSessionAppearanceView(
                    profile: selectedController.appearanceProfile,
                    isDark: colorScheme == .dark,
                    onApply: {
                        selectedController.applyAppearance(
                            $0,
                            dark: colorScheme == .dark
                        )
                    },
                    onApplyGlobal: {
                        selectedController.applyGlobalAppearance(
                            dark: colorScheme == .dark
                        )
                    },
                    onReset: {
                        selectedController.resetAppearance(
                            dark: colorScheme == .dark
                        )
                    }
                )
            }
        }
    }

    private func requestSnippet(
        _ snippet: CommandSnippetRecord,
        into sessionID: UUID,
        execute: Bool
    ) {
        guard let controller = registry.controller(for: sessionID), controller.status == .connected else { return }
        let request = TerminalSnippetRequest(
            snippetID: snippet.id, sessionID: sessionID, serverName: controller.serverName,
            title: snippet.title, command: snippet.command, execute: execute
        )
        if request.requiresConfirmation {
            snippetPendingExecution = request
        } else {
            deliverSnippet(request)
        }
    }

    private func deliverSnippet(_ request: TerminalSnippetRequest) {
        guard request.canDeliver(selectedSessionID: appState.selectedTerminalID,
                                 status: registry.controller(for: request.sessionID)?.status) else { return }
        TerminalCommandBus.insert(request.payload, into: request.sessionID)
        snippets.first { $0.id == request.snippetID }?.lastUsedAt = .now
        try? modelContext.save()
    }

    private func tabTitle(for controller: TerminalSessionController) -> String {
        let peers = registry.controllers.filter { $0.serverID == controller.serverID }
        guard peers.count > 1, let index = peers.firstIndex(where: { $0.id == controller.id }) else {
            return controller.serverName
        }
        return "\(controller.serverName) · \(DisplayFormat.integer(index + 1))"
    }
}

struct TerminalSnippetRequest {
    let snippetID: UUID
    let sessionID: UUID
    let serverName: String
    let title: String
    let command: String
    let execute: Bool

    var requiresConfirmation: Bool {
        execute || command.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    var payload: String { command + (execute ? "\n" : "") }

    func canDeliver(selectedSessionID: UUID?, status: TerminalConnectionStatus?) -> Bool {
        selectedSessionID == sessionID && status == .connected
    }
}

struct TerminalInspectorView: View {
    let server: ServerRecord
    @ObservedObject var controller: TerminalSessionController
    @ObservedObject var runtime: ServerRuntimeState
    let snippets: [CommandSnippetRecord]
    let refreshInterval: TimeInterval
    @Binding var selectedTab: String
    let onInsert: (CommandSnippetRecord) -> Void
    let onRun: (CommandSnippetRecord) -> Void
    @State private var search = ""
    @State private var copiedSnippetID: UUID?

    private var state: ServerRenderState { runtime.renderState }
    private var snapshot: ServerSnapshot { state.snapshot }
    private var filteredSnippets: [CommandSnippetRecord] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return snippets.filter {
            term.isEmpty || [$0.title, $0.command, $0.category].contains { $0.localizedCaseInsensitiveContains(term) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: AppleDesign.Spacing.sm) {
                Text("终端检查器").font(.headline).accessibilityAddTraits(.isHeader)
                Text(controller.serverName)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Picker("检查器内容", selection: $selectedTab) {
                    Text("状态").tag("status")
                    Text("代码片段").tag("snippets")
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            .padding(AppleDesign.Spacing.md)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: AppleDesign.Spacing.md) {
                    if selectedTab == "snippets" { snippetContent } else { statusContent }
                }
                .padding(AppleDesign.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.appGround)
    }

    @ViewBuilder private var statusContent: some View {
        HStack {
            Label(controller.status.title, systemImage: "terminal")
                .foregroundStyle(controller.status.displayColor)
            Spacer()
            Text("SSH 会话").foregroundStyle(.secondary)
        }
        .font(.caption)

        if controller.serverID != server.id {
            Text("正在切换服务器…").foregroundStyle(.secondary)
        } else if state.hasSnapshot {
            HStack {
                Text("资源快照").font(.headline)
                Spacer()
                ServerStatusBadge(status: state.status)
            }
            VStack(alignment: .leading, spacing: AppleDesign.Spacing.md) {
                metric("CPU", value: snapshot.cpuUsage, detail: "\(snapshot.coreCount) 核心")
                Divider()
                metric("内存", value: snapshot.memoryUsage,
                       detail: "\(DisplayFormat.bytes(snapshot.memoryUsedBytes)) / \(DisplayFormat.bytes(snapshot.memoryTotalBytes))")
                Divider()
                metric("磁盘", value: snapshot.diskUsage,
                       detail: "\(DisplayFormat.bytes(snapshot.diskUsedBytes)) / \(DisplayFormat.bytes(snapshot.diskTotalBytes))")
            }
            .applePanel()

            VStack(alignment: .leading, spacing: AppleDesign.Spacing.sm) {
                Text("平均负载").font(.headline)
                HStack {
                    load("1 分钟", value: snapshot.load1)
                    load("5 分钟", value: snapshot.load5)
                    load("15 分钟", value: snapshot.load15)
                }
                Divider()
                HStack {
                    Label(DisplayFormat.speed(snapshot.downloadBytesPerSecond), systemImage: "arrow.down")
                    Spacer(minLength: 0)
                    Label(DisplayFormat.speed(snapshot.uploadBytesPerSecond), systemImage: "arrow.up")
                }
                .font(.caption).monospacedDigit()
            }
            .applePanel()

            if !snapshot.topProcesses.isEmpty {
                VStack(alignment: .leading, spacing: AppleDesign.Spacing.sm) {
                    Text("活跃进程 · CPU").font(.headline)
                    ForEach(snapshot.topProcesses.prefix(5)) { process in
                        HStack {
                            Text(process.name).lineLimit(1)
                            Spacer(minLength: AppleDesign.Spacing.sm)
                            Text(DisplayFormat.percent(process.cpu)).monospacedDigit()
                        }
                        .font(.caption)
                    }
                }
                .applePanel()
            }
            TimelineView(.periodic(from: .now, by: 5)) { context in
                VStack(alignment: .leading, spacing: AppleDesign.Spacing.xs) {
                    if !server.enableDashboardMonitor {
                        Label("自动监控已关闭", systemImage: "pause.circle").foregroundStyle(.secondary)
                    }
                    if state.isStale(refreshInterval: refreshInterval, now: context.date) || state.status != .online {
                        Label("当前显示最后一次成功采集的数据", systemImage: "clock.badge.exclamationmark")
                            .foregroundStyle(Color.appWarning)
                    }
                    Text("采集于 \(snapshot.capturedAt.formatted(date: .omitted, time: .standard))")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        } else {
            ContentUnavailableView {
                Label(state.status == .failed ? "资源采集失败" : "暂无资源快照", systemImage: "waveform.path.ecg")
            } description: {
                Text(server.enableDashboardMonitor
                     ? "采集成功后将在这里显示，终端连接与监控状态相互独立。"
                     : "此服务器未开启仪表盘监控，可在机器设置中开启。")
            }
        }
    }

    @ViewBuilder private var snippetContent: some View {
        AppleSearchField(prompt: "搜索代码片段", text: $search)
        if filteredSnippets.isEmpty {
            ContentUnavailableView {
                Label(snippets.isEmpty ? "还没有代码片段" : "没有匹配的片段", systemImage: "curlybraces")
            } description: {
                Text(snippets.isEmpty ? "在侧栏的“代码片段”中保存常用命令，即可在这里使用。" : "试试其他关键词。")
            }
        } else {
            Text("单行命令可插入后编辑；执行或发送多行内容前会再次确认。")
                .font(.caption).foregroundStyle(.secondary)
            AppleUnifiedPanel {
                ForEach(filteredSnippets) { snippet in
                    snippetRow(snippet)
                    if snippet.id != filteredSnippets.last?.id {
                        Divider().padding(.horizontal, AppleDesign.Spacing.md)
                    }
                }
            }
        }
    }

    private func snippetRow(_ snippet: CommandSnippetRecord) -> some View {
        VStack(alignment: .leading, spacing: AppleDesign.Spacing.sm) {
            Text(snippet.title).font(.headline).lineLimit(2)
            Text(snippet.category).font(.caption).foregroundStyle(.secondary)
            Text(snippet.command)
                .font(.caption.monospaced()).lineLimit(4).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: AppleDesign.Spacing.sm) {
                Button(copiedSnippetID == snippet.id ? "已复制" : "复制", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snippet.command, forType: .string)
                    copiedSnippetID = snippet.id
                }
                .labelStyle(.iconOnly)
                .help(copiedSnippetID == snippet.id ? "已复制" : "复制命令")
                Spacer(minLength: 0)
                Button("插入") { onInsert(snippet) }.disabled(controller.status != .connected)
                Button("执行…") { onRun(snippet) }.disabled(controller.status != .connected)
            }
            .controlSize(.regular)
        }
        .padding(AppleDesign.Spacing.md)
    }

    private func metric(_ title: String, value: Double, detail: String) -> some View {
        VStack(alignment: .leading, spacing: AppleDesign.Spacing.xs) {
            HStack {
                Text(title).font(.callout.weight(.medium))
                Spacer()
                Text(DisplayFormat.percent(value)).font(.headline).monospacedDigit()
            }
            ProgressView(value: min(100, max(0, value)), total: 100).tint(.accentColor)
            Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private func load(_ title: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: AppleDesign.Spacing.xxs) {
            Text(value, format: .number.precision(.fractionLength(2))).font(.callout.weight(.medium))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .monospacedDigit().frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TerminalSessionPane: View {
    @ObservedObject var controller: TerminalSessionController
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("hideIPInformation") private var hideIPInformation = false
    let onReconnect: () -> Void

    private var endpoint: String {
        let host = hideIPInformation ? "[IP]" : controller.config.host
        return "\(controller.config.username)@\(host):\(controller.config.port)"
    }

    private var theme: TerminalColorTheme {
        TerminalThemeCatalog.shared.theme(
            id: colorScheme == .dark
                ? controller.appearanceProfile.darkThemeID
                : controller.appearanceProfile.lightThemeID,
            dark: colorScheme == .dark
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            PersistentTerminalView(controller: controller)
                // The controller owns the persistent NSView; a different session must mount its own view.
                .id(controller.id)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .background(theme.background.color)

            if controller.status == .disconnected || controller.status == .failed {
                HStack(spacing: AppleDesign.Spacing.sm) {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(controller.status.displayColor)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: AppleDesign.Spacing.xxs) {
                        Text(controller.lastError ?? "终端连接已断开")
                            .font(.callout.weight(.medium))
                            .lineLimit(2)
                            .help(controller.lastError ?? "终端连接已断开")
                        Text("重新连接将创建新的 Shell 会话。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: AppleDesign.Spacing.sm)
                    Button("重新连接", action: onReconnect)
                        .buttonStyle(.borderedProminent)
                }
                .padding(AppleDesign.Spacing.sm)
                .background(Color.appSurface)
            }

            Divider()
            HStack(spacing: AppleDesign.Spacing.sm) {
                Label {
                    Text(controller.status.title)
                } icon: {
                    Circle()
                        .fill(controller.status.displayColor)
                        .frame(width: 7, height: 7)
                }
                .fixedSize()
                Text(endpoint)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(endpoint)
                    .textSelection(.enabled)
                Spacer(minLength: AppleDesign.Spacing.xs)
                Text("\(DisplayFormat.integer(Int(controller.appearanceProfile.fontSize))) pt")
                    .monospacedDigit()
                    .help("⌘+ / ⌘= 放大，⌘− 缩小，⌘0 恢复；更多快捷键见菜单栏“终端”")
                    .accessibilityLabel("终端字号 \(Int(controller.appearanceProfile.fontSize)) 点")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, AppleDesign.Spacing.sm)
            .frame(height: 30)
            .background(Color.appGround)
        }
    }
}

private extension TerminalConnectionStatus {
    var displayColor: Color {
        switch self {
        case .connecting: .appWarning
        case .connected: .appLive
        case .disconnected: .secondary
        case .failed: .appError
        }
    }
}

private struct PersistentTerminalView: NSViewRepresentable {
    @ObservedObject var controller: TerminalSessionController
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let host = controller.hostView
        host.removeFromSuperview()
        host.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        host.applyAppearance(
            controller.appearanceProfile,
            dark: colorScheme == .dark
        )
        // SwiftUI owns a fresh container; the session retains only its terminal and scrollback.
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        controller.hostView.applyAppearance(
            controller.appearanceProfile,
            dark: colorScheme == .dark
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        // The terminal has no intrinsic size; an unspecified axis must not reuse its previous frame.
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }
}

private struct TerminalTab: View {
    @ObservedObject var controller: TerminalSessionController
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("hideIPInformation") private var hideIPInformation = false
    let title: String
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    private var theme: TerminalColorTheme {
        TerminalThemeCatalog.shared.theme(
            id: colorScheme == .dark
                ? controller.appearanceProfile.darkThemeID
                : controller.appearanceProfile.lightThemeID,
            dark: colorScheme == .dark
        )
    }

    private var tooltip: String {
        let host = hideIPInformation ? "[IP]" : controller.config.host
        return "\(title) · \(controller.status.title)\n\(controller.config.username)@\(host):\(controller.config.port)"
    }

    var body: some View {
        HStack(spacing: AppleDesign.Spacing.xxs) {
            Button(action: onSelect) {
                HStack(spacing: AppleDesign.Spacing.xs) {
                    Circle()
                        .fill(controller.status.displayColor)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .padding(.leading, AppleDesign.Spacing.sm)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("切换到 \(title) 终端，\(controller.status.title)")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(isSelected ? selectedForeground.opacity(0.65) : Color.secondary)
            .padding(.trailing, AppleDesign.Spacing.xxs)
            .accessibilityLabel("关闭 \(title) 终端")
            .help("关闭 \(title) 终端")
        }
        .foregroundStyle(isSelected ? selectedForeground : Color.primary)
        .frame(width: 190, height: 40)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: AppleDesign.Radius.chip,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: AppleDesign.Radius.chip,
                style: .continuous
            )
            .fill(tabBackground)
        )
        .overlay {
            UnevenRoundedRectangle(
                topLeadingRadius: AppleDesign.Radius.chip,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: AppleDesign.Radius.chip,
                style: .continuous
            )
            .stroke(Color.appHairline.opacity(isSelected ? 0.5 : 0))
        }
        .overlay(alignment: .bottom) {
            if isSelected {
                Rectangle()
                    .fill(Color.appAccent)
                    .frame(height: 2)
            }
        }
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : AppleDesign.quick, value: isHovering)
        .help(tooltip)
    }

    private var selectedForeground: Color {
        theme.foreground.color
    }

    private var tabBackground: Color {
        if isSelected {
            return theme.background.color
        }
        return isHovering ? Color.appHover : .clear
    }
}

enum TerminalCommandBus {
    static let notification = Notification.Name("ServerDash.InsertTerminalCommand")

    static func insert(_ command: String, into sessionID: UUID) {
        NotificationCenter.default.post(
            name: notification,
            object: nil,
            userInfo: ["sessionID": sessionID, "command": command]
        )
    }
}
