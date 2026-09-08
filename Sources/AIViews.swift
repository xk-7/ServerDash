import AppKit
import SwiftUI

extension Notification.Name {
    static let terminalShowAI = Notification.Name("ServerDash.terminal.showAI")
}

struct AIAssistantPanel: View {
    @ObservedObject var controller: TerminalSessionController
    var isActive: () -> Bool = { true }
    var body: some View {
        AIChatView(mode: .ops, controller: controller, pane: controller.ai, isActive: isActive)
            .id(controller.id)
    }
}

struct AIGeneralWindow: View {
    @StateObject private var pane = AIPaneState()
    var body: some View {
        AIChatView(mode: .general, controller: nil, pane: pane)
            .frame(minWidth: 480, minHeight: 520)
    }
}

private struct AIPendingCommand: Identifiable {
    var id = UUID()
    let target: AICommandTarget
    let command: String
}

struct AIChatView: View {
    let mode: AIMode
    let controller: TerminalSessionController?
    @ObservedObject var pane: AIPaneState
    @ObservedObject var workspace = AIWorkspace.shared
    @ObservedObject var settings = AISettings.shared
    var isActive: () -> Bool = { true }
    @Environment(\.openWindow) private var openWindow
    @State private var showingSettings = false
    @State private var showingConversations = false
    @State private var showingConsent = false
    @State private var contextPreview: String?
    @State private var pendingCommand: AIPendingCommand?
    @State private var confirmingClear = false
    @State private var deletingMessage: UUID?
    @State private var followsOutput = true

    private var conversationID: UUID? {
        mode == .ops ? pane.conversationID : workspace.generalConversationID
    }
    private var chat: AIConversation? { workspace.conversation(conversationID) }
    private var busy: Bool { conversationID.map { workspace.running.contains($0) } ?? false }
    private var draft: Binding<String> {
        mode == .ops ? $pane.draft : $workspace.generalDraft
    }
    private var authorized: Bool {
        guard let controller, mode == .ops else { return false }
        return pane.isAuthorized(generation: controller.connectionGeneration, settings: settings.revision)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = workspace.storageError {
                HStack(alignment: .top) {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption)
                    Button("管理") { showingConversations = true }
                    if !workspace.loaded { Button("重试") { Task { await workspace.load() } } }
                }.padding(10).foregroundStyle(Color.appWarning)
            }
            messageList
            Divider()
            composer
        }
        .background(Color.appGround)
        .task {
            await workspace.load()
            if let controller { workspace.prepare(controller) }
        }
        .onChange(of: workspace.loaded) { _, loaded in if loaded, let controller { workspace.prepare(controller) } }
        .onChange(of: settings.revision) { _, _ in pane.revoke(); if let id = conversationID { workspace.stop(id) } }
        .onChange(of: pane.authorizedGeneration) { _, _ in pendingCommand = nil }
        .onChange(of: conversationID) { _, _ in pendingCommand = nil }
        .sheet(isPresented: $showingSettings) {
            VStack(spacing: 0) {
                HStack { Text("AI 设置").font(.headline); Spacer(); Button("完成") { showingSettings = false } }.padding()
                AISettingsView()
            }.frame(width: 650, height: 570)
        }
        .sheet(isPresented: $showingConversations) {
            AIConversationBrowser(mode: mode, serverID: controller?.serverID, paneID: controller?.id) { id in
                if mode == .ops {
                    pane.invalidate(); pane.conversationID = id; pane.draft = ""
                    if let controller { workspace.prepare(controller) }
                } else { workspace.generalConversationID = id; workspace.generalDraft = "" }
            }
        }
        .sheet(isPresented: Binding(get: { contextPreview != nil }, set: { if !$0 { contextPreview = nil } })) {
            VStack(alignment: .leading, spacing: 12) {
                Text("终端附件预览").font(.headline)
                Text("最多 16 KiB；发送时重新采集当前可见屏幕。可能包含密码、令牌或业务数据，不提供可靠自动脱敏。关闭自动附件后仍可手动粘贴内容。").font(.caption).foregroundStyle(.secondary)
                ScrollView { Text(contextPreview ?? "").font(.callout.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack { Spacer(); Button("完成") { contextPreview = nil }.keyboardShortcut(.defaultAction) }
            }.padding(20).frame(width: 640, height: 480)
        }
        .alert("允许向 AI 服务附带终端上下文？", isPresented: $showingConsent) {
            Button("允许此连接") {
                if let controller { pane.authorize(generation: controller.connectionGeneration, settings: settings.revision) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅在点击发送时，将“\(controller?.serverName ?? "")”的服务器地址、用户名及当前可见输出发送至 \(settings.configuration.baseURL)。不会读取原始按键、隐藏密码、Keychain 或整段历史，但可见内容仍可能包含秘密。附件本身不随对话存储；AI 回复可能复述内容。重连或修改 API 设置后需重新授权。")
        }
        .confirmationDialog("执行 AI 建议的命令？", isPresented: Binding(get: { pendingCommand != nil }, set: { if !$0 { pendingCommand = nil } })) {
            Button("确认执行") { executePending() }
            Button("取消", role: .cancel) { pendingCommand = nil }
        } message: {
            Text("目标：\(pendingCommand?.target.serverName ?? "")\n\(pendingCommand?.command ?? "")\n\n请确认终端正停留在空的 Shell 提示符，而非密码输入、编辑器或其他程序中。命令将立即提交；AI 建议未经实际验证。")
        }
        .confirmationDialog("清空此对话的所有消息？", isPresented: $confirmingClear) {
            Button("清空消息", role: .destructive) { if let id = conversationID { workspace.clear(id) } }
        }
        .confirmationDialog("删除这条消息？", isPresented: Binding(get: { deletingMessage != nil }, set: { if !$0 { deletingMessage = nil } })) {
            Button("删除消息", role: .destructive) {
                if let message = deletingMessage, let id = conversationID { workspace.deleteMessage(message, in: id) }
                deletingMessage = nil
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("AI 助手", systemImage: "sparkles").font(.headline)
                Spacer()
                Button { showingConversations = true } label: { Image(systemName: "bubble.left.and.bubble.right") }
                    .help("对话管理（最多 50 个）").accessibilityLabel("AI 对话管理")
                Button { newConversation() } label: { Image(systemName: "square.and.pencil") }
                    .help("新建对话").accessibilityLabel("新建 AI 对话").disabled(!workspace.loaded)
                Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                    .help("AI 设置").accessibilityLabel("AI 设置")
            }.buttonStyle(.borderless)
            HStack {
                Text(mode.title).font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                if mode == .ops {
                    Text(controller?.serverName ?? "").font(.caption).lineLimit(1)
                    Spacer()
                    Button("通用对话 ↗") { openWindow(id: "ai-general") }.font(.caption).buttonStyle(.borderless)
                } else {
                    Text("不读取终端上下文").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !settings.configuration.model.isEmpty {
                Text(settings.configuration.model).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }.padding(12)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if chat?.messages.isEmpty != false {
                        VStack(alignment: .leading, spacing: 14) {
                            Image(systemName: mode == .ops ? "terminal" : "bubble.left.and.text.bubble.right")
                                .font(.system(size: 28)).foregroundStyle(Color.accentColor)
                            Text(mode == .ops ? "把问题带到终端旁边" : "独立思考，随时提问").font(.title3.weight(.semibold))
                            Text("生成命令、解释参数、分析日志或编写脚本。回复仅供参考，执行前请检查。").font(.callout).foregroundStyle(.secondary)
                            ForEach(["生成 Shell 命令", "解释命令", "分析错误日志", "编写 Bash / Python / Ansible 脚本"], id: \.self) { title in
                                Button(title) { draft.wrappedValue = title + "：" }.buttonStyle(.bordered)
                            }
                        }.padding(.vertical, 24)
                    }
                    ForEach(chat?.messages ?? []) { message in
                        messageRow(message)
                    }
                    if let id = conversationID, let error = workspace.errors[id] {
                        Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(Color.appWarning)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }.padding(12)
            }
            .onChange(of: chat?.messages.last?.text) { _, _ in if followsOutput { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: chat?.messages.count) { _, _ in if followsOutput { proxy.scrollTo("bottom", anchor: .bottom) } }
        }
    }

    private func messageRow(_ message: AIMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(message.role == .user ? "你" : "AI", systemImage: message.role == .user ? "person.crop.circle" : "sparkles")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if message.state == .streaming { ProgressView().controlSize(.mini) }
                if message.state == .interrupted { Text("未完成").font(.caption2).foregroundStyle(Color.appWarning) }
                Spacer()
                Button { copy(message.text) } label: { Image(systemName: "doc.on.doc") }.accessibilityLabel("复制消息")
                Button { deletingMessage = message.id } label: { Image(systemName: "trash") }.accessibilityLabel("删除消息")
            }.buttonStyle(.borderless)
            // Plain text intentionally avoids remote images, HTML and active model-generated links.
            if message.role == .user || message.text.isEmpty {
                Text(message.text.isEmpty ? "正在生成…" : message.text).font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(AIMessagePart.parse(message.text)) { part in
                    if let language = part.language {
                        codeCard(.init(id: part.id, language: language, text: part.text), message: message, complete: part.complete)
                    } else {
                        Text(part.text).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }.padding(12)
            .background(message.role == .user ? Color.accentColor.opacity(0.07) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    private func codeCard(_ block: AICodeBlock, message: AIMessage, complete: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(block.language.isEmpty ? "代码" : block.language).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("复制代码") { copy(block.text) }
            }.font(.caption).buttonStyle(.borderless)
            Text(block.text).font(.callout.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if complete, message.state == .complete, block.isShell, AICommandTarget.isSingleCommand(block.text),
               let target = workspace.commandTargets[message.id], targetIsCurrent(target) {
                HStack {
                    Button("填入命令栏") {
                        guard targetIsCurrent(target), let controller else { return }
                        controller.hostView.tools.command = block.text
                        controller.hostView.tools.composerVisible = true
                    }
                    Button("执行…") { pendingCommand = .init(target: target, command: block.text) }
                }.font(.caption).buttonStyle(.bordered)
            }
        }.padding(10).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if mode == .ops {
                HStack {
                    Toggle("附带可见终端", isOn: Binding(get: { authorized }, set: { if $0 { showingConsent = true } else { pane.revoke() } }))
                        .toggleStyle(.checkbox).disabled(controller?.status != .connected)
                    Spacer()
                    Button("预览") { contextPreview = terminalAttachment(includeScreen: true).text }
                        .disabled(controller == nil).buttonStyle(.borderless)
                }.font(.caption)
                if pane.selectedText != nil {
                    HStack {
                        Label("已附选区 · 仅本次发送", systemImage: "text.quote").font(.caption)
                        Spacer()
                        Button { contextPreview = pane.selectedText } label: { Image(systemName: "eye") }.accessibilityLabel("查看选区附件")
                        Button { pane.selectedText = nil } label: { Image(systemName: "xmark.circle") }.accessibilityLabel("移除选区附件")
                    }.buttonStyle(.borderless)
                }
            }
            TextField("描述需求，或粘贴命令与日志…", text: draft, axis: .vertical)
                .lineLimit(3...8).textFieldStyle(.roundedBorder)
                .accessibilityLabel("AI 消息输入")
            HStack {
                Toggle("跟随回复", isOn: $followsOutput).toggleStyle(.checkbox).font(.caption)
                Spacer()
                if chat?.messages.isEmpty == false {
                    Button { confirmingClear = true } label: { Image(systemName: "trash") }.accessibilityLabel("清空 AI 对话")
                }
                if busy {
                    Button("停止") { if let id = conversationID { workspace.stop(id) } }
                } else {
                    Button("发送") { send() }.buttonStyle(.borderedProminent)
                        .disabled(!workspace.loaded || draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Text("聊天保存在本机；发送内容交由所配置的 AI 服务处理。请勿提交秘密。").font(.caption2).foregroundStyle(.secondary)
        }.padding(12)
    }

    private func newConversation() {
        if mode == .ops, let controller {
            if let id = workspace.create(mode: .ops, serverID: controller.serverID, name: controller.serverName) {
                pane.invalidate(); pane.conversationID = id; pane.draft = ""; workspace.prepare(controller)
            }
        } else if let id = workspace.create(mode: .general) { workspace.generalConversationID = id; workspace.generalDraft = "" }
    }
    private func send() {
        guard mode == .general || isActive() else { return }
        if (try? settings.configuration.endpoint()) == nil { showingSettings = true; return }
        if chat == nil {
            let savedDraft = draft.wrappedValue
            newConversation()
            draft.wrappedValue = savedDraft
        }
        guard let id = conversationID else { return }
        let context = mode == .ops && (authorized || pane.selectedText != nil) ? terminalAttachment(includeScreen: authorized) : nil
        let target = controller.map { AICommandTarget(paneID: $0.id, generation: $0.connectionGeneration, serverName: $0.serverName) }
        if workspace.send(id: id, prompt: draft.wrappedValue, configuration: settings.configuration, context: context, target: target) {
            draft.wrappedValue = ""; pane.selectedText = nil
        }
    }
    private func terminalAttachment(includeScreen: Bool) -> AITerminalContext {
        var parts: [String] = []
        if let selected = pane.selectedText { parts.append("用户选中的终端内容：\n" + selected) }
        if includeScreen, let controller {
            parts.append("服务器：\(controller.serverName)\n地址：\(controller.config.host):\(controller.config.port)\n用户名：\(controller.config.username)\n当前可见屏幕：\n" + controller.hostView.aiVisibleText())
        }
        return .init(text: AITerminalContext.bounded(parts.joined(separator: "\n\n")))
    }
    private func targetIsCurrent(_ target: AICommandTarget) -> Bool {
        isActive() && target.matches(paneID: controller?.id, generation: controller?.connectionGeneration, connected: controller?.status == .connected)
    }
    private func executePending() {
        defer { pendingCommand = nil }
        guard let pendingCommand, targetIsCurrent(pendingCommand.target), AICommandTarget.isSingleCommand(pendingCommand.command) else { return }
        controller?.hostView.sendCommand(pendingCommand.command + "\r")
        if let controller { CommandHistoryStore.shared.record(pendingCommand.command, serverID: controller.serverID) }
    }
    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
}

private struct AIConversationBrowser: View {
    let mode: AIMode
    let serverID: UUID?
    let paneID: UUID?
    let select: (UUID) -> Void
    @ObservedObject private var workspace = AIWorkspace.shared
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var deleting: UUID?
    var body: some View {
        NavigationStack {
            List {
                ForEach(workspace.conversations.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { chat in
                    HStack {
                        Button {
                            select(chat.id); dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(chat.title).lineLimit(1)
                                Text("\(chat.mode.title) · \(chat.messages.count) 条消息").font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                            .disabled(chat.mode != mode || (mode == .ops && (chat.serverID != serverID || workspace.isOwnedByAnotherPane(chat.id, paneID: paneID))))
                        if workspace.running.contains(chat.id) { ProgressView().controlSize(.small) }
                        Button(role: .destructive) { deleting = chat.id } label: { Image(systemName: "trash") }.accessibilityLabel("删除对话 \(chat.title)")
                    }.padding(.vertical, 4)
                }
            }
            .searchable(text: $search, prompt: "搜索对话名称")
            .navigationTitle("本地对话 · \(workspace.conversations.count)/50")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .safeAreaInset(edge: .bottom) {
                Text("运维对话仅能在同一服务器中打开；已绑定其他面板的对话不可混用。删除不可撤销，不会删除 AI 服务端的数据。").font(.caption).foregroundStyle(.secondary).padding()
            }
            .confirmationDialog("删除此对话及全部消息？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("删除对话", role: .destructive) { if let id = deleting { Task { await workspace.delete(id) } }; deleting = nil }
            }
        }.frame(width: 620, height: 520)
    }
}

struct AISettingsView: View {
    @ObservedObject private var settings = AISettings.shared
    @State private var configuration = AIConfiguration()
    @State private var key = ""
    @State private var removeKey = false
    @State private var status: String?
    @State private var testing = false
    @State private var testTask: Task<Void, Never>?
    var body: some View {
        Form {
            Section("OpenAI 兼容服务") {
                TextField("API 基础地址", text: $configuration.baseURL)
                    .help("例如 https://api.openai.com/v1，自动追加 /chat/completions")
                TextField("模型 ID", text: $configuration.model)
                SecureField("新的 API Key（留空保留）", text: $key)
                Toggle("删除已保存的 API Key（用于免密本机服务）", isOn: $removeKey)
                Stepper("上下文消息：\(configuration.contextMessages) 条", value: $configuration.contextMessages, in: 2...100, step: 2)
                Text("填写支持 Chat Completions 流式输出的模型和基础地址，不含 /chat/completions。仅 HTTPS 或本机回环 HTTP；不会跟随重定向。并非所有“兼容”服务都支持相同参数。").font(.caption).foregroundStyle(.secondary)
            }
            Section("隐私与执行") {
                Text("API Key 仅保存在本机 Keychain，不写入聊天、日志或会话导出。服务器上下文需逐连接授权；通用对话不读取终端。自动附件不落盘，但用户消息及 AI 回复可能包含敏感内容。")
                Text("单次发送最多 32 KiB 输入、16 KiB 终端附件；历史默认最近 20 条并有请求大小上限。最多 50 个对话，不会自动删除旧对话。AI 不会自主连接服务器或执行命令。")
            }.font(.caption).foregroundStyle(.secondary)
            Section {
                HStack {
                    Button("保存设置") {
                        do {
                            try settings.save(configuration, key: removeKey ? "" : (key.isEmpty ? nil : key))
                            key = ""; removeKey = false; status = "已保存，终端上下文授权已重置。"
                        } catch { status = AIError.safeDescription(error) }
                    }.buttonStyle(.borderedProminent).disabled(testing)
                    Button(testing ? "停止测试" : "测试连接") { if testing { testTask?.cancel() } else { testConnection() } }
                    if testing { ProgressView().controlSize(.small) }
                }
                Text("测试会发送一条不含终端内容的“回复 OK”消息，可能产生服务费用。").font(.caption).foregroundStyle(.secondary)
                if let status { Text(status).font(.caption).textSelection(.enabled) }
            }
        }.formStyle(.grouped)
            .onAppear { configuration = settings.configuration }
            .onDisappear { testTask?.cancel(); key = "" }
    }
    private func testConnection() {
        testing = true; status = nil
        do {
            let token = removeKey ? "" : (key.isEmpty ? try AIKeychain.read() : key)
            let request = try AIRequestBuilder.request(configuration: configuration, key: token, messages: [.init(role: "user", content: "请只回复 OK。")])
            testTask = Task {
                defer { testing = false }
                do {
                    for try await _ in OpenAICompatibleClient().stream(request: request) { try Task.checkCancellation() }
                    status = "流式连接测试成功。请保存设置后使用。"
                } catch { status = AIError.safeDescription(error) }
            }
        } catch { testing = false; status = AIError.safeDescription(error) }
    }
}
