import AppKit
import SwiftData
import SwiftUI

enum ServerEditorFocusField: Hashable {
    case name
    case host
    case username
    case port
    case password
    case privateKey
    case passphrase
    case keepAliveInterval
    case keepAliveCount
    case connectTimeout
    case authenticationTimeout
    case beforeCommand
    case afterCommand
}

struct ServerEditorCredentialPlan: Equatable, Sendable {
    let mutations: [KeychainSecretMutation]

    static func make(
        passwordAccount: String,
        passphraseAccount: String,
        replacementPassword: String,
        removeStoredPassword: Bool,
        replacementPassphrase: String,
        removeStoredPassphrase: Bool
    ) -> Self {
        var mutations: [KeychainSecretMutation] = []
        if !replacementPassword.isEmpty {
            mutations.append(.replace(account: passwordAccount, value: replacementPassword))
        } else if removeStoredPassword {
            mutations.append(.remove(account: passwordAccount))
        }
        if !replacementPassphrase.isEmpty {
            mutations.append(.replace(account: passphraseAccount, value: replacementPassphrase))
        } else if removeStoredPassphrase {
            mutations.append(.remove(account: passphraseAccount))
        }
        return Self(mutations: mutations)
    }
}

struct ServerEditorRecordVersion: Equatable, Sendable {
    let id: UUID
    let name: String
    let host: String
    let port: Int
    let username: String
    let authentication: AuthenticationMethod
    let privateKeyPath: String
    let groupName: String
    let tagsText: String
    let notes: String
    let identityID: UUID?
    let enableDashboardMonitor: Bool
    let defaultSFTPPath: String

    init(_ record: ServerRecord) {
        id = record.id
        name = record.name
        host = record.host
        port = record.port
        username = record.username
        authentication = record.authentication
        privateKeyPath = record.privateKeyPath
        groupName = record.groupName
        tagsText = record.tagsText
        notes = record.notes
        identityID = record.identityID
        enableDashboardMonitor = record.enableDashboardMonitor
        defaultSFTPPath = record.defaultSFTPPath
    }

    func validate(_ record: ServerRecord?) throws {
        guard let record, self == ServerEditorRecordVersion(record) else {
            throw ServerEditorRecordConflictError()
        }
    }
}

struct ServerEditorIdentityVersion: Equatable, Sendable {
    let id: UUID
    let username: String
    let authenticationRawValue: String
    let sshKeyID: UUID?
    let updatedAt: Date

    init(_ record: IdentityRecord) {
        id = record.id
        username = record.username
        authenticationRawValue = record.authenticationRawValue
        sshKeyID = record.sshKeyID
        updatedAt = record.updatedAt
    }
}

struct ServerEditorSSHKeyVersion: Equatable, Sendable {
    let id: UUID
    let filePath: String
    let algorithm: String
    let fingerprint: String
    let storageModeRawValue: String
    let hasPassphrase: Bool
    let bookmarkData: Data?

    init(_ record: SSHKeyRecord) {
        id = record.id
        filePath = record.filePath
        algorithm = record.algorithm
        fingerprint = record.fingerprint
        storageModeRawValue = record.storageModeRawValue
        hasPassphrase = record.hasPassphrase
        bookmarkData = record.bookmarkData
    }
}

struct ServerEditorRouteVersion: Equatable, Sendable {
    let id: UUID
    let revision: UUID
    let routeJSON: String

    init(_ record: ConnectionRouteRecord) {
        id = record.id
        revision = record.revision
        routeJSON = record.routeJSON
    }
}

/// Captures every persisted record used to build the SSH test configuration.
/// The lease rejects cooperating editors while the test awaits; this value
/// check also catches deletions and writes from other model contexts.
struct ServerEditorConnectionDependencyVersion: Equatable, Sendable {
    let server: ServerEditorRecordVersion?
    let identityID: UUID?
    let identity: ServerEditorIdentityVersion?
    let sshKeyID: UUID?
    let sshKey: ServerEditorSSHKeyVersion?
    let routeServerID: UUID?
    let routes: [ServerEditorRouteVersion]

    init(
        server: ServerRecord?,
        identityID: UUID?,
        identity: IdentityRecord?,
        sshKeyID: UUID?,
        sshKey: SSHKeyRecord?,
        routes: [ConnectionRouteRecord]
    ) {
        self.server = server.map(ServerEditorRecordVersion.init)
        self.identityID = identityID
        self.identity = identity.map(ServerEditorIdentityVersion.init)
        self.sshKeyID = sshKeyID
        self.sshKey = sshKey.map(ServerEditorSSHKeyVersion.init)
        routeServerID = server?.id
        self.routes = routes
            .map(ServerEditorRouteVersion.init)
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    func validate(
        server currentServer: ServerRecord?,
        identity currentIdentity: IdentityRecord?,
        sshKey currentSSHKey: SSHKeyRecord?,
        routes currentRoutes: [ConnectionRouteRecord]
    ) throws {
        let currentRouteVersions = currentRoutes
            .map(ServerEditorRouteVersion.init)
            .sorted { $0.id.uuidString < $1.id.uuidString }
        guard server == currentServer.map(ServerEditorRecordVersion.init),
              identity == currentIdentity.map(ServerEditorIdentityVersion.init),
              sshKey == currentSSHKey.map(ServerEditorSSHKeyVersion.init),
              routes == currentRouteVersions else {
            throw ServerEditorRecordConflictError()
        }
    }
}

struct ServerEditorRecordConflictError: LocalizedError {
    var errorDescription: String? {
        "配置已在另一窗口更新，请重新载入后再试。"
    }
}

struct ServerEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appState: AppState
    @Query(sort: \IdentityRecord.name) private var identities: [IdentityRecord]
    @Query(sort: \SSHKeyRecord.name) private var sshKeys: [SSHKeyRecord]
    @Query private var connectionRoutes: [ConnectionRouteRecord]

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
    @State private var hasStoredPassword: Bool
    @State private var removeStoredPassword = false
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
    @State private var hasStoredPassphrase: Bool
    @State private var removeStoredPassphrase = false
    @State private var statusNote: String?
    @State private var sshTestFeedback: SSHTestFeedback?
    @State private var advanced = SSHAdvancedSettingsDraft.default
    @State private var showsRoute = false
    @FocusState private var focusedField: ServerEditorFocusField?

    init(server: ServerRecord?, onSave: ((ServerRecord) -> Void)? = nil) {
        let credentialID = server?.id ?? UUID()
        self.server = server
        self.onSave = onSave
        _draftID = State(initialValue: credentialID)
        _name = State(initialValue: server?.name ?? "")
        _host = State(initialValue: server?.host ?? "")
        _port = State(initialValue: server?.port ?? 22)
        _username = State(initialValue: server?.username ?? "root")
        _authentication = State(initialValue: server?.authentication ?? .privateKey)
        _selectedIdentityID = State(initialValue: server?.identityID)
        _privateKeyPath = State(initialValue: server?.privateKeyPath ?? "")
        _hasStoredPassword = State(initialValue: KeychainService.hasPassword(for: credentialID))
        _hasStoredPassphrase = State(initialValue: KeychainService.hasSecret(
            account: KeychainService.passphraseAccount(for: credentialID)
        ))
        _groupName = State(initialValue: server?.groupName ?? "默认分组")
        _tagsText = State(initialValue: server?.tagsText ?? "")
        _notes = State(initialValue: server?.notes ?? "")
        _enableDashboardMonitor = State(initialValue: server?.enableDashboardMonitor ?? true)
        _defaultSFTPPath = State(initialValue: server?.defaultSFTPPath ?? ".")
    }

    var body: some View {
        MacEditorSheetScaffold(
            title: server == nil ? "添加服务器" : "编辑服务器",
            accessibilityID: "mac.editor.server",
            saveTitle: isValidating ? "处理中" : "保存配置",
            errorMessage: errorMessage,
            saveDisabled: !isValid || isValidating,
            maxContentWidth: 720,
            scrollsContent: false,
            onCancel: {
                guard !isValidating else { return }
                dismiss()
            },
            onSave: { begin(.save) },
            onValidationError: focusFirstInvalidField
        ) {
            VStack(alignment: .leading, spacing: AppleDesign.Spacing.sm) {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Form {
                    Section("连接信息") {
                    TextField("名称", text: $name, prompt: Text("例如：生产服务器"))
                        .focused($focusedField, equals: .name)
                    TextField("主机地址", text: $host, prompt: Text("IP 地址或域名"))
                        .focused($focusedField, equals: .host)
                        .accessibilityIdentifier("mac.editor.server.host")
                    HStack {
                        TextField("用户名", text: $username)
                            .disabled(selectedIdentityID != nil)
                            .focused($focusedField, equals: .username)
                        TextField("SSH 端口", value: $port, format: .number.grouping(.never))
                            .frame(width: 120)
                            .focused($focusedField, equals: .port)
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
                                hasStoredPassword ? "新密码（留空则保留已保存密码）" : "密码",
                                text: $password
                            )
                            .focused($focusedField, equals: .password)
                            .onChange(of: password) { _, value in
                                if !value.isEmpty { removeStoredPassword = false }
                            }
                        }
                        if authentication.usesPrivateKey {
                            HStack {
                                TextField(
                                    "私钥路径（留空使用 SSH 默认配置）",
                                    text: $privateKeyPath
                                )
                                .focused($focusedField, equals: .privateKey)
                                Button("选择…", action: choosePrivateKey)
                            }
                            SecureField(
                                hasStoredPassphrase ? "新私钥口令（留空则保留已保存口令）" : "私钥口令（可选）",
                                text: $passphrase
                            )
                            .focused($focusedField, equals: .passphrase)
                            .onChange(of: passphrase) { _, value in
                                if !value.isEmpty { removeStoredPassphrase = false }
                            }
                        }
                        if hasStoredPassword {
                            Toggle("移除已保存密码", isOn: $removeStoredPassword)
                                .disabled(!password.isEmpty)
                            Text(removeStoredPassword ? "保存后将从本机 Keychain 删除密码。" : "留空会保留现有密码，即使认证方式改变也不会自动删除。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if hasStoredPassphrase {
                            Toggle("移除已保存私钥口令", isOn: $removeStoredPassphrase)
                                .disabled(!passphrase.isEmpty)
                            Text(removeStoredPassphrase ? "保存后将从本机 Keychain 删除口令。" : "留空会保留现有私钥口令。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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

                    SSHAdvancedEditorSection(draft: $advanced, focusedField: $focusedField)
                    Section("连接路线") {
                        if server != nil {
                            Button("连接路线、跳板与代理…") { showsRoute = true }
                        } else {
                            Text("保存主机后，可配置跳板路线与 SOCKS5 / HTTP 代理。").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
                .disabled(isValidating)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button("测试 SSH", systemImage: "network") { begin(.testSSH) }
                    .disabled(!isValid || isValidating)
            }
        }
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

    private func focusFirstInvalidField() {
        if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            focusedField = .host
        } else if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            focusedField = .username
        } else if !(1...65_535).contains(port) {
            focusedField = .port
        } else if !(10...300).contains(advanced.keepAliveInterval) {
            focusedField = .keepAliveInterval
        } else if !(1...10).contains(advanced.keepAliveCountMax) {
            focusedField = .keepAliveCount
        } else if !(5...300).contains(advanced.connectTimeout) {
            focusedField = .connectTimeout
        } else if !(10...120).contains(advanced.authenticationTimeout) {
            focusedField = .authenticationTimeout
        } else if advanced.beforeConnectCommand.utf8.count > 16_384 || advanced.beforeConnectCommand.contains("\0") {
            focusedField = .beforeCommand
        } else if advanced.afterConnectCommand.utf8.count > 16_384 || advanced.afterConnectCommand.contains("\0") {
            focusedField = .afterCommand
        } else {
            focusedField = .host
        }
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
        passphrase = ""
        removeStoredPassword = false
        removeStoredPassphrase = false
    }

    private var draftConfig: ServerConnectionConfig {
        let route: ConnectionRoute? = if let server {
            ConnectionConfigResolver.persistedRoute(
                for: server.id,
                routes: connectionRoutes
            )
        } else {
            .direct
        }
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
            config.route = route
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
            route: route,
            advancedSettings: advanced
        )
    }

    private func begin(_ action: EditorAction) {
        guard isValid else { return }
        if authentication.usesPassword,
           password.isEmpty,
           (removeStoredPassword || !KeychainService.hasPassword(for: draftConfig.credentialID)),
           action != .save {
            presentSSHTestFailure(ValidationError.missingPassword)
            return
        }

        errorMessage = nil
        statusNote = nil
        pendingAction = action
        if action == .save {
            do {
                try KeychainMutationTransaction.commit(
                    credentialMutations,
                    coordinationKeys: credentialCoordinationKeys
                ) {
                    try commit(snapshot: nil, status: .unverified)
                }
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
        switch action {
        case .save:
            try KeychainMutationTransaction.commit(
                credentialMutations,
                coordinationKeys: credentialCoordinationKeys
            ) {
                try commit(snapshot: nil, status: .unverified)
            }
        case .testSSH:
            let testedConfig = draftConfig
            let expectedVersion = connectionDependencyVersion(for: testedConfig)
            let elapsed = try await KeychainMutationTransaction.commitAsync(
                credentialMutations,
                coordinationKeys: ConnectionConfigurationCoordination.serverEditor(
                    draftID: draftID,
                    config: testedConfig
                )
            ) {
                let elapsed = try await appState.performTrustedConnection(
                    testedConfig,
                    source: .sshTest
                ) {
                    try await SSHConnectionTester.test(testedConfig)
                }
                try validateConnectionDependencies(expectedVersion)
                try commit(snapshot: nil, status: .sshReady)
                return elapsed
            }
            statusNote = "SSH 测试成功，配置已保存。"
            sshTestFeedback = SSHTestFeedback(
                succeeded: true,
                message: "已成功连接 \(testedConfig.username)@\(testedConfig.host):\(testedConfig.port)，延迟 \(DisplayFormat.integer(Int(elapsed * 1_000))) ms。"
            )
        }
        isValidating = false
    }

    private func connectionDependencyVersion(
        for config: ServerConnectionConfig
    ) -> ServerEditorConnectionDependencyVersion {
        let identityID = selectedIdentityID
        let keyID = config.sshKeyID
        let routes = server.map { server in
            connectionRoutes.filter { $0.serverID == server.id }
        } ?? []
        return ServerEditorConnectionDependencyVersion(
            server: server,
            identityID: identityID,
            identity: identityID.flatMap { id in identities.first { $0.id == id } },
            sshKeyID: keyID,
            sshKey: keyID.flatMap { id in sshKeys.first { $0.id == id } },
            routes: routes
        )
    }

    private func validateConnectionDependencies(
        _ expected: ServerEditorConnectionDependencyVersion
    ) throws {
        let allServers = try modelContext.fetch(FetchDescriptor<ServerRecord>())
        let currentServer = expected.server.flatMap { version in
            allServers.first { $0.id == version.id }
        }
        let allIdentities = try modelContext.fetch(FetchDescriptor<IdentityRecord>())
        let currentIdentity = expected.identityID.flatMap { id in
            allIdentities.first { $0.id == id }
        }
        let allKeys = try modelContext.fetch(FetchDescriptor<SSHKeyRecord>())
        let currentKey = expected.sshKeyID.flatMap { id in
            allKeys.first { $0.id == id }
        }
        let allRoutes = try modelContext.fetch(FetchDescriptor<ConnectionRouteRecord>())
        let currentRoutes = expected.routeServerID.map { serverID in
            allRoutes.filter { $0.serverID == serverID }
        } ?? []
        try expected.validate(
            server: currentServer,
            identity: currentIdentity,
            sshKey: currentKey,
            routes: currentRoutes
        )
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

    private var credentialMutations: [KeychainSecretMutation] {
        guard selectedIdentityID == nil else { return [] }
        return ServerEditorCredentialPlan.make(
            passwordAccount: draftID.uuidString,
            passphraseAccount: KeychainService.passphraseAccount(for: draftID),
            replacementPassword: password,
            removeStoredPassword: removeStoredPassword,
            replacementPassphrase: passphrase,
            removeStoredPassphrase: removeStoredPassphrase
        ).mutations
    }

    private var credentialCoordinationKeys: [String] {
        ConnectionConfigurationCoordination.serverEditor(
            draftID: draftID,
            config: draftConfig
        )
    }

    private func commit(snapshot: ServerSnapshot?, status: ServerVerificationStatus) throws {
        try advanced.validate()
        let record: ServerRecord
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
            try MachineOrganization.include(names: [record.groupName], tags: record.tags, context: modelContext)
            try modelContext.save()
            // Update only cached configuration and monitoring membership after
            // persistence succeeds. Existing terminal/session controllers keep
            // their current generation and consume this on the next connection.
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
            modelContext.rollback()
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
