import SwiftData
import SwiftTerm
import SwiftUI
import UIKit

struct MobileSessionsView: View {
    @EnvironmentObject private var runtime: MobileRuntime
    var body: some View {
        MobileWorkspaceContent(workspace: runtime.terminalWorkspace)
            .navigationTitle("会话工作区")
    }
}

private struct MobileWorkspaceContent: View {
    @EnvironmentObject private var runtime: MobileRuntime
    @ObservedObject var workspace: TerminalWorkspace
    @State private var showingServerPicker = false
    @State private var pendingClose: [WorkspaceTab] = []
    @Query(sort: \ServerRecord.name) private var servers: [ServerRecord]
    @Query private var identities: [IdentityRecord]
    @Query private var keys: [SSHKeyRecord]
    @Query private var routes: [ConnectionRouteRecord]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                WorkspaceTabStrip(workspace: workspace, onSelect: { workspace.select(tab: $0.id) }, onClose: close, onCloseMultiple: requestClose)
                Button { showingServerPicker = true } label: { Image(systemName: "server.rack").frame(width: 44, height: 44) }.accessibilityLabel("选择机器")
                Menu {
                    Button("整理为网格（最多 4×4）") { workspace.arrangeGrid() }.disabled(workspace.selectedTab?.kind != .terminal)
                    Divider()
                    ForEach(servers) { server in
                        Menu(server.displayName) {
                            Button("SSH 新标签") { open(server) }
                            Button("SFTP 新标签") { runtime.openSFTP(config: config(server), initialPath: server.defaultSFTPPath) }
                            Button("监控新标签") { workspace.add(serverID: server.id, title: server.displayName, kind: .monitor) }
                            Divider()
                            Button("右侧分屏") { open(server, axis: .right) }.disabled(!canSplit)
                            Button("下方分屏") { open(server, axis: .below) }.disabled(!canSplit)
                        }
                    }
                } label: { Image(systemName: "plus").frame(width: 44, height: 44) }
                .accessibilityLabel("新建标签或分屏")
            }
            ZStack {
                if workspace.tabs.isEmpty {
                    ContentUnavailableView {
                        Label("没有会话", systemImage: "terminal")
                    } description: {
                        Text("选择机器打开终端；使用 + 新建独立标签或分屏。")
                    } actions: {
                        Button("选择机器") { showingServerPicker = true }.buttonStyle(.borderedProminent)
                    }
                }
                // Only the selected page is mounted; controllers own foreground work.
                ForEach(workspace.tabs.filter { ($0.kind == .sftp || $0.kind == .monitor) && $0.id == workspace.selectedTabID }) { tab in
                    if let server = servers.first(where: { $0.id == tab.serverID }) {
                        Group {
                            if tab.kind == .sftp { if let controller = runtime.fileControllers[tab.activePane] { MobileSFTPView(controller: controller, reconnect: { controller.reconnect(config: config(server)) }) } }
                            else if tab.kind == .monitor { MobileServerDetailView(server: server) }
                        }
                        .opacity(workspace.selectedTabID == tab.id ? 1 : 0)
                        .allowsHitTesting(workspace.selectedTabID == tab.id)
                        .accessibilityHidden(workspace.selectedTabID != tab.id)
                    }
                }
                if let tab = workspace.selectedTab, tab.kind == .terminal {
                    TerminalSplitLayout(node: workspace.renderedLayout ?? tab.layout, resize: { workspace.resize(divider: $0, ratio: $1) }) { id in
                        if let controller = runtime.terminalControllers[id] {
                            MobileTerminalPane(controller: controller, active: id == tab.activePane,
                                select: { workspace.select(pane: id) },
                                zoom: { workspace.toggleZoom(pane: id) },
                                close: { runtime.closeTerminal(sessionID: id) },
                                shortcut: handleShortcut,
                                reconnect: { if let server = servers.first(where: { $0.id == controller.config.id }) { controller.reconnect(config: config(server)) } })
                        }
                    }
                }
            }
        }
        .confirmationDialog("取消传输并关闭所选标签？", isPresented: Binding(get: { !pendingClose.isEmpty }, set: { if !$0 { pendingClose = [] } })) {
            Button("取消传输并关闭", role: .destructive) { runtime.closeWorkspaceTabs(pendingClose); pendingClose = [] }
            Button("保留会话", role: .cancel) { pendingClose = [] }
        } message: { Text("进行中的传输将取消，需要从头重新传输。") }
        .sheet(isPresented: $showingServerPicker) {
            SessionServerPicker(servers: servers) { server in
                runtime.openSession(SessionOpenRequest(serverID: server.id), config: config(server))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: workspace.selectedTabID) { _, _ in focusActive() }
    }

    private var canSplit: Bool { workspace.activePane.map(workspace.canSplit) ?? false }
    private func config(_ server: ServerRecord) -> ServerConnectionConfig {
        ConnectionConfigResolver.resolve(server: server, identities: identities, keys: keys, routes: routes)
    }
    private func open(_ server: ServerRecord, axis: TerminalSplitAxis? = nil) {
        let target = workspace.activePane
        if axis != nil && !canSplit { return }
        let policy: SessionOpenRequest.Policy = if let axis, let target { .split(pane: target, axis: axis) } else { .newTab }
        runtime.openSession(SessionOpenRequest(serverID: server.id, policy: policy), config: config(server))
    }
    private func close(_ tab: WorkspaceTab) { requestClose([tab]) }
    private func requestClose(_ tabs: [WorkspaceTab]) {
        if tabs.contains(where: { tab in tab.layout.panes.contains { runtime.fileControllers[$0]?.hasActiveTransfer == true } }) {
            pendingClose = tabs
        } else { runtime.closeWorkspaceTabs(tabs) }
    }
    private func focusActive() {
        guard let id = workspace.activePane, let controller = runtime.terminalControllers[id] else { return }
        _ = controller.surface.terminal.becomeFirstResponder()
    }
    private func handleShortcut(_ key: String) {
        switch key {
        case "next": workspace.advance(1); focusActive()
        case "previous": workspace.advance(-1); focusActive()
        case "close": if let id = workspace.activePane { runtime.closeTerminal(sessionID: id) }
        case "find":
            if let id = workspace.activePane { runtime.terminalControllers[id]?.tools.searchVisible.toggle() }
        case "right", "below":
            guard let id = workspace.activePane, let controller = runtime.terminalControllers[id],
                  let server = servers.first(where: { $0.id == controller.config.id }) else { return }
            open(server, axis: key == "right" ? .right : .below)
        default: break
        }
    }
}

private struct MobileTerminalPane: View {
    @ObservedObject var controller: MobileTerminalController
    let active: Bool
    let select: () -> Void
    let zoom: () -> Void
    let close: () -> Void
    let shortcut: (String) -> Void
    let reconnect: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { select(); _ = controller.surface.terminal.becomeFirstResponder() } label: {
                    VStack(alignment: .leading) {
                        Text(controller.config.name).font(.caption.weight(.semibold)).lineLimit(1)
                        Text(controller.status.title).font(.caption2).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                Button(action: zoom) { Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 44, height: 44) }
                    .accessibilityLabel("放大或还原面板")
                Button(action: close) { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .accessibilityLabel("关闭面板")
            }.padding(.leading, 8).buttonStyle(.plain)
                .background(active ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1))
            if active {
                TerminalToolsBar(tools: controller.tools, connected: controller.status == .connected) {
                    controller.send(Data($0.utf8))
                }
            }
            ZStack {
                MobileTerminalRepresentable(controller: controller, onFocus: select, shortcut: shortcut)
                    .id(controller.id).background(.black)
                if controller.status != .connected {
                    VStack(spacing: 8) {
                        if controller.status == .connecting { ProgressView() }
                        Text(controller.status.title).font(.headline)
                        if let error = controller.lastError { Text(error).font(.caption).lineLimit(4) }
                        if controller.status != .connecting {
                            Button("重新连接", action: reconnect).buttonStyle(.borderedProminent)
                        }
                    }.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).padding(8)
                }
            }
            if active { keyboardBar }
        }
        .overlay { Rectangle().stroke(active ? Color.accentColor : .clear, lineWidth: 1).allowsHitTesting(false) }
        .task { await controller.startIfNeeded() }
    }
    private var keyboardBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                key("Esc", [27]); key("Tab", [9]); key("Ctrl-C", [3])
                key("↑", [27, 91, 65]); key("↓", [27, 91, 66])
                key("←", [27, 91, 68]); key("→", [27, 91, 67])
                Button("粘贴") {
                    controller.surface.terminal.paste(nil)
                }.frame(minWidth: 50, minHeight: 44)
            }.padding(.horizontal, 8)
        }.frame(height: 46).background(.bar).disabled(controller.status != .connected)
    }
    private func key(_ label: String, _ bytes: [UInt8]) -> some View {
        Button(label) { controller.send(Data(bytes)) }.font(.caption.monospaced()).frame(minWidth: 44, minHeight: 44)
    }
}

private struct MobileTerminalRepresentable: UIViewRepresentable {
    @ObservedObject var controller: MobileTerminalController
    let onFocus: () -> Void
    let shortcut: (String) -> Void
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        let terminal = controller.surface.terminal
        terminal.removeFromSuperview()
        terminal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: container.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        terminal.onFocus = onFocus
        terminal.onShortcut = shortcut
        return container
    }
    func updateUIView(_ view: UIView, context: Context) {
        controller.surface.terminal.onFocus = onFocus
        controller.surface.terminal.onShortcut = shortcut
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }
}

/// Retained by the controller rather than a SwiftUI coordinator: preserves scrollback while unmounted.
@MainActor
final class MobileTerminalSurface: NSObject, @preconcurrency TerminalViewDelegate {
    weak var controller: MobileTerminalController?
    let terminal = WorkspaceMobileTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
    init(controller: MobileTerminalController) {
        self.controller = controller
        super.init()
        terminal.terminalDelegate = self
        terminal.nativeBackgroundColor = .black
        terminal.nativeForegroundColor = UIColor(white: 0.9, alpha: 1)
        terminal.optionAsMetaKey = true
        terminal.allowMouseReporting = true
        terminal.accessibilityLabel = "远程终端"
        controller.tools.attach(terminal)
    }
    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) { controller?.send(Data(data)) }
    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
        controller?.resize(.init(columns: max(1, newCols), rows: max(1, newRows),
                                 pixelWidth: Int(source.bounds.width), pixelHeight: Int(source.bounds.height)))
    }
    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
    func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
    func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return }
        UIApplication.shared.open(url)
    }
    func bell(source: SwiftTerm.TerminalView) { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
        if let text = String(data: content, encoding: .utf8) { UIPasteboard.general.string = text }
    }
    func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
}

final class WorkspaceMobileTerminalView: SwiftTerm.TerminalView {
    var onFocus: (() -> Void)?
    var onShortcut: ((String) -> Void)?
    override func layoutSubviews() {
        // SwiftUI briefly proposes zero while reparenting a retained terminal. Resizing
        // the emulator to zero then back can discard its visible buffer.
        guard bounds.width >= 40, bounds.height >= 20 else { return }
        super.layoutSubviews()
    }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onFocus?() }
        return result
    }
    override var keyCommands: [UIKeyCommand]? {
        let definitions: [(String, UIKeyModifierFlags, String)] = [
            ("\t", .control, "next"), ("\t", [.control, .shift], "previous"),
            ("d", [.control, .shift], "right"), ("e", [.control, .shift], "below"),
            ("w", [.control, .shift], "close"), ("f", .control, "find")
        ]
        return definitions.map { input, modifiers, action in
            let command = UIKeyCommand(title: "", action: #selector(workspaceKey(_:)), input: input, modifierFlags: modifiers, propertyList: action)
            command.wantsPriorityOverSystemBehavior = true
            return command
        } + (super.keyCommands ?? [])
    }
    @objc private func workspaceKey(_ command: UIKeyCommand) {
        guard window != nil, isFirstResponder, let action = command.propertyList as? String else { return }
        onShortcut?(action)
    }
}
