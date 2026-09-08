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
    @State private var showingModels = false

    private var conversationID: UUID? {
        mode == .ops ? pane.conversationID : workspace.generalConversationID
    }
    private var chat: AIConversation? { workspace.conversation(conversationID) }
    private var busy: Bool { conversationID.map { workspace.running.contains($0) } ?? false }
    private var activeProfile: AIProviderProfile {
        var profile = settings.profile(chat?.destination?.provider ?? settings.defaultProvider)
        if let model = chat?.destination?.model { profile.model = model }
        return profile
    }
    private var destinationChanged: Bool { chat?.destination.map { !$0.matches(activeProfile) } ?? false }
    private var draft: Binding<String> {
        mode == .ops ? $pane.draft : $workspace.generalDraft
    }
    private var authorized: Bool {
        guard let controller, mode == .ops else { return false }
        return !destinationChanged && pane.isAuthorized(generation: controller.connectionGeneration, settings: activeProfile.authorizationRevision)
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
        .onChange(of: activeProfile.authorizationRevision) { _, _ in pane.invalidate(); showingConsent = false }
        .onChange(of: pane.authorizedGeneration) { _, _ in pendingCommand = nil }
        .onChange(of: conversationID) { _, _ in pendingCommand = nil; showingConsent = false }
        .sheet(isPresented: $showingSettings) {
            VStack(spacing: 0) {
                HStack { Text("AI 设置").font(.headline); Spacer(); Button("完成") { showingSettings = false } }.padding()
                AISettingsView(settings: settings)
            }.frame(width: 680, height: 720)
        }
        .sheet(isPresented: $showingModels) {
            AIModelPicker(profile: activeProfile, settings: settings, key: { try settings.key(for: activeProfile) }) { model in
                if let id = conversationID { workspace.selectModel(model, in: id) }
            }
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
                if let controller, !destinationChanged { pane.authorize(generation: controller.connectionGeneration, settings: activeProfile.authorizationRevision) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅在点击发送时，将“\(controller?.serverName ?? "")”的服务器地址、用户名及当前可见输出发送至 \(activeProfile.provider.title)：\(activeProfile.baseURL)。不会读取原始按键、隐藏密码、Keychain 或整段历史，但可见内容仍可能包含秘密。附件本身不随对话存储；AI 回复可能复述内容。重连、切换提供商或修改地址／凭据后需重新授权。")
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
            HStack {
                Menu {
                    ForEach(AIProviderID.allCases) { provider in
                        Button(provider.title) { selectProvider(provider) }
                    }
                } label: { Text(activeProfile.provider.title).lineLimit(1) }
                    .accessibilityLabel("切换 AI 提供商，新建对话")
                Button { ensureConversation(); showingModels = true } label: {
                    Text(activeProfile.model.isEmpty ? "选择模型…" : activeProfile.model).lineLimit(1).truncationMode(.middle)
                }.buttonStyle(.borderless).accessibilityLabel("选择 AI 模型")
            }.font(.caption).disabled(!workspace.loaded)
            Text("发送至：\(chat?.destination?.baseURL ?? activeProfile.baseURL)")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            if destinationChanged {
                Label("地址已修改，请新建对话。旧历史不会转发。", systemImage: "lock.shield")
                    .font(.caption2).foregroundStyle(Color.appWarning)
                Button("为新地址新建对话") { newConversation(profile: settings.profile(activeProfile.provider)) }
                    .font(.caption).buttonStyle(.bordered)
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
            if let provider = message.provider, let model = message.model {
                Text("\(provider.title) · \(model)").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
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
                        .toggleStyle(.checkbox).disabled(controller?.status != .connected || destinationChanged)
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
                        .disabled(!workspace.loaded || destinationChanged || draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Text("聊天保存在本机；发送内容交由所配置的 AI 服务处理。请勿提交秘密。").font(.caption2).foregroundStyle(.secondary)
        }.padding(12)
    }

    private func newConversation(profile: AIProviderProfile? = nil) {
        if mode == .ops, let controller {
            if let id = workspace.create(mode: .ops, serverID: controller.serverID, name: controller.serverName, profile: profile) {
                pane.invalidate(); pane.conversationID = id; pane.draft = ""; workspace.prepare(controller)
            }
        } else if let id = workspace.create(mode: .general, profile: profile) {
            if let old = conversationID { workspace.stop(old) }
            pane.invalidate(); workspace.generalConversationID = id; workspace.generalDraft = ""
        }
    }
    private func ensureConversation() { if chat == nil { newConversation() } }
    private func selectProvider(_ provider: AIProviderID) {
        guard let old = conversationID else { newConversation(profile: settings.profile(provider)); return }
        guard let id = workspace.selectProvider(provider, in: old), id != old else { return }
        pane.invalidate(); draft.wrappedValue = ""
        if mode == .ops {
            pane.conversationID = id
            if let controller { workspace.prepare(controller) }
        } else { workspace.generalConversationID = id }
    }
    private func send() {
        guard mode == .general || isActive() else { return }
        guard !destinationChanged else { return }
        if (try? activeProfile.validate()) == nil { showingSettings = true; return }
        if chat == nil {
            let savedDraft = draft.wrappedValue
            newConversation()
            draft.wrappedValue = savedDraft
        }
        guard let id = conversationID else { return }
        let context = mode == .ops && (authorized || pane.selectedText != nil) ? terminalAttachment(includeScreen: authorized) : nil
        let target = controller.map { AICommandTarget(paneID: $0.id, generation: $0.connectionGeneration, serverName: $0.serverName) }
        if workspace.send(id: id, prompt: draft.wrappedValue, profile: activeProfile, context: context, target: target) {
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
    @ObservedObject var settings = AISettings.shared
    @State private var profile = AIProviderProfile(provider: .openAI)
    @State private var key = ""
    @State private var removeKey = false
    @State private var makeDefault = false
    @State private var pendingProvider: AIProviderID?
    @State private var showingModels = false
    @State private var status: String?
    @State private var testing = false
    @State private var testTask: Task<Void, Never>?
    @State private var testID = UUID()
    private var dirty: Bool {
        profile != settings.profile(profile.provider) || !key.isEmpty || removeKey || (makeDefault && profile.provider != settings.defaultProvider)
    }
    var body: some View {
        Form {
            if let notice = settings.notice {
                Section { Text(notice).font(.caption); Button("重试迁移") { settings.retryMigration(); load(settings.defaultProvider) } }
            }
            Section("模型提供商") {
                Picker("提供商", selection: Binding(get: { profile.provider }, set: { provider in
                    if dirty { pendingProvider = provider } else { load(provider) }
                })) { ForEach(AIProviderID.allCases) { Text($0.title).tag($0) } }
                TextField("API 基础地址", text: $profile.baseURL)
                Text(profile.provider.help).font(.caption).foregroundStyle(.secondary)
                SecureField("新的 API Key（留空保留）", text: $key)
                Toggle("删除此提供商已保存的 Key", isOn: $removeKey)
                if !settings.profile(profile.provider).destination.matches(profile) {
                    Text("地址已变更：请重新填写 Key。继续使用需新建对话，不转发旧历史。").font(.caption).foregroundStyle(Color.appWarning)
                }
                HStack {
                    TextField("模型 ID", text: $profile.model)
                    Button("选择模型…") { showingModels = true }
                }
                Toggle("设为新对话的默认提供商", isOn: $makeDefault)
                Text("每家一套配置；已有对话保持自己的提供商与模型。内置登录通道暂未提供。").font(.caption).foregroundStyle(.secondary)
            }
            Section("高级参数") {
                Toggle("Temperature 使用模型默认", isOn: Binding(get: { profile.options.temperature == nil }, set: { profile.options.temperature = $0 ? nil : min(0.2, profile.temperatureMaximum ?? 0) }))
                    .disabled(profile.temperatureMaximum == nil && profile.options.temperature == nil)
                if profile.temperatureMaximum == nil {
                    Text("此模型不提供 Temperature 覆盖；若已有自定义值，请切回模型默认。").font(.caption).foregroundStyle(.secondary)
                }
                if profile.options.temperature != nil {
                    TextField("Temperature（0–\(profile.temperatureMaximum ?? 0, specifier: "%.1f")）", value: $profile.options.temperature, format: .number)
                }
                Toggle("Max Tokens 使用服务默认", isOn: Binding(get: { profile.options.maxTokens == nil }, set: { profile.options.maxTokens = $0 ? nil : 4096 }))
                    .disabled(profile.provider == .anthropic)
                if profile.options.maxTokens != nil {
                    TextField("Max Tokens（正整数）", value: $profile.options.maxTokens, format: .number.grouping(.never))
                }
                Stepper("历史消息上限：\(profile.options.historyMessages) 条", value: $profile.options.historyMessages, in: 1...50)
                Text("默认 20 条历史，不含系统提示及当前问题；按协议与大小限制裁剪。Temperature 0 也不保证结果完全确定。Token 上限可能包含推理消耗。").font(.caption).foregroundStyle(.secondary)
            }
            Section("隐私与执行") {
                Text("Key 按提供商和地址保存在本机 Keychain，不进入聊天或日志。仅 HTTPS 或本机回环 HTTP，不跟随重定向。终端上下文逐连接、逐发送目的地授权；AI 不会自动执行命令。")
            }.font(.caption).foregroundStyle(.secondary)
            Section {
                HStack {
                    Button("保存设置") { _ = save() }.buttonStyle(.borderedProminent).disabled(testing)
                    Button(testing ? "停止测试" : "测试连接") { if testing { cancelTest(); status = "已停止测试。" } else { testConnection() } }
                    if testing { ProgressView().controlSize(.small) }
                }
                Text("测试会发送一条不含终端内容的“回复 OK”消息，可能产生服务费用。").font(.caption).foregroundStyle(.secondary)
                if let status { Text(status).font(.caption).textSelection(.enabled) }
            }
        }.formStyle(.grouped)
            .onAppear { load(settings.defaultProvider) }
            .onDisappear { cancelTest(); key = "" }
            .onChange(of: profile) { old, new in
                cancelTest()
                if old.baseURL != new.baseURL { key = ""; removeKey = false }
            }
            .onChange(of: key) { _, _ in cancelTest() }
            .onChange(of: removeKey) { _, _ in cancelTest() }
            .sheet(isPresented: $showingModels) {
                AIModelPicker(profile: profile, settings: settings, key: draftKey,
                              mayCache: key.isEmpty && !removeKey && settings.profile(profile.provider).destination.matches(profile)) { profile.model = $0 }
            }
            .confirmationDialog("保存当前提供商的修改？", isPresented: Binding(get: { pendingProvider != nil }, set: { if !$0 { pendingProvider = nil } })) {
                Button("保存并切换") { if let next = pendingProvider, save() { load(next) }; pendingProvider = nil }
                Button("放弃修改并切换", role: .destructive) { if let next = pendingProvider { load(next) }; pendingProvider = nil }
                Button("取消", role: .cancel) { pendingProvider = nil }
            }
    }
    private func load(_ provider: AIProviderID) {
        cancelTest(); profile = settings.profile(provider); key = ""; removeKey = false
        makeDefault = settings.defaultProvider == provider; status = nil
    }
    private func draftKey() throws -> String {
        if removeKey { return "" }
        if !key.isEmpty { return key }
        guard settings.profile(profile.provider).destination.matches(profile) else { return "" }
        return try settings.key(for: settings.profile(profile.provider))
    }
    private func save() -> Bool {
        do {
            try settings.save(profile, key: removeKey ? "" : (key.isEmpty ? nil : key), makeDefault: makeDefault)
            load(profile.provider); status = "已保存。参数从下一次请求生效；地址或凭据变更会重置上下文授权。"
            return true
        } catch { status = AIError.safeDescription(error); return false }
    }
    private func cancelTest() { testID = UUID(); testTask?.cancel(); testTask = nil; testing = false }
    private func testConnection() {
        cancelTest()
        let id = UUID(); testID = id; testing = true; status = nil
        do {
            let captured = profile
            let request = try AIProviderAdapter(provider: captured.provider).request(profile: captured, key: draftKey(), messages: [.init(role: "user", content: "请只回复 OK。")], model: settings.models(for: captured).first { $0.id == captured.model })
            testTask = Task {
                do {
                    for try await _ in OpenAICompatibleClient().stream(request: request, provider: captured.provider) { try Task.checkCancellation() }
                    guard testID == id else { return }
                    testing = false; status = "流式连接测试成功。请保存设置后使用。"
                } catch {
                    guard testID == id else { return }
                    testing = false; status = AIError.safeDescription(error)
                }
            }
        } catch { testing = false; status = AIError.safeDescription(error) }
    }
}

private struct AIModelPicker: View {
    let profile: AIProviderProfile
    @ObservedObject var settings: AISettings
    let key: () throws -> String
    var mayCache = true
    let select: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var models: [AIModelDescriptor] = []
    @State private var search = ""
    @State private var manual = ""
    @State private var status: String?
    @State private var loading = false
    @State private var task: Task<Void, Never>?
    @State private var requestID = UUID()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("\(profile.provider.title) · 模型").font(.headline); Spacer(); Button("取消") { dismiss() } }
            TextField("搜索模型名称或 ID", text: $search).textFieldStyle(.roundedBorder)
            List(models.filter { search.isEmpty || $0.id.localizedCaseInsensitiveContains(search) || $0.name.localizedCaseInsensitiveContains(search) }) { model in
                Button { manual = model.id } label: {
                    VStack(alignment: .leading) { Text(model.id); Text(model.name).font(.caption).foregroundStyle(.secondary) }
                }.buttonStyle(.plain).accessibilityLabel("选择 \(model.id)")
            }
            HStack {
                Button(loading ? "停止刷新" : "刷新模型列表") { if loading { cancel() } else { refresh() } }
                    .disabled(!profile.provider.discoverySupported)
                if loading { ProgressView().controlSize(.small) }
            }
            TextField("手动填写模型 ID / 推理接入点 ID", text: $manual).textFieldStyle(.roundedBorder)
            Text(profile.provider == .volcengine ? "请从方舟控制台复制已开通的模型 ID 或 ep- 接入点 ID。" : "列表来自当前服务，不代表具备调用权限或支持所有参数。刷新仅查询目录，不发送对话。也可手动填写 ID。")
                .font(.caption).foregroundStyle(.secondary)
            if let status { Text(status).font(.caption).foregroundStyle(Color.appWarning) }
            HStack { Spacer(); Button("使用此模型") {
                let id = manual.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty, id.utf8.count <= 256, !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { status = AIError.configuration.localizedDescription; return }
                select(id); dismiss()
            }.buttonStyle(.borderedProminent).disabled(manual.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(20).frame(width: 540, height: 540)
            .onAppear { models = mayCache ? settings.models(for: profile) : []; manual = profile.model }
            .onDisappear { cancel() }
            .onChange(of: profile) { _, _ in cancel(); models = []; manual = profile.model }
    }
    private func cancel() { requestID = UUID(); task?.cancel(); task = nil; loading = false }
    private func refresh() {
        cancel(); let id = UUID(); requestID = id; loading = true; status = nil
        do {
            let token = try key()
            task = Task {
                do {
                    let list = try await AIProviderAdapter(provider: profile.provider).listModels(profile: profile, key: token)
                    try Task.checkCancellation(); guard requestID == id else { return }
                    models = list; if mayCache { settings.cache(list, for: profile) }; loading = false
                    status = list.isEmpty ? "服务未返回模型，请手动填写。" : nil
                } catch {
                    guard requestID == id else { return }
                    loading = false; status = AIError.safeDescription(error)
                }
            }
        } catch { loading = false; status = AIError.safeDescription(error) }
    }
}
