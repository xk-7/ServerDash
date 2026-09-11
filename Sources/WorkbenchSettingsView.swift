import AppKit
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, terminal, monitoring, files, shortcuts, security, sync, recording, ai
    var id: String { rawValue }
    var title: String { switch self { case .general: "通用"; case .terminal: "终端"; case .monitoring: "监控"; case .files: "SFTP"; case .shortcuts: "快捷键"; case .security: "安全"; case .sync: "同步"; case .recording: "录制"; case .ai: "AI 助手" } }
    var symbol: String { switch self { case .general: "gearshape"; case .terminal: "terminal"; case .monitoring: "chart.xyaxis.line"; case .files: "folder"; case .shortcuts: "keyboard"; case .security: "lock.shield"; case .sync: "arrow.triangle.2.circlepath"; case .recording: "record.circle"; case .ai: "sparkles" } }
}

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("appAppearance") private var appearance = AppAppearance.system.rawValue
    @AppStorage("networkDisplayInBits") private var networkBits = false
    @AppStorage("hideIPInformation") private var hideIP = false
    @AppStorage("disableLocationLookup") private var disableLocation = false
    @AppStorage("confirmHostFingerprint") private var confirmFingerprint = true
    @AppStorage("workbench.localShellPath") private var localShell = ""
    @AppStorage("workbench.localShellEnvironment") private var localEnvironment = "inherit"
    @AppStorage("mac.settings.selectedPage") private var pageID = SettingsPage.general.rawValue
    @State private var timeoutText = ""
    @State private var timeoutError: String?
    @State private var timeoutSaved = false
    @FocusState private var timeoutFocused: Bool
    @State private var shortcutSearch = ""
    private var page: SettingsPage { SettingsPage(rawValue: pageID) ?? .general }
    private var pageSelection: Binding<SettingsPage?> {
        Binding(get: { page }, set: { if let value = $0 { pageID = value.rawValue } })
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: pageSelection) {
                Label($0.title, systemImage: $0.symbol).tag($0)
            }.listStyle(.sidebar).navigationTitle("设置")
                .navigationSplitViewColumnWidth(min: 155, ideal: 170, max: 210)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                Label(page.title, systemImage: page.symbol)
                    .font(.title2.weight(.semibold)).padding(20)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.background(Color.appGround)
        }
        .frame(minWidth: 820, idealWidth: 1000, minHeight: 620, idealHeight: 740)
        .preferredColorScheme((AppAppearance(rawValue: appearance) ?? .system).colorScheme)
        .onAppear { reloadTimeout() }
        .onChange(of: pageID) { _, _ in reloadTimeout() }
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
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox("本地终端") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                TextField("Shell 路径（留空使用登录 Shell）", text: $localShell)
                                Button("浏览…") { chooseShell() }
                            }
                            Picker("环境", selection: $localEnvironment) { Text("登录终端环境").tag("inherit"); Text("干净环境").tag("clean") }
                            if !localShell.isEmpty && (!localShell.hasPrefix("/") || !FileManager.default.isExecutableFile(atPath: localShell)) {
                                Text("请选择可执行文件的绝对路径。").font(.caption).foregroundStyle(Color.appError)
                            }
                        }.padding(10)
                    }.padding(.horizontal, 20).padding(.top, 16)
                    TerminalAppearanceSettingsView()
                }
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
            VStack {
                AppleSearchField(prompt: "查找快捷键", text: $shortcutSearch).padding(16)
                List {
                    ForEach(shortcuts.filter { shortcutSearch.isEmpty || $0.0.localizedCaseInsensitiveContains(shortcutSearch) }, id: \.0) { item in
                        LabeledContent(item.0) { Text(item.1).font(.body.monospaced()).foregroundStyle(.secondary) }.padding(.vertical, 6)
                    }
                }
                Text("快捷键与菜单栏保持一致；macOS 保留的系统快捷键由系统处理。").font(.caption).foregroundStyle(.secondary).padding(16)
            }
        case .security:
            Form {
                Section("SSH") {
                    Toggle("首次连接时确认主机指纹", isOn: $confirmFingerprint)
                    LabeledContent("默认连接超时") {
                        HStack {
                            TextField("5–300", text: $timeoutText).frame(width: 80)
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
                    Text("已有连接可在编辑主机中设置独立超时。主机密钥变化时继续要求重新确认。").font(.caption).foregroundStyle(.secondary)
                }
                Section("位置采集") {
                    Toggle("停止位置采集", isOn: $disableLocation)
                        .onChange(of: disableLocation) { _, disabled in if disabled { Task { await ServerLocationService.shared.clearCache() } } }
                    Text("停止向位置服务发起查询，并清理已缓存的位置。").font(.caption).foregroundStyle(.secondary)
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
    private func reloadTimeout() {
        timeoutText = MacSettingsValidation.timeoutText(PrivacySettings.connectTimeout)
        timeoutError = nil; timeoutSaved = false
    }
    private func saveTimeout() {
        guard let seconds = MacSettingsValidation.timeout(timeoutText) else {
            timeoutError = "请输入 5–300 之间的整数秒数。"; return
        }
        UserDefaults.standard.set(seconds, forKey: "sshConnectTimeout")
        timeoutText = String(seconds); timeoutError = nil; timeoutSaved = true; timeoutFocused = false
    }
    private func chooseShell() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.directoryURL = URL(fileURLWithPath: "/bin")
        if panel.runModal() == .OK, let url = panel.url { localShell = url.path }
    }
}

enum MacSettingsValidation {
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
