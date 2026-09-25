import AppKit
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, terminal, monitoring, files, shortcuts, security, sync, recording, ai
    var id: String { rawValue }
    var title: String { switch self { case .general: "通用"; case .terminal: "终端"; case .monitoring: "监控"; case .files: "SFTP"; case .shortcuts: "快捷键"; case .security: "安全"; case .sync: "同步"; case .recording: "录制"; case .ai: "AI 助手" } }
    var symbol: String { switch self { case .general: "gearshape"; case .terminal: "terminal"; case .monitoring: "chart.xyaxis.line"; case .files: "folder"; case .shortcuts: "keyboard"; case .security: "lock.shield"; case .sync: "arrow.triangle.2.circlepath"; case .recording: "record.circle"; case .ai: "sparkles" } }
    var maximumContentWidth: CGFloat {
        switch self {
        case .terminal, .files, .sync, .recording, .ai:
            960
        case .general, .monitoring, .shortcuts, .security:
            720
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("appAppearance") private var appearance = AppAppearance.system.rawValue
    @AppStorage("networkDisplayInBits") private var networkBits = false
    @AppStorage("hideIPInformation") private var hideIP = false
    @AppStorage(PrivacySettings.locationLookupEnabledKey) private var locationLookupEnabled = false
    @AppStorage("mac.settings.selectedPage") private var pageID = SettingsPage.general.rawValue
    @State private var localShellDraft = LocalShellSettingsDraft(path: "", environment: "inherit")
    @State private var localShellError: String?
    @State private var localShellSaved = false
    @FocusState private var localShellFocused: Bool
    @State private var timeoutText = ""
    @State private var timeoutError: String?
    @State private var timeoutSaved = false
    @FocusState private var timeoutFocused: Bool
    @State private var shortcutSearch = ""
    @State private var confirmingLocationLookup = false
    @State private var showsTrustedHosts = false
    private var page: SettingsPage { SettingsPage(rawValue: pageID) ?? .general }
    private var pageSelection: Binding<SettingsPage?> {
        Binding(get: { page }, set: { if let value = $0 { pageID = value.rawValue } })
    }
    private var localShellPathBinding: Binding<String> {
        Binding(
            get: { localShellDraft.path },
            set: {
                localShellDraft.path = $0
                localShellError = nil
                localShellSaved = false
            }
        )
    }
    private var localShellEnvironmentBinding: Binding<String> {
        Binding(
            get: { localShellDraft.environment },
            set: {
                localShellDraft.environment = $0
                localShellError = nil
                localShellSaved = false
            }
        )
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: pageSelection) {
                Label($0.title, systemImage: $0.symbol).tag($0)
            }.listStyle(.sidebar).navigationTitle("设置")
                .navigationSplitViewColumnWidth(min: 155, ideal: 170, max: 210)
        } detail: {
            GeometryReader { geometry in
                let metrics = MacWorkspaceMetrics(size: geometry.size)
                VStack(alignment: .leading, spacing: 0) {
                    Label(page.title, systemImage: page.symbol)
                        .font(.title2.weight(.semibold))
                        .padding(.horizontal, metrics.pagePadding)
                        .padding(.vertical, metrics.pageHeaderPadding)
                    Divider()
                    detail
                        .frame(maxWidth: page.maximumContentWidth, maxHeight: .infinity)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .background(Color.appGround)
            }
        }
        .frame(minWidth: 820, idealWidth: 1000, minHeight: 620, idealHeight: 740)
        .preferredColorScheme((AppAppearance(rawValue: appearance) ?? .system).colorScheme)
        .onAppear {
            reloadTimeout()
            reloadLocalShell()
        }
        .onChange(of: pageID) { _, _ in reloadTimeout() }
        .confirmationDialog("启用服务器公网位置查询？", isPresented: $confirmingLocationLookup) {
            Button("启用查询") { setLocationLookupEnabled(true) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("监控连接会让受管服务器访问 ipinfo.io，以查询该服务器的公网 IP 与大致位置。ServerDash 不会上传连接凭据。")
        }
        .sheet(isPresented: $showsTrustedHosts) {
            TrustedHostsView().frame(minWidth: 720, minHeight: 520)
        }
    }
    @ViewBuilder private var detail: some View {
        switch page {
        case .general:
            Form {
                Section("外观") {
                    Picker("显示模式", selection: $appearance) { ForEach(AppAppearance.allCases) { Label($0.title, systemImage: $0.symbol).tag($0.rawValue) } }.pickerStyle(.segmented)
                    Toggle("隐藏 IP 与位置信息", isOn: $hideIP)
                    Text("隐私模式同时应用于主机、监控、导出摘要和诊断显示。").font(.caption).foregroundStyle(.secondary)
                }
                Section("工作区") {
                    Text("标签与连接由工作区持有，切换页面后保持运行。").foregroundStyle(.secondary)
                    LabeledContent("版本", value: MacSettingsValidation.versionLabel())
                }
            }.formStyle(.grouped)
        case .terminal:
            GeometryReader { geometry in
                Form {
                    Section("本地终端") {
                        HStack {
                            TextField("Shell 路径（留空使用登录 Shell）", text: localShellPathBinding)
                                .focused($localShellFocused)
                                .onSubmit(saveLocalShell)
                                .accessibilityIdentifier("mac.settings.terminal.shellPath")
                            Button("浏览…") { chooseShell() }
                        }
                        Picker("环境", selection: localShellEnvironmentBinding) {
                            Text("登录终端环境").tag("inherit")
                            Text("干净环境").tag("clean")
                        }
                        if localShellError != nil || MacSettingsValidation.localShellPath(localShellDraft.path) == nil {
                            Text(localShellError ?? "请选择可执行文件的绝对路径，或留空使用登录 Shell。")
                                .font(.caption)
                                .foregroundStyle(Color.appError)
                                .accessibilityIdentifier("mac.settings.terminal.shellError")
                        } else if localShellSaved {
                            Label("已保存", systemImage: "checkmark.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Spacer()
                            Button("取消", action: reloadLocalShell)
                                .disabled(!localShellHasChanges)
                                .accessibilityIdentifier("mac.settings.terminal.shellCancel")
                            Button("保存", action: saveLocalShell)
                                .disabled(!localShellCanSave)
                                .accessibilityIdentifier("mac.settings.terminal.shellSave")
                        }
                    }
                    Section("终端外观") {
                        TerminalAppearanceSettingsView(availableWidth: geometry.size.width)
                    }
                }
                .formStyle(.grouped)
            }
        case .monitoring:
            Form {
                Section("刷新") {
                            Picker("自动刷新", selection: Binding(get: { appState.refreshInterval }, set: { appState.updateRefreshInterval($0) })) {
                                Text("手动").tag(0.0)
                                ForEach([1.0, 5, 10, 30, 60], id: \.self) { Text("每 \(Int($0)) 秒").tag($0) }
                            }
                            Toggle("网络速率使用 bit/s", isOn: $networkBits)
                }
                MonitoringFilterSettingsView()
            }.formStyle(.grouped)
        case .files: DesktopFileSettingsView()
        case .shortcuts:
            Form {
                Section("查找") {
                    AppleSearchField(prompt: "查找快捷键", text: $shortcutSearch)
                        .accessibilityIdentifier("mac.settings.shortcuts.search")
                }
                Section("快捷键") {
                    if visibleShortcuts.isEmpty {
                        Text("没有匹配的快捷键")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(visibleShortcuts, id: \.0) { item in
                            LabeledContent(item.0) {
                                Text(item.1)
                                    .font(.body.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    Text("快捷键与菜单栏保持一致；macOS 保留的系统快捷键由系统处理。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        case .security:
            Form {
                Section("SSH") {
                    LabeledContent("主机密钥验证") {
                        Label("始终启用", systemImage: "checkmark.shield")
                            .foregroundStyle(Color.appLive)
                    }
                    LabeledContent("默认连接超时") {
                        HStack {
                            TextField("默认连接超时", text: $timeoutText, prompt: Text("5–300"))
                                .labelsHidden().frame(width: 80)
                                .focused($timeoutFocused).onSubmit(saveTimeout)
                                .accessibilityLabel("默认连接超时，秒")
                                .onChange(of: timeoutText) { _, _ in timeoutSaved = false; timeoutError = nil }
                            Text("秒").foregroundStyle(.secondary)
                            Button("保存", action: saveTimeout)
                                .disabled(MacSettingsValidation.timeout(timeoutText) == nil)
                        }
                    }
                    if let timeoutError { Text(timeoutError).foregroundStyle(Color.appError) }
                    else if timeoutSaved { Label("已保存", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
                    else if MacSettingsValidation.timeout(timeoutText) == nil { Text("请输入 5–300 之间的整数秒数。").foregroundStyle(Color.appError) }
                    Text("所有 SSH、SFTP 与监控连接都使用应用专属信任记录；首次连接和密钥变化时必须明确确认。").font(.caption).foregroundStyle(.secondary)
                    Button("管理可信主机…", systemImage: "checkmark.shield") { showsTrustedHosts = true }
                }
                Section("服务器公网位置") {
                    Toggle("查询服务器公网 IP 与大致位置", isOn: Binding(
                        get: { locationLookupEnabled },
                        set: { enabled in
                            if enabled { confirmingLocationLookup = true }
                            else { setLocationLookupEnabled(false) }
                        }
                    ))
                    Text("默认关闭。启用后，受管服务器会访问 ipinfo.io；关闭会停止后续查询并清理 ServerDash 内存中的位置缓存。").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
        case .sync: WebDAVSyncView(embedded: true)
        case .recording: RecordingSettingsView()
        case .ai: AISettingsView()
        }
    }
    private var shortcuts: [(String, String)] {
        [("新建主机", "⌘N"), ("刷新全部", "⌘R"), ("重试失败监控", "⇧⌘R"), ("新建会话标签", "⌘T"),
         ("下一标签", "⌃Tab"), ("上一标签", "⌃⇧Tab"), ("向右分屏", "⌃⇧D"), ("向下分屏", "⌃⇧E"),
         ("关闭活跃面板", "⌃⇧W"), ("查找终端", "⌘F / ⌃F"), ("显示检查器", "⌥⌘I"),
         ("放大字号", "⌘+"), ("缩小字号", "⌘−"), ("恢复字号", "⌘0"), ("终端外观", "⇧⌘,"),
         ("保存远程文件", "⌘S"), ("设置", "⌘,")]
    }
    private var visibleShortcuts: [(String, String)] {
        shortcuts.filter {
            shortcutSearch.isEmpty ||
                $0.0.localizedCaseInsensitiveContains(shortcutSearch) ||
                $0.1.localizedCaseInsensitiveContains(shortcutSearch)
        }
    }
    private func reloadTimeout() {
        timeoutText = MacSettingsValidation.timeoutText(PrivacySettings.connectTimeout)
        timeoutError = nil; timeoutSaved = false
    }
    private var localShellHasChanges: Bool {
        localShellDraft != LocalShellSettingsDraft.load()
    }
    private var localShellCanSave: Bool {
        localShellHasChanges
            && MacSettingsValidation.localShellPath(localShellDraft.path) != nil
            && (localShellDraft.environment == "inherit" || localShellDraft.environment == "clean")
    }
    private func reloadLocalShell() {
        localShellDraft = LocalShellSettingsDraft.load()
        localShellError = nil
        localShellSaved = false
        localShellFocused = false
    }
    private func saveLocalShell() {
        guard let saved = localShellDraft.commit() else {
            localShellError = "请选择可执行文件的绝对路径，或留空使用登录 Shell。"
            localShellFocused = true
            return
        }
        localShellDraft = saved
        localShellError = nil
        localShellSaved = true
        localShellFocused = false
    }
    private func saveTimeout() {
        guard let seconds = MacSettingsValidation.timeout(timeoutText) else {
            timeoutError = "请输入 5–300 之间的整数秒数。"; return
        }
        UserDefaults.standard.set(seconds, forKey: "sshConnectTimeout")
        timeoutText = String(seconds); timeoutError = nil; timeoutSaved = true; timeoutFocused = false
    }
    private func setLocationLookupEnabled(_ enabled: Bool) {
        PrivacySettings.setLocationLookupEnabled(enabled)
        locationLookupEnabled = enabled
        if !enabled { appState.clearCachedServerLocations() }
    }
    private func chooseShell() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.directoryURL = URL(fileURLWithPath: "/bin")
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { localShellPathBinding.wrappedValue = url.path }
    }
}

struct LocalShellSettingsDraft: Equatable {
    var path: String
    var environment: String

    static func load(defaults: UserDefaults = .standard) -> Self {
        let environment = defaults.string(forKey: "workbench.localShellEnvironment") == "clean" ? "clean" : "inherit"
        return Self(path: defaults.string(forKey: "workbench.localShellPath") ?? "", environment: environment)
    }

    /// Only an explicit, validated commit changes the configuration read by new PTY sessions.
    @discardableResult
    func commit(defaults: UserDefaults = .standard, fileManager: FileManager = .default) -> Self? {
        guard let path = MacSettingsValidation.localShellPath(path, fileManager: fileManager),
              environment == "inherit" || environment == "clean" else { return nil }
        defaults.set(path, forKey: "workbench.localShellPath")
        defaults.set(environment, forKey: "workbench.localShellEnvironment")
        return Self(path: path, environment: environment)
    }
}

enum MacSettingsValidation {
    static func localShellPath(_ text: String, fileManager: FileManager = .default) -> String? {
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty { return "" }
        guard !path.contains("\0"), (path as NSString).isAbsolutePath else { return nil }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              fileManager.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    static func timeout(_ text: String) -> Int? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }),
              let seconds = Int(value), (5...300).contains(seconds) else { return nil }
        return seconds
    }
    static func versionLabel(info: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> String {
        let version = info["CFBundleShortVersionString"] as? String ?? "—"
        guard let build = info["CFBundleVersion"] as? String, !build.isEmpty else { return version }
        return "\(version)（\(build)）"
    }
    static func timeoutText(_ seconds: TimeInterval) -> String {
        seconds.rounded() == seconds ? String(Int(seconds)) : String(seconds)
    }
}
