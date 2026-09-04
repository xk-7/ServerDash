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
    @State private var snippetPendingExecution: CommandSnippetRecord?
    @State private var showingAppearance = false

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
                                    insert(snippet, into: selectedSession.id, execute: false)
                                }
                                Button("执行…", systemImage: "play") {
                                    snippetPendingExecution = snippet
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
        .focusedSceneValue(\.terminalShortcuts, shortcutActions)
        .confirmationDialog(
            "执行“\(snippetPendingExecution?.title ?? "代码片段")”？",
            isPresented: Binding(
                get: { snippetPendingExecution != nil },
                set: { if !$0 { snippetPendingExecution = nil } }
            )
        ) {
            Button("执行命令") {
                guard let snippet = snippetPendingExecution,
                      let selectedSession else { return }
                insert(snippet, into: selectedSession.id, execute: true)
                snippetPendingExecution = nil
            }
            Button("取消", role: .cancel) {
                snippetPendingExecution = nil
            }
        } message: {
            Text(snippetPendingExecution?.command ?? "")
        }
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

    private func insert(
        _ snippet: CommandSnippetRecord,
        into sessionID: UUID,
        execute: Bool
    ) {
        TerminalCommandBus.insert(
            snippet.command + (execute ? "\n" : ""),
            into: sessionID
        )
        snippet.lastUsedAt = .now
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
