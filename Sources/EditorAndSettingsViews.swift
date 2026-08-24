import AppKit
import SwiftData
import SwiftUI

struct ServerEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appState: AppState
    @Query(sort: \IdentityRecord.name) private var identities: [IdentityRecord]
    @Query(sort: \SSHKeyRecord.name) private var sshKeys: [SSHKeyRecord]

    let server: ServerRecord?
    var onSave: ((ServerRecord) -> Void)?

    @State private var draftID: UUID
    @State private var name: String
    @State private var host: String
    @State private var port: Int
    @State private var username: String
    @State private var authentication: AuthenticationMethod
    @State private var selectedIdentityID: UUID?
    @State private var password = ""
    @State private var privateKeyPath: String
    @State private var groupName: String
    @State private var tagsText: String
    @State private var notes: String
    @State private var errorMessage: String?
    @State private var isValidating = false
    @State private var pendingAction: EditorAction?
    @State private var enableDashboardMonitor = true
    @State private var defaultSFTPPath = "."
    @State private var passphrase = ""
    @State private var statusNote: String?
    @State private var sshTestFeedback: SSHTestFeedback?

    init(server: ServerRecord?, onSave: ((ServerRecord) -> Void)? = nil) {
        self.server = server
        self.onSave = onSave
        _draftID = State(initialValue: server?.id ?? UUID())
        _name = State(initialValue: server?.name ?? "")
        _host = State(initialValue: server?.host ?? "")
        _port = State(initialValue: server?.port ?? 22)
        _username = State(initialValue: server?.username ?? "root")
        _authentication = State(initialValue: server?.authentication ?? .privateKey)
        _selectedIdentityID = State(initialValue: server?.identityID)
        _privateKeyPath = State(initialValue: server?.privateKeyPath ?? "")
        _groupName = State(initialValue: server?.groupName ?? "默认分组")
        _tagsText = State(initialValue: server?.tagsText ?? "")
        _notes = State(initialValue: server?.notes ?? "")
        _enableDashboardMonitor = State(initialValue: server?.enableDashboardMonitor ?? true)
        _defaultSFTPPath = State(initialValue: server?.defaultSFTPPath ?? ".")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(server == nil ? "添加服务器" : "编辑服务器")
                        .font(.title2.bold())
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            Form {
                Section("连接信息") {
                    TextField("名称", text: $name, prompt: Text("例如：生产服务器"))
                    TextField("主机地址", text: $host, prompt: Text("IP 地址或域名"))
                    HStack {
                        TextField("用户名", text: $username)
                            .disabled(selectedIdentityID != nil)
                        TextField("SSH 端口", value: $port, format: .number)
                            .frame(width: 120)
                    }
                }

                Section("认证") {
                    Picker("登录身份", selection: $selectedIdentityID) {
                        Text("自定义").tag(UUID?.none)
                        ForEach(identities) { identity in
                            Text(identity.name).tag(Optional(identity.id))
                        }
                    }
                    .onChange(of: selectedIdentityID) {
                        applySelectedIdentity()
                    }

                    if let identity = selectedIdentity {
                        LabeledContent("用户名", value: identity.username)
                        LabeledContent("认证方式", value: identity.authentication.title)
                    } else {
                        Picker("认证方式", selection: $authentication) {
                            ForEach(AuthenticationMethod.allCases) { method in
                                Text(method.title).tag(method)
                            }
                        }
                        .pickerStyle(.segmented)

                        if authentication.usesPassword {
                            SecureField(
                                server == nil ? "密码" : "新密码（留空则不修改）",
                                text: $password
                            )
                        }
                        if authentication.usesPrivateKey {
                            HStack {
                                TextField(
                                    "私钥路径（留空使用 SSH 默认配置）",
                                    text: $privateKeyPath
                                )
                                Button("选择…", action: choosePrivateKey)
                            }
                            SecureField("私钥口令（可选）", text: $passphrase)
                        }
                    }
                }

                Section("整理") {
                    TextField("分组", text: $groupName)
                    TextField("标签（用逗号分隔）", text: $tagsText)
                    TextField("备注", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                    TextField("默认 SFTP 路径", text: $defaultSFTPPath)
                    Toggle("加入仪表盘自动监控", isOn: $enableDashboardMonitor)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(Color.appError)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .disabled(isValidating)

            Divider()

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isValidating)
                Button("测试 SSH") { begin(.testSSH) }
                    .disabled(!isValid || isValidating)
                Button(action: { begin(.save) }) {
                    if isValidating {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text("处理中")
                        }
                    } else {
                        Text("保存配置")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!isValid || isValidating)
            }
            .padding(16)
        }
        .frame(width: 620, height: 680)
        .background(Color.appGround)
        .interactiveDismissDisabled(isValidating)
        .task {
            applySelectedIdentity()
        }
        .alert(
            appState.pendingTrust?.replacing == true ? "主机密钥已变化" : "确认 SSH 主机指纹",
            isPresented: Binding(
                get: { appState.pendingTrust != nil },
                set: { _ in }
            )
        ) {
            Button("取消", role: .cancel) {
                if let requestID = appState.pendingTrust?.id {
                    appState.cancelTrust(requestID)
                }
            }
            Button(appState.pendingTrust?.replacing == true ? "替换指纹" : "信任") {
                if let request = appState.pendingTrust {
                    Task {
                        if let probe = await appState.resolveTrust(request.id) {
                            TrustedHostCatalog.upsert(probe: probe, in: modelContext)
                        }
                    }
                }
            }
        } message: {
            if let request = appState.pendingTrust {
                Text(hostTrustMessage(request))
            }
        }
        .alert(item: $sshTestFeedback) { feedback in
            Alert(
                title: Text(feedback.title),
                message: Text(feedback.message),
                dismissButton: .default(Text("好"))
            )
        }
    }

    private var statusText: String {
        if isValidating { return "正在处理连接…" }
        if let statusNote { return statusNote }
        return "可以先保存离线配置，SSH 测试可单独执行。"
    }

    private var isValid: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (1...65_535).contains(port)
    }

    private enum EditorAction {
        case save, testSSH
    }

    private var selectedIdentity: IdentityRecord? {
        guard let selectedIdentityID else { return nil }
        return identities.first { $0.id == selectedIdentityID }
    }

    private func applySelectedIdentity() {
        guard let identity = selectedIdentity else { return }
        username = identity.username
        authentication = identity.authentication
        if identity.authentication.usesPrivateKey {
            privateKeyPath = sshKeys.first { $0.id == identity.sshKeyID }?.filePath ?? ""
        } else {
            privateKeyPath = ""
        }
        password = ""
    }

    private var draftConfig: ServerConnectionConfig {
        if let identity = selectedIdentity {
            let draft = ServerRecord(
                id: draftID,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                port: port,
                username: identity.username,
                authentication: identity.authentication,
                identityID: identity.id
            )
            return ConnectionConfigResolver.resolve(
                server: draft,
                identities: identities,
                keys: sshKeys
            )
        }
        let hasStoredPassphrase = (try? KeychainService.secret(
            account: KeychainService.passphraseAccount(for: draftID)
        )) != nil
        return ServerConnectionConfig(
            id: draftID,
            credentialID: draftID,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: port,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            authentication: authentication,
            privateKeyPath: privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines),
            sshKeyID: draftID,
            hasPassphrase: !passphrase.isEmpty || hasStoredPassphrase
        )
    }

    private func begin(_ action: EditorAction) {
        guard isValid else { return }
        if authentication.usesPassword,
           password.isEmpty,
           !KeychainService.hasPassword(for: draftConfig.credentialID),
           action != .save {
            presentSSHTestFailure(ValidationError.missingPassword)
            return
        }

        errorMessage = nil
        statusNote = nil
        pendingAction = action
        if action == .save {
            do {
                try persistSecrets()
                try commit(snapshot: nil, status: .unverified)
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }

        isValidating = true
        Task {
            do {
                try await perform(action)
            } catch {
                isValidating = false
                if action == .testSSH {
                    presentSSHTestFailure(error)
                } else {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func perform(_ action: EditorAction) async throws {
        try persistSecrets()
        switch action {
        case .save:
            try commit(snapshot: nil, status: .unverified)
        case .testSSH:
            let config = draftConfig
            let elapsed = try await appState.performTrustedConnection(
                config,
                source: .sshTest
            ) {
                try await SSHConnectionTester.test(config)
            }
            try commit(snapshot: nil, status: .sshReady)
            statusNote = "SSH 测试成功，配置已保存。"
            sshTestFeedback = SSHTestFeedback(
                succeeded: true,
                message: "已成功连接 \(draftConfig.username)@\(draftConfig.host):\(draftConfig.port)，延迟 \(Int(elapsed * 1_000)) ms。"
            )
        }
        isValidating = false
    }

    private func presentSSHTestFailure(_ error: Error) {
        errorMessage = error.localizedDescription
        sshTestFeedback = SSHTestFeedback(
            succeeded: false,
            message: error.localizedDescription
        )
    }

    private func hostTrustMessage(_ request: HostTrustRequest) -> String {
        if request.replacing {
            return "来源：\(request.source.title)\n旧指纹：\(request.oldFingerprint ?? "未知")\n新指纹：\(request.probe.fingerprint)\n替换前请确认这是你预期的主机。"
        }
        return "来源：\(request.source.title)\n\(request.probe.host):\(request.probe.port)\n\(request.probe.algorithm) \(request.probe.fingerprint)"
    }

    private func persistSecrets() throws {
        if authentication.usesPassword, !password.isEmpty {
            try KeychainService.savePassword(password, for: draftConfig.credentialID)
        }
        if !passphrase.isEmpty {
            try KeychainService.saveSecret(
                passphrase,
                account: KeychainService.passphraseAccount(
                    for: selectedIdentity?.sshKeyID ?? draftID
                )
            )
        }
    }

    private func commit(snapshot: ServerSnapshot?, status: ServerVerificationStatus) throws {
        let record: ServerRecord
        let isNewRecord = server == nil
        if let server {
            record = server
            record.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            record.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
            record.port = port
            record.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
            record.authentication = authentication
            record.privateKeyPath = privateKeyPath
            record.groupName = groupName.isEmpty ? "默认分组" : groupName
            record.tagsText = tagsText
            record.notes = notes
            record.identityID = selectedIdentityID
            record.enableDashboardMonitor = enableDashboardMonitor
            record.defaultSFTPPath = defaultSFTPPath.isEmpty ? "." : defaultSFTPPath
            record.verificationStatus = status
        } else {
            record = ServerRecord(
                id: draftID,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                port: port,
                username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                authentication: authentication,
                privateKeyPath: privateKeyPath,
                groupName: groupName.isEmpty ? "默认分组" : groupName,
                tagsText: tagsText,
                notes: notes,
                identityID: selectedIdentityID,
                verificationStatus: status,
                enableDashboardMonitor: enableDashboardMonitor,
                defaultSFTPPath: defaultSFTPPath.isEmpty ? "." : defaultSFTPPath
            )
            modelContext.insert(record)
        }

        do {
            if !authentication.usesPassword {
                try KeychainService.deletePassword(for: record.id)
            }
            if selectedIdentityID != nil, !authentication.usesPassword {
                try? KeychainService.deletePassword(for: record.id)
            }
            try modelContext.save()
            appState.cacheConfig(draftConfig)
            if let snapshot {
                appState.applyValidatedSnapshot(snapshot, to: record)
                try? modelContext.save()
            } else {
                appState.initializeRuntime(for: record)
            }
            if pendingAction == .save {
                onSave?(record)
                dismiss()
            }
        } catch {
            if isNewRecord {
                modelContext.delete(record)
            }
            throw error
        }
    }

    private func choosePrivateKey() {
        let panel = NSOpenPanel()
        panel.title = "选择 SSH 私钥"
        panel.prompt = "选择"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK {
            privateKeyPath = panel.url?.path ?? privateKeyPath
        }
    }
}

private struct SSHTestFeedback: Identifiable {
    let id = UUID()
    let succeeded: Bool
    let message: String

    var title: String {
        succeeded ? "SSH 连接成功" : "SSH 连接失败"
    }
}

private enum ValidationError: LocalizedError {
    case missingPassword

    var errorDescription: String? {
        "使用密码认证时必须提供密码。"
    }
}

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("confirmHostFingerprint") private var confirmHostFingerprint = true
    @AppStorage("appAppearance") private var appAppearanceRawValue = AppAppearance.system.rawValue
    @AppStorage("networkDisplayInBits") private var networkDisplayInBits = false
    @AppStorage("hideIPInformation") private var hideIPInformation = false
    @AppStorage("disableLocationLookup") private var disableLocationLookup = false
    @AppStorage("sshConnectTimeout") private var sshConnectTimeout = 8.0

    var body: some View {
        TabView {
            Form {
            Section("外观") {
                Picker("显示模式", selection: $appAppearanceRawValue) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Label(appearance.title, systemImage: appearance.symbol)
                            .tag(appearance.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Text(appAppearance == .system ? "外观会随 macOS 的浅色或深色设置自动变化。" : "此设置仅影响 ServerDash。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("监控") {
                Picker(
                    "自动刷新",
                    selection: Binding(
                        get: { appState.refreshInterval },
                        set: { appState.updateRefreshInterval($0) }
                    )
                ) {
                    Text("关闭").tag(0.0)
                    Text("每 1 秒").tag(1.0)
                    Text("每 5 秒").tag(5.0)
                    Text("每 10 秒").tag(10.0)
                    Text("每 30 秒").tag(30.0)
                    Text("每分钟").tag(60.0)
                }
                if appState.refreshInterval > 0 && appState.refreshInterval < 5 {
                    Text("低于 5 秒会增加服务器和本机负载。")
                        .font(.caption)
                        .foregroundStyle(Color.appWarning)
                }
            }

            Section("监控面板") {
                Toggle("网络速度使用 bit/s", isOn: $networkDisplayInBits)
                Toggle("隐藏 IP 与位置信息", isOn: $hideIPInformation)
                Toggle("停止位置采集", isOn: $disableLocationLookup)
                    .onChange(of: disableLocationLookup) {
                        if disableLocationLookup {
                            Task { await ServerLocationService.shared.clearCache() }
                        }
                    }
                Text("停止采集后，服务器不会再请求 ipinfo.io，并清理本机缓存。隐藏 IP 会影响界面、Markdown 和诊断。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("安全") {
                Toggle("首次连接时确认主机指纹", isOn: $confirmHostFingerprint)
                HStack {
                    Text("SSH 超时")
                    Slider(value: $sshConnectTimeout, in: 5...300, step: 5)
                    Text("\(Int(sshConnectTimeout))s")
                        .monospacedDigit()
                        .frame(width: 44)
                }
                Text("主机指纹保存在应用专属 known_hosts。密钥变化时默认拒绝，需同时看到新旧指纹后才能替换。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("通用", systemImage: "gearshape")
            }

            TerminalAppearanceSettingsView()
                .tabItem {
                    Label("终端主题", systemImage: "terminal")
                }
        }
        .preferredColorScheme(appAppearance.colorScheme)
        .frame(width: 920, height: 720)
    }

    private var appAppearance: AppAppearance {
        AppAppearance(rawValue: appAppearanceRawValue) ?? .system
    }
}
