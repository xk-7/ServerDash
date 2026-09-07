import SwiftUI
import SwiftData

struct TerminalToolsBar: View {
    @ObservedObject var tools: TerminalTools
    @ObservedObject private var history = CommandHistoryStore.shared
    @ObservedObject private var highlights = TerminalHighlightSettings.shared
    @Query(sort: \CommandSnippetRecord.title) private var snippets: [CommandSnippetRecord]
    let connected: Bool
    let send: (String) -> Void
    @State private var pendingCommand: String?
    @State private var historySearch = ""
    @State private var showingShellIntegration = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if tools.searchVisible {
                HStack {
                    TextField("搜索终端内容", text: $tools.searchText).focused($searchFocused)
                        .textFieldStyle(.roundedBorder).onSubmit { tools.search() }
                        .onChange(of: tools.searchText) { _, _ in tools.search() }
                    if tools.searchFound == false { Text("无匹配").font(.caption).foregroundStyle(.secondary) }
                    Button { tools.search(backwards: true) } label: { Image(systemName: "chevron.up").frame(width: 44, height: 44) }
                        .accessibilityLabel("上一个匹配")
                    Button { tools.search() } label: { Image(systemName: "chevron.down").frame(width: 44, height: 44) }
                        .accessibilityLabel("下一个匹配")
                    Button { tools.searchText = ""; tools.searchVisible = false; tools.search() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                        .accessibilityLabel("关闭搜索")
                }.padding(.horizontal, 8).onAppear { searchFocused = true }
            }
            if tools.composerVisible || !tools.promptCommand.isEmpty {
                let suggestions = TerminalCompletion.suggestions(prefix: tools.composerVisible ? tools.command : tools.promptCommand,
                    history: history.entries.filter { $0.serverID == tools.serverID }.map(\.command), snippets: snippets.map(\.command))
                    .filter { tools.composerVisible || $0.command.hasPrefix(tools.promptCommand) }
                if !suggestions.isEmpty {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(suggestions) { suggestion in
                                Button {
                                    if tools.composerVisible { tools.command = suggestion.command }
                                    else if connected, let suffix = tools.completionSuffix(for: suggestion.command) { send(suffix) }
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(suggestion.command).font(.caption.monospaced()).lineLimit(1)
                                        Text(suggestion.source).font(.caption2).foregroundStyle(.secondary)
                                    }.padding(.horizontal, 8).frame(minHeight: 44)
                                }
                            }
                        }
                    }.padding(.horizontal, 8)
                }
                if tools.composerVisible { HStack {
                    TextField("命令（历史 / Linux / 片段补全）", text: $tools.command)
                        .textFieldStyle(.roundedBorder).font(.callout.monospaced())
                        #if os(iOS)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        #endif
                        .onSubmit { requestSend() }
                    Button("发送…") { requestSend() }.disabled(!connected || tools.command.isEmpty)
                        .frame(minHeight: 44)
                }.padding(.horizontal, 8) }
            }
            HStack(spacing: 12) {
                Button { tools.composerVisible.toggle() } label: { Label("命令", systemImage: "text.cursor") }
                Button { tools.showingHistory = true } label: { Label("历史", systemImage: "clock.arrow.circlepath") }
                Button { tools.showingRules = true } label: { Label("高亮", systemImage: "highlighter") }
                Menu {
                    Button("启用自动命令历史…") { showingShellIntegration = true }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("Shell 集成")
                Spacer(minLength: 0)
                Button { tools.searchVisible.toggle() } label: { Image(systemName: "magnifyingglass").frame(width: 44, height: 44) }
                    .accessibilityLabel("终端搜索 Ctrl+F")
            }.font(.caption).padding(.horizontal, 8).frame(minHeight: 44)
        }
        .buttonStyle(.borderless).background(.bar)
        .onChange(of: highlights.rules) { _, _ in tools.redraw() }
        .sheet(isPresented: $showingShellIntegration) {
            NavigationStack {
                Form {
                    Section("自动记录直接在终端中执行的命令") {
                        Text("通过 OSC 133 标记 Shell 提示符和命令边界，区分命令与程序内的密码输入。只修改当前 Shell 的提示符，不写入远程配置文件；断开连接后需重新启用。请在 Shell 提示符下选择对应类型，再确认发送。")
                        Button("Bash 4.4+：填入集成命令") { prepareIntegration(TerminalShellIntegration.bash) }
                        Button("Zsh：填入集成命令") { prepareIntegration(TerminalShellIntegration.zsh) }
                    }
                    Section { Text("已有 OSC 133 集成的 Shell 无需重复设置。不支持的 Shell 请使用命令栏。历史记录不是密码保险箱：涉及私密参数的操作请关闭记录，或在命令前加一个空格。") }
                }.formStyle(.grouped).navigationTitle("Shell 集成")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showingShellIntegration = false } } }
            }
            #if os(macOS)
            .frame(width: 570, height: 430)
            #endif
        }
        .sheet(isPresented: $tools.showingRules) { TerminalHighlightEditor(settings: highlights) }
        .sheet(isPresented: $tools.showingHistory) {
            NavigationStack {
                List {
                    Section {
                        Toggle("保存命令历史", isOn: $history.enabled)
                        Text("仅保存命令栏确认发送的命令及 OSC 133 Shell 边界内的命令。不记录原始按键或密码回答。含敏感关键词、赋值或以空格开头的命令会跳过；其他私密命令请先关闭记录。最多保留最近 2,000 条，仅存本机。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("当前服务器 · 点击填入命令栏") {
                        ForEach(history.entries.filter { $0.serverID == tools.serverID && (historySearch.isEmpty || $0.command.localizedCaseInsensitiveContains(historySearch)) }) { entry in
                            Button {
                                tools.command = entry.command; tools.composerVisible = true; tools.showingHistory = false
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(entry.command).font(.callout.monospaced())
                                    Text(entry.date, style: .date).font(.caption).foregroundStyle(.secondary)
                                }.frame(minHeight: 44)
                            }
                        }
                    }
                    Section { Button("清空所有服务器的命令历史", role: .destructive) { history.clear() } }
                }
                .searchable(text: $historySearch, prompt: "搜索命令")
                .navigationTitle("命令历史")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { tools.showingHistory = false } } }
            }
            #if os(macOS)
            .frame(width: 620, height: 560)
            #endif
        }
        .confirmationDialog("向当前面板发送命令？", isPresented: Binding(get: { pendingCommand != nil }, set: { if !$0 { pendingCommand = nil } })) {
            Button("确认发送") {
                guard connected, let command = pendingCommand else { pendingCommand = nil; return }
                send(command + "\r")
                history.record(command, serverID: tools.serverID)
                tools.command = ""; pendingCommand = nil
            }
            Button("取消", role: .cancel) { pendingCommand = nil }
        } message: {
            Text("\(pendingCommand ?? "")\n\n请确认当前终端停留在 Shell 提示符；命令将立即提交，不会广播至其他面板。")
        }
    }
    private func requestSend() {
        guard connected, !tools.command.isEmpty,
              !tools.command.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return }
        pendingCommand = tools.command
    }
    private func prepareIntegration(_ command: String) {
        tools.command = command; tools.composerVisible = true; showingShellIntegration = false
    }
}

private struct TerminalHighlightEditor: View {
    @ObservedObject var settings: TerminalHighlightSettings
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var pattern = ""
    @State private var color = 0
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("规则（最多 32 条，按优先级匹配）") {
                    ForEach($settings.rules) { $rule in
                        VStack(alignment: .leading) {
                            Toggle(rule.name, isOn: $rule.enabled)
                            Text(rule.pattern).font(.caption.monospaced()).textSelection(.enabled)
                            Picker("颜色", selection: $rule.color) { colors }
                            Button("删除规则", role: .destructive) { settings.rules.removeAll { $0.id == rule.id } }
                        }.padding(.vertical, 4)
                    }
                }
                Section("自定义正则表达式") {
                    TextField("名称", text: $name)
                    TextField("正则（最多 256 字符）", text: $pattern)
                        #if os(iOS)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        #endif
                    Picker("颜色", selection: $color) { colors }
                    if let error { Text(error).foregroundStyle(.red) }
                    Button("添加规则") {
                        guard !pattern.isEmpty, pattern.count <= 256, (try? NSRegularExpression(pattern: pattern)) != nil else { error = "请输入有效且不超过 256 字符的正则表达式。"; return }
                        settings.rules.append(.init(name: name.isEmpty ? "自定义规则" : name, pattern: pattern, color: color))
                        pattern = ""; name = ""; error = nil
                    }.disabled(settings.rules.count >= 32)
                }
                Section { Button("恢复 7 个预设") { settings.rules = TerminalHighlightRule.presets } }
                Section { Text("只装饰可见终端文字，不改变输出、复制内容或发送数据。复杂表达式达到时间预算时会跳过该行，避免阻塞终端。") }
            }
            .formStyle(.grouped).navigationTitle("关键词高亮")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        #if os(macOS)
        .frame(width: 600, height: 640)
        #endif
    }
    private var colors: some View {
        ForEach(0..<12) { index in Text(TerminalHighlightRule.colorNames[index]).foregroundStyle(TerminalHighlightRule.colors[index]).tag(index) }
    }
}
