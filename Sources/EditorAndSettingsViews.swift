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
    @State private var advanced = SSHAdvancedSettingsDraft.default
    @State private var showsRoute = false

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
                        TextField("SSH 端口", value: $port, format: .number.grouping(.never))
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

                SSHAdvancedEditorSection(draft: $advanced)
                Section("连接路线") {
                    if server != nil {
                        Button("连接路线、跳板与代理…") { showsRoute = true }
                    } else {
                        Text("保存主机后，可配置跳板路线与 SOCKS5 / HTTP 代理。").font(.caption).foregroundStyle(.secondary)
                    }
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
        .sheet(isPresented: $showsRoute) { if let server { SSHConnectionRouteEditor(server: server) } }
        .interactiveDismissDisabled(isValidating)
        .task {
            applySelectedIdentity()
            if let server { advanced = SSHAdvancedSettingsRecord.load(serverID: server.id, in: modelContext) }
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
            var config = ConnectionConfigResolver.resolve(
                server: draft,
                identities: identities,
                keys: sshKeys
            )
            config.advancedSettings = advanced
            config.connectTimeout = TimeInterval(advanced.connectTimeout)
            return config
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
            hasPassphrase: !passphrase.isEmpty || hasStoredPassphrase,
            connectTimeout: TimeInterval(advanced.connectTimeout),
            advancedSettings: advanced
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
                message: "已成功连接 \(draftConfig.username)@\(draftConfig.host):\(draftConfig.port)，延迟 \(DisplayFormat.integer(Int(elapsed * 1_000))) ms。"
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
        try advanced.validate()
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
            try SSHAdvancedSettingsRecord.upsert(serverID: record.id, settings: advanced, in: modelContext)
            if !authentication.usesPassword {
                try KeychainService.deletePassword(for: record.id)
            }
            if selectedIdentityID != nil, !authentication.usesPassword {
                try? KeychainService.deletePassword(for: record.id)
            }
            try MachineOrganization.include(names: [record.groupName], tags: record.tags, context: modelContext)
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
