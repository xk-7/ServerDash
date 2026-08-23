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
    @State private var pendingHostKey: SSHHostKeyProbe?
    @State private var pendingValidationConfig: ServerConnectionConfig?

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
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(server == nil ? "添加服务器" : "编辑服务器")
                        .font(.title2.bold())
                    Text(isValidating ? "正在验证 SSH 连接与资源采集…" : "验证成功后才会保存，凭据仅存入 macOS Keychain")
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

                        if authentication == .password {
                            SecureField(
                                server == nil ? "密码" : "新密码（留空则不修改）",
                                text: $password
                            )
                        } else {
                            HStack {
                                TextField(
                                    "私钥路径（留空使用 SSH 默认配置）",
                                    text: $privateKeyPath
                                )
                                Button("选择…", action: choosePrivateKey)
                            }
                        }
                    }
                }

                Section("整理") {
                    TextField("分组", text: $groupName)
                    TextField("标签（用逗号分隔）", text: $tagsText)
                    TextField("备注", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
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
                Button(action: beginValidation) {
                    if isValidating {
                        HStack(spacing: 7) {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在验证")
                        }
                    } else {
                        Text(server == nil ? "连接" : "验证并保存")
                    }
                }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid || isValidating)
            }
            .padding(16)
        }
        .frame(width: 560, height: 590)
        .background(Color.appGround)
        .interactiveDismissDisabled(isValidating)
        .task {
            applySelectedIdentity()
        }
        .alert(
            "确认 SSH 主机指纹",
            isPresented: Binding(
                get: { pendingHostKey != nil },
                set: {
                    if !$0 {
                        pendingHostKey = nil
                        pendingValidationConfig = nil
                    }
                }
            ),
            presenting: pendingHostKey
        ) { probe in
            Button("取消", role: .cancel) {
                pendingHostKey = nil
                pendingValidationConfig = nil
            }
            Button("信任并验证") {
                trustHostKeyAndContinue(probe)
            }
        } message: { probe in
            Text(
                "\(probe.host):\(probe.port)\n\(probe.algorithm)  \(probe.fingerprint)\n\n请与服务商控制台显示的指纹核对后再信任。"
            )
        }
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (1...65_535).contains(port)
    }

    private var selectedIdentity: IdentityRecord? {
        guard let selectedIdentityID else { return nil }
        return identities.first { $0.id == selectedIdentityID }
    }

    private func applySelectedIdentity() {
        guard let identity = selectedIdentity else { return }
        username = identity.username
        authentication = identity.authentication
        if identity.authentication == .privateKey {
            privateKeyPath = sshKeys.first { $0.id == identity.sshKeyID }?.filePath ?? ""
        } else {
            privateKeyPath = ""
        }
        password = ""
    }

    private var draftConfig: ServerConnectionConfig {
        ServerConnectionConfig(
            id: draftID,
            credentialID: selectedIdentityID ?? draftID,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: port,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            authentication: authentication,
            privateKeyPath: privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func beginValidation() {
        guard isValid else { return }
        if authentication == .password,
           password.isEmpty,
           !KeychainService.hasPassword(for: draftConfig.credentialID) {
            errorMessage = ValidationError.missingPassword.localizedDescription
            return
        }

        let config = draftConfig
        errorMessage = nil
        isValidating = true

        Task {
            do {
                if let probe = try await SSHConnectionValidator.pendingHostKey(for: config) {
                    pendingValidationConfig = config
                    pendingHostKey = probe
                    isValidating = false
                } else {
                    try await validateAndCommit(config)
                }
            } catch {
                isValidating = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func trustHostKeyAndContinue(_ probe: SSHHostKeyProbe) {
        guard let config = pendingValidationConfig else { return }
        pendingHostKey = nil
        pendingValidationConfig = nil
        isValidating = true

        Task {
            do {
                try await SSHConnectionValidator.trust(probe)
                try await validateAndCommit(config)
            } catch {
                isValidating = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func validateAndCommit(_ config: ServerConnectionConfig) async throws {
        var previousPassword: String?
        var stagedPassword = false

        if authentication == .password, !password.isEmpty {
            previousPassword = try KeychainService.password(for: config.credentialID)
            try KeychainService.savePassword(password, for: config.credentialID)
            stagedPassword = true
        }

        do {
            let snapshot = try await SSHMonitoringService.collect(config)
            try commit(snapshot: snapshot)
        } catch {
            if stagedPassword {
                if let previousPassword {
                    try? KeychainService.savePassword(previousPassword, for: config.credentialID)
                } else {
                    try? KeychainService.deletePassword(for: config.credentialID)
                }
            }
            throw error
        }
    }

    private func commit(snapshot: ServerSnapshot) throws {
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
                identityID: selectedIdentityID
            )
            modelContext.insert(record)
        }

        do {
            if authentication == .privateKey {
                try KeychainService.deletePassword(for: record.id)
            }
            if selectedIdentityID != nil {
                try? KeychainService.deletePassword(for: record.id)
            }
            try modelContext.save()
            appState.applyValidatedSnapshot(snapshot, to: record)
            try? modelContext.save()
            onSave?(record)
            dismiss()
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

private enum ValidationError: LocalizedError {
    case missingPassword

    var errorDescription: String? {
        "使用密码认证时必须提供密码。"
    }
}

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("terminalFontSize") private var terminalFontSize = 13.0
    @AppStorage("terminalFontName") private var terminalFontName = "SF Mono"
    @AppStorage("confirmHostFingerprint") private var confirmHostFingerprint = true
    @AppStorage("appAppearance") private var appAppearanceRawValue = AppAppearance.system.rawValue

    var body: some View {
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
                    Text("每 5 秒").tag(5.0)
                    Text("每 10 秒").tag(10.0)
                    Text("每 30 秒").tag(30.0)
                    Text("每分钟").tag(60.0)
                }
            }

            Section("终端") {
                TextField("字体", text: $terminalFontName)
                HStack {
                    Slider(value: $terminalFontSize, in: 10...24, step: 1)
                    Text("\(Int(terminalFontSize)) pt")
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }
            }

            Section("安全") {
                Toggle("首次连接时确认主机指纹", isOn: $confirmHostFingerprint)
                    .disabled(true)
                Text("ServerDash 使用 OpenSSH 的 known_hosts 校验。主机指纹变化时，连接会被阻止。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .preferredColorScheme(appAppearance.colorScheme)
        .frame(width: 500, height: 420)
    }

    private var appAppearance: AppAppearance {
        AppAppearance(rawValue: appAppearanceRawValue) ?? .system
    }
}
