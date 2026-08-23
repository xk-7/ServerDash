import AppKit
import SwiftData
import SwiftTerm
import SwiftUI

struct TerminalWorkspaceView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appState: AppState
    @Query(sort: \CommandSnippetRecord.title) private var snippets: [CommandSnippetRecord]
    @State private var snippetPendingExecution: CommandSnippetRecord?

    let server: ServerRecord

    private var selectedSession: TerminalSession? {
        appState.terminalSessions.first { $0.id == appState.selectedTerminalID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(appState.terminalSessions) { session in
                            TerminalTab(
                                session: session,
                                isSelected: session.id == appState.selectedTerminalID,
                                onSelect: {
                                    appState.selectedTerminalID = session.id
                                },
                                onClose: {
                                    appState.closeTerminal(session)
                                }
                            )
                        }
                    }
                }
                Button {
                    appState.newTerminal(for: server)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(CompactActionButtonStyle())
                .frame(minWidth: 44, minHeight: 44)
                .keyboardShortcut("t", modifiers: .command)
                .help("新建 SSH 标签页")
                .accessibilityLabel("新建 SSH 标签页")
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
                    .frame(minWidth: 44, minHeight: 44)
                    .help("插入代码片段")
                    .accessibilityLabel("代码片段")
                }
            }
            .padding(.horizontal, 12)
            .background(AppleChromeBackground())

            Divider()

            if let selectedSession {
                SSHProcessTerminalView(
                    sessionID: selectedSession.id,
                    config: selectedSession.config
                )
                    .id(selectedSession.id)
                    .background(Color.black)
            } else {
                VStack(spacing: 0) {
                    ServerLocationMapView(server: server)
                        .frame(height: 260)
                        .padding(AppleDesign.Spacing.lg)

                    Divider()

                    ContentUnavailableView {
                        Label("没有打开的终端", systemImage: "terminal")
                    } description: {
                        Text("地图显示服务器公网地址的大致位置。创建标签页以连接 \(server.name)。")
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
}

private struct TerminalTab: View {
    let session: TerminalSession
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Button(action: onSelect) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.appLive)
                        .frame(width: 6, height: 6)
                    Text(session.serverName)
                        .font(.system(size: 11, weight: .semibold))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("切换到 \(session.serverName) 终端")
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .frame(minWidth: 24, minHeight: 24)
            .accessibilityLabel("关闭 \(session.serverName) 终端")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: AppleDesign.Radius.chip, style: .continuous)
                .fill(isSelected ? Color.appSurface : Color.primary.opacity(0.04))
        )
        .overlay {
            RoundedRectangle(cornerRadius: AppleDesign.Radius.chip, style: .continuous)
                .stroke(Color.primary.opacity(isSelected ? 0.10 : 0.04))
        }
        .frame(minHeight: 36)
    }
}

private struct SSHProcessTerminalView: NSViewRepresentable {
    let sessionID: UUID
    let config: ServerConnectionConfig
    @AppStorage("terminalFontSize") private var terminalFontSize = 13.0
    @AppStorage("terminalFontName") private var terminalFontName = "SF Mono"

    func makeNSView(context: Context) -> TerminalHostView {
        TerminalHostView(
            sessionID: sessionID,
            config: config,
            fontName: terminalFontName,
            fontSize: terminalFontSize
        )
    }

    func updateNSView(_ nsView: TerminalHostView, context: Context) {
        nsView.updateFont(name: terminalFontName, size: terminalFontSize)
    }
}

private final class TerminalHostView: NSView {
    private let terminalView = LocalProcessTerminalView(frame: .zero)
    private let sessionID: UUID
    private let config: ServerConnectionConfig
    private var didStart = false
    private var commandObserver: NSObjectProtocol?

    init(sessionID: UUID, config: ServerConnectionConfig, fontName: String, fontSize: Double) {
        self.sessionID = sessionID
        self.config = config
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        terminalView.autoresizingMask = [.width, .height]
        terminalView.configureNativeColors()
        addSubview(terminalView)
        updateFont(name: fontName, size: fontSize)
        commandObserver = NotificationCenter.default.addObserver(
            forName: TerminalCommandBus.notification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  notification.userInfo?["sessionID"] as? UUID == self.sessionID,
                  let command = notification.userInfo?["command"] as? String else {
                return
            }
            self.terminalView.send(txt: command)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let commandObserver {
            NotificationCenter.default.removeObserver(commandObserver)
        }
        if didStart {
            terminalView.terminate()
        }
    }

    override func layout() {
        super.layout()
        terminalView.frame = bounds
        guard !didStart, bounds.width > 40, bounds.height > 40 else { return }
        didStart = true
        startSSH()
    }

    func updateFont(name: String, size: Double) {
        terminalView.font = NSFont(name: name, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private func startSSH() {
        let arguments = SSHSupport.arguments(
            for: config,
            strictHostChecking: "ask"
        )
        let environment = SSHSupport.environment(for: config)
            .map { "\($0.key)=\($0.value)" }
            .sorted()

        terminalView.startProcess(
            executable: "/usr/bin/ssh",
            args: arguments,
            environment: environment,
            execName: "ssh"
        )
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
