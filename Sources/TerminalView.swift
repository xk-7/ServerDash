import AppKit
import SwiftData
import SwiftUI

struct TerminalWorkspaceView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appState: AppState
    @Query(sort: \CommandSnippetRecord.title) private var snippets: [CommandSnippetRecord]
    @State private var snippetPendingExecution: CommandSnippetRecord?
    @State private var showingAppearance = false

    let server: ServerRecord

    private var selectedSession: TerminalSession? {
        appState.terminalSessions.first { $0.id == appState.selectedTerminalID }
    }

    private var selectedController: TerminalSessionController? {
        guard let selectedSession else { return nil }
        return appState.terminalRegistry.controller(for: selectedSession.id)
    }

    private var selectedTheme: TerminalColorTheme? {
        guard let selectedController else { return nil }
        return TerminalThemeCatalog.shared.theme(
            id: colorScheme == .dark
                ? selectedController.appearanceProfile.darkThemeID
                : selectedController.appearanceProfile.lightThemeID,
            dark: colorScheme == .dark
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppleDesign.Spacing.xs) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 3) {
                        ForEach(appState.terminalSessions) { session in
                            TerminalTab(
                                session: session,
                                isSelected: session.id == appState.selectedTerminalID,
                                theme: theme(for: session),
                                onSelect: {
                                    appState.selectTerminal(session)
                                },
                                onClose: {
                                    appState.closeTerminal(session, context: modelContext)
                                }
                            )
                        }
                    }
                    .padding(.top, 5)
                }
                .scrollClipDisabled()

                Divider()
                    .frame(height: 20)

                Button {
                    appState.newTerminal(for: server)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .frame(width: 28, height: 28)
                .keyboardShortcut("t", modifiers: .command)
                .help("新建 SSH 标签页")
                if let selectedController {
                    Menu {
                        Button("终端外观…", systemImage: "paintpalette") {
                            showingAppearance = true
                        }
                        Divider()
                        Button("增大字号") {
                            selectedController.changeFontSize(
                                by: 1,
                                dark: colorScheme == .dark
                            )
                        }
                        .keyboardShortcut("+", modifiers: .command)
                        Button("减小字号") {
                            selectedController.changeFontSize(
                                by: -1,
                                dark: colorScheme == .dark
                            )
                        }
                        .keyboardShortcut("-", modifiers: .command)
                        Button("恢复初始字号") {
                            selectedController.resetFontSize(
                                dark: colorScheme == .dark
                            )
                        }
                        .keyboardShortcut("0", modifiers: .command)
                    } label: {
                        Image(systemName: "paintpalette")
                    }
                    .menuStyle(.borderlessButton)
                    .controlSize(.small)
                    .frame(width: 28, height: 28)
                    .help("终端外观")
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
                    .controlSize(.small)
                    .frame(width: 28, height: 28)
                    .help("插入代码片段")
                }
            }
            .frame(height: 38)
            .padding(.horizontal, AppleDesign.Spacing.xs)
            .background(AppleChromeBackground())

            Rectangle()
                .fill(Color.appHairline.opacity(0.55))
                .frame(height: 1)

            if let selectedSession,
               let controller = appState.terminalRegistry.controller(for: selectedSession.id) {
                PersistentTerminalView(controller: controller)
                    .background(selectedTheme?.background.color ?? Color.black)
                if selectedSession.status == .disconnected || selectedSession.status == .failed {
                    reconnectBanner(selectedSession)
                }
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
        .sheet(isPresented: $showingAppearance) {
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

    private func reconnectBanner(_ session: TerminalSession) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.status.title)
                    .font(.headline)
                Text(session.lastError ?? "重连会建立新的 Shell，不会恢复远端前台进程。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("重新连接") {
                appState.reconnectTerminal(session)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(AppleDesign.Spacing.md)
        .background(Color.appGround)
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

    private func theme(for session: TerminalSession) -> TerminalColorTheme? {
        guard let controller = appState.terminalRegistry.controller(for: session.id) else {
            return nil
        }
        return TerminalThemeCatalog.shared.theme(
            id: colorScheme == .dark
                ? controller.appearanceProfile.darkThemeID
                : controller.appearanceProfile.lightThemeID,
            dark: colorScheme == .dark
        )
    }
}

private struct PersistentTerminalView: NSViewRepresentable {
    @ObservedObject var controller: TerminalSessionController
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> TerminalHostView {
        controller.hostView.applyAppearance(
            controller.appearanceProfile,
            dark: colorScheme == .dark
        )
        return controller.hostView
    }

    func updateNSView(_ nsView: TerminalHostView, context: Context) {
        nsView.applyAppearance(
            controller.appearanceProfile,
            dark: colorScheme == .dark
        )
    }
}

private struct TerminalTab: View {
    let session: TerminalSession
    let isSelected: Bool
    let theme: TerminalColorTheme?
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    private var statusColor: Color {
        switch session.status {
        case .connecting: .appWarning
        case .connected: .appLive
        case .disconnected: .secondary
        case .failed: .appError
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelect) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text(session.serverName)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("切换到 \(session.serverName) 终端，\(session.status.title)")
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(isSelected ? selectedForeground.opacity(0.65) : Color.secondary)
            .frame(width: 18, height: 18)
            .opacity(isSelected || isHovering ? 1 : 0)
            .accessibilityLabel("关闭 \(session.serverName) 终端")
        }
        .foregroundStyle(isSelected ? selectedForeground : Color.primary)
        .padding(.horizontal, 10)
        .frame(minWidth: 110, idealWidth: 145, maxWidth: 190, minHeight: 32)
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
                    .fill(theme?.background.color ?? Color.appSurface)
                    .frame(height: 1)
                    .offset(y: 1)
            }
        }
        .onHover { isHovering = $0 }
        .animation(AppleDesign.quick, value: isHovering)
        .help("\(session.serverName) · \(session.status.title)")
    }

    private var selectedForeground: Color {
        theme?.foreground.color ?? .primary
    }

    private var tabBackground: Color {
        if isSelected {
            return theme?.background.color ?? .appSurface
        }
        return isHovering ? Color.primary.opacity(0.06) : .clear
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
