import AppKit
import SwiftData
import SwiftUI

enum KeychainSecretMutation: Equatable, Sendable {
    case replace(account: String, value: String)
    case remove(account: String)

    var account: String {
        switch self {
        case let .replace(account, _), let .remove(account): account
        }
    }

    func apply() throws {
        switch self {
        case let .replace(account, value):
            try KeychainService.saveSecret(value, account: account)
        case let .remove(account):
            try KeychainService.deleteSecret(account: account)
        }
    }
}

private struct KeychainMutationRollbackError: LocalizedError {
    var errorDescription: String? {
        "保存失败，且无法恢复本机 Keychain 凭据。请在再次保存前检查钥匙串访问状态。"
    }
}

private struct KeychainMutationInProgressError: LocalizedError {
    var errorDescription: String? {
        "此配置正在另一个窗口中验证或保存，请稍后重试。"
    }
}

/// Applies Keychain changes before the model commit. Accounts and explicit
/// coordination keys stay exclusively leased across an async operation, so a
/// second editor cannot persist a model that disagrees with the leased secret.
enum KeychainMutationTransaction {
    private struct Snapshot: Sendable {
        let account: String
        let originalValue: String?
        let appliedValue: String?
    }

    private struct Lease: Sendable {
        let keys: [String]
    }

    private struct Transaction: Sendable {
        let lease: Lease
        let snapshots: [Snapshot]
    }

    /// The lock protects only lease bookkeeping and is never held while
    /// touching Keychain, saving SwiftData, or awaiting network work.
    private final class Coordinator: @unchecked Sendable {
        private let lock = NSLock()
        private var activeKeys = Set<String>()

        func acquire(_ keys: [String]) throws -> Lease {
            let normalizedKeys = Array(Set(keys.filter { !$0.isEmpty })).sorted()
            lock.lock()
            defer { lock.unlock() }
            guard activeKeys.isDisjoint(with: normalizedKeys) else {
                throw KeychainMutationInProgressError()
            }
            activeKeys.formUnion(normalizedKeys)
            return Lease(keys: normalizedKeys)
        }

        func release(_ lease: Lease) {
            lock.lock()
            activeKeys.subtract(lease.keys)
            lock.unlock()
        }
    }

    private static let coordinator = Coordinator()

    static func commit(
        _ mutations: [KeychainSecretMutation],
        coordinationKeys: [String] = [],
        persistModel: () throws -> Void
    ) throws {
        let transaction = try begin(mutations, coordinationKeys: coordinationKeys)
        defer { coordinator.release(transaction.lease) }

        do {
            try persistModel()
        } catch {
            let originalError = error
            try rollback(transaction)
            throw originalError
        }
    }

    @MainActor
    static func commitAsync<Value>(
        _ mutations: [KeychainSecretMutation],
        coordinationKeys: [String] = [],
        operation: () async throws -> Value
    ) async throws -> Value {
        let transaction = try begin(mutations, coordinationKeys: coordinationKeys)
        defer { coordinator.release(transaction.lease) }

        do {
            return try await operation()
        } catch {
            let originalError = error
            try rollback(transaction)
            throw originalError
        }
    }

    private static func begin(
        _ mutations: [KeychainSecretMutation],
        coordinationKeys: [String]
    ) throws -> Transaction {
        var seen = Set<String>()
        let accounts = mutations.compactMap { mutation -> String? in
            seen.insert(mutation.account).inserted ? mutation.account : nil
        }
        let lease = try coordinator.acquire(coordinationKeys + accounts)

        var originals: [Snapshot] = []
        var didStartApplyingMutations = false
        do {
            for account in accounts {
                originals.append(Snapshot(
                    account: account,
                    originalValue: try KeychainService.secret(account: account),
                    appliedValue: nil
                ))
            }

            didStartApplyingMutations = true
            for mutation in mutations {
                try mutation.apply()
            }

            let snapshots = try originals.map { snapshot in
                Snapshot(
                    account: snapshot.account,
                    originalValue: snapshot.originalValue,
                    appliedValue: try KeychainService.secret(account: snapshot.account)
                )
            }
            return Transaction(lease: lease, snapshots: snapshots)
        } catch {
            let originalError = error
            defer { coordinator.release(lease) }
            guard didStartApplyingMutations else { throw originalError }
            if restore(originals.reversed(), validatingAppliedValue: false) {
                throw originalError
            }
            throw KeychainMutationRollbackError()
        }
    }

    private static func rollback(_ transaction: Transaction) throws {
        guard restore(transaction.snapshots.reversed(), validatingAppliedValue: true) else {
            throw KeychainMutationRollbackError()
        }
    }

    private static func restore<S: Sequence>(
        _ snapshots: S,
        validatingAppliedValue: Bool
    ) -> Bool where S.Element == Snapshot {
        var succeeded = true
        for snapshot in snapshots {
            do {
                if validatingAppliedValue,
                   try KeychainService.secret(account: snapshot.account) != snapshot.appliedValue {
                    // A write outside this coordinator happened while an async
                    // operation was in flight. Preserve that newer value.
                    continue
                }
                try write(snapshot.originalValue, account: snapshot.account)
            } catch {
                succeeded = false
            }
        }
        return succeeded
    }

    private static func write(_ value: String?, account: String) throws {
        if let value {
            try KeychainService.saveSecret(value, account: account)
        } else {
            try KeychainService.deleteSecret(account: account)
        }
    }
}

/// Stable, process-local lease keys for model records that influence a
/// connection but are not themselves Keychain accounts. Editors use these in
/// addition to the concrete secret accounts so metadata-only saves cannot
/// race an in-flight connection test.
enum ConnectionConfigurationCoordination {
    static func serverRecord(_ id: UUID) -> String {
        "connection-model.server.\(id.uuidString)"
    }

    static func identityRecord(_ id: UUID) -> String {
        "connection-model.identity.\(id.uuidString)"
    }

    static func sshKeyRecord(_ id: UUID) -> String {
        "connection-model.ssh-key.\(id.uuidString)"
    }

    static func routeRecords(for serverID: UUID) -> String {
        "connection-model.routes.\(serverID.uuidString)"
    }

    static func sshKey(_ id: UUID) -> [String] {
        [
            sshKeyRecord(id),
            KeychainService.importedKeyAccount(for: id),
            KeychainService.passphraseAccount(for: id)
        ]
    }

    static func serverEditor(draftID: UUID, config: ServerConnectionConfig) -> [String] {
        var keys = [
            serverRecord(draftID),
            routeRecords(for: draftID),
            draftID.uuidString,
            config.credentialID.uuidString,
            identityRecord(config.credentialID)
        ]
        if let keyID = config.sshKeyID {
            keys.append(contentsOf: sshKey(keyID))
        }
        return keys
    }
}

struct IdentityManagementView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \IdentityRecord.name) private var identities: [IdentityRecord]
    @Query(sort: \SSHKeyRecord.name) private var keys: [SSHKeyRecord]
    @Query(sort: \ServerRecord.name) private var servers: [ServerRecord]

    @State private var showingNewIdentity = false
    @State private var editingIdentity: IdentityRecord?
    @State private var identityPendingDeletion: IdentityRecord?
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppleDesign.Spacing.lg) {
                AppleWorkspaceHeader(
                    title: "身份", subtitle: "在多台服务器间安全复用认证凭据。",
                    symbol: "person.crop.circle.badge.checkmark"
                ) {
                    Button("新建身份", systemImage: "plus") {
                        showingNewIdentity = true
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                }

                if identities.isEmpty {
                    ContentUnavailableView {
                        Label("还没有身份", systemImage: "person.crop.circle.badge.checkmark")
                    } description: {
                        Text("创建身份后，可将同一凭据安全地关联到多台服务器。")
                    } actions: {
                        Button("新建身份") { showingNewIdentity = true }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, minHeight: 360)
                    .applePanel()
                } else {
                    AppleUnifiedPanel {
                        ForEach(Array(identities.enumerated()), id: \.element.id) { index, identity in
                            Button {
                                editingIdentity = identity
                            } label: {
                                IdentityRow(
                                    identity: identity,
                                    key: keys.first { $0.id == identity.sshKeyID },
                                    serverCount: servers.filter { $0.identityID == identity.id }.count
                                )
                            }
                            .buttonStyle(.plain)
                            .appleInteractiveSurface(radius: AppleDesign.Radius.chip)
                            .contextMenu {
                                Button("编辑身份", systemImage: "pencil") {
                                    editingIdentity = identity
                                }
                                Divider()
                                Button("删除身份", systemImage: "trash", role: .destructive) {
                                    requestDelete(identity)
                                }
                            }
                            if index < identities.count - 1 {
                                Divider().padding(.leading, 56)
                            }
                        }
                    }
                }
            }
            .padding(AppleDesign.Spacing.lg)
            .frame(maxWidth: AppleDesign.Layout.readingWidth)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showingNewIdentity) {
            IdentityEditorView(identity: nil, keys: keys)
        }
        .sheet(item: $editingIdentity) { identity in
            IdentityEditorView(identity: identity, keys: keys)
        }
        .confirmationDialog(
            "删除 \(identityPendingDeletion?.name ?? "身份")？",
            isPresented: Binding(
                get: { identityPendingDeletion != nil },
                set: { if !$0 { identityPendingDeletion = nil } }
            )
        ) {
            Button("删除身份", role: .destructive) {
                guard let identity = identityPendingDeletion else { return }
                do {
                    modelContext.delete(identity)
                    try KeychainMutationTransaction.commit([
                        .remove(account: identity.id.uuidString)
                    ], coordinationKeys: [
                        ConnectionConfigurationCoordination.identityRecord(identity.id)
                    ]) {
                        try modelContext.save()
                    }
                    identityPendingDeletion = nil
                } catch {
                    modelContext.rollback()
                    errorMessage = error.localizedDescription
                }
            }
        }
        .alert(
            "无法删除身份",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func requestDelete(_ identity: IdentityRecord) {
        let count = ResourceDeletionPolicy.identityReferenceCount(identity.id, in: servers)
        guard count == 0 else {
            errorMessage = "此身份正被 \(DisplayFormat.integer(count)) 台服务器使用，请先更改服务器身份。"
            return
        }
        identityPendingDeletion = identity
    }
}

private struct IdentityRow: View {
    let identity: IdentityRecord
    let key: SSHKeyRecord?
    let serverCount: Int

    var body: some View {
        HStack(spacing: AppleDesign.Spacing.sm) {
            Image(systemName: identity.authentication.usesPassword && !identity.authentication.usesPrivateKey ? "lock" : "key")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: AppleDesign.Spacing.xxs) {
                Text(identity.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(identity.username)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(identity.authentication.title + (identity.authentication.usesPrivateKey ? " · \(key?.name ?? "未选择密钥")" : ""))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: 200, alignment: .trailing)
            Text("\(DisplayFormat.integer(serverCount)) 台机器")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 70, alignment: .trailing)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, AppleDesign.Spacing.md)
        .frame(minHeight: 62)
        .contentShape(Rectangle())
    }
}

private enum IdentityEditorFocusField: Hashable { case name, username, password }

struct IdentityEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var servers: [ServerRecord]

    let identity: IdentityRecord?
    let keys: [SSHKeyRecord]

    @State private var draftID: UUID
    @State private var name: String
    @State private var username: String
    @State private var authentication: AuthenticationMethod
    @State private var sshKeyID: UUID?
    @State private var password = ""
    @State private var hasStoredPassword: Bool
    @State private var removeStoredPassword = false
    @State private var notes: String
    @State private var errorMessage: String?
    @FocusState private var focusedField: IdentityEditorFocusField?

    init(identity: IdentityRecord?, keys: [SSHKeyRecord]) {
        self.identity = identity
        self.keys = keys
        _draftID = State(initialValue: identity?.id ?? UUID())
        _name = State(initialValue: identity?.name ?? "")
        _username = State(initialValue: identity?.username ?? "root")
        _authentication = State(initialValue: identity?.authentication ?? .privateKey)
        _sshKeyID = State(initialValue: identity?.sshKeyID)
        _hasStoredPassword = State(initialValue: identity.map { KeychainService.hasPassword(for: $0.id) } ?? false)
        _notes = State(initialValue: identity?.notes ?? "")
    }

    var body: some View {
        MacEditorSheetScaffold(
            title: identity == nil ? "新建身份" : "编辑身份",
            accessibilityID: "mac.editor.identity",
            errorMessage: errorMessage,
            saveDisabled: !isValid,
            maxContentWidth: 620,
            scrollsContent: false,
            onCancel: { dismiss() },
            onSave: save,
            onValidationError: focusFirstInvalidField
        ) {
            Form {
                Section("身份") {
                    TextField("名称", text: $name)
                        .focused($focusedField, equals: .name)
                    TextField("用户名", text: $username)
                        .focused($focusedField, equals: .username)
                        .accessibilityIdentifier("mac.editor.identity.username")
                    Picker("认证方式", selection: $authentication) {
                        ForEach(AuthenticationMethod.allCases) { method in
                            Text(method.title).tag(method)
                        }
                    }
                }

                Section("凭据") {
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
                        Picker("SSH 密钥", selection: $sshKeyID) {
                            Text("请选择").tag(UUID?.none)
                            ForEach(keys) { key in
                                Text(key.name).tag(Optional(key.id))
                            }
                        }
                        if keys.isEmpty {
                            Text("请先在“SSH 密钥”中导入密钥。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if hasStoredPassword {
                        Toggle("移除已保存密码", isOn: $removeStoredPassword)
                            .disabled(!password.isEmpty)
                        Text(removeStoredPassword ? "保存后将从本机 Keychain 删除密码。" : "留空会保留本机 Keychain 中的现有密码，即使切换认证方式也不会自动删除。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    TextField("备注", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (!authentication.usesPrivateKey || sshKeyID != nil)
    }

    private func focusFirstInvalidField() {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            focusedField = .name
        } else if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            focusedField = .username
        } else {
            focusedField = .password
        }
    }

    private func save() {
        guard isValid else { return }
        if authentication == .password,
           password.isEmpty,
           (!KeychainService.hasPassword(for: draftID) || removeStoredPassword) {
            errorMessage = "密码身份必须提供密码。"
            return
        }

        do {
            let record = identity ?? IdentityRecord(
                id: draftID,
                name: name,
                username: username,
                authentication: authentication
            )
            if identity == nil {
                modelContext.insert(record)
            }
            record.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            record.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
            record.authentication = authentication
            record.sshKeyID = authentication.usesPrivateKey ? sshKeyID : nil
            record.notes = notes
            record.updatedAt = .now

            let credentialMutations = IdentityPasswordUpdate.mutations(
                replacement: password,
                removeStoredPassword: removeStoredPassword,
                identityID: record.id
            )

            let selectedKey = keys.first { $0.id == record.sshKeyID }
            for server in servers where server.identityID == record.id {
                server.username = record.username
                server.authentication = record.authentication
                server.privateKeyPath = selectedKey?.filePath ?? ""
            }
            try KeychainMutationTransaction.commit(
                credentialMutations,
                coordinationKeys: [ConnectionConfigurationCoordination.identityRecord(record.id)]
            ) {
                try modelContext.save()
            }
            dismiss()
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }
}

enum IdentityPasswordUpdate {
    /// Applies only an explicit credential change. An empty replacement keeps
    /// the existing secret even when the identity's authentication changes.
    static func apply(
        replacement: String,
        removeStoredPassword: Bool,
        identityID: UUID
    ) throws {
        for mutation in mutations(
            replacement: replacement,
            removeStoredPassword: removeStoredPassword,
            identityID: identityID
        ) {
            try mutation.apply()
        }
    }

    static func mutations(
        replacement: String,
        removeStoredPassword: Bool,
        identityID: UUID
    ) -> [KeychainSecretMutation] {
        if !replacement.isEmpty {
            return [.replace(account: identityID.uuidString, value: replacement)]
        }
        if removeStoredPassword {
            return [.remove(account: identityID.uuidString)]
        }
        return []
    }
}

struct SSHKeyManagementView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SSHKeyRecord.name) private var keys: [SSHKeyRecord]
    @Query private var identities: [IdentityRecord]

    @State private var showingNewKey = false
    @State private var editingKey: SSHKeyRecord?
    @State private var keyPendingDeletion: SSHKeyRecord?
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppleDesign.Spacing.lg) {
                AppleWorkspaceHeader(
                    title: "SSH 密钥", subtitle: "管理本地密钥引用或保存在钥匙串中的私钥。",
                    symbol: "key"
                ) {
                    Button("导入密钥", systemImage: "plus") { showingNewKey = true }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("k", modifiers: [.command, .shift])
                }

                if keys.isEmpty {
                    ContentUnavailableView {
                        Label("还没有 SSH 密钥", systemImage: "key")
                    } description: {
                        Text("导入本地私钥文件后，可在身份中复用。")
                    } actions: {
                        Button("导入密钥") { showingNewKey = true }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, minHeight: 360)
                    .applePanel()
                } else {
                    AppleUnifiedPanel {
                        ForEach(Array(keys.enumerated()), id: \.element.id) { index, key in
                            Button {
                                editingKey = key
                            } label: {
                                SSHKeyRow(
                                    key: key,
                                    identityCount: identities.filter { $0.sshKeyID == key.id }.count
                                )
                            }
                            .buttonStyle(.plain)
                            .appleInteractiveSurface(radius: AppleDesign.Radius.chip)
                            .contextMenu {
                                Button("编辑密钥", systemImage: "pencil") { editingKey = key }
                                Divider()
                                Button("删除密钥", systemImage: "trash", role: .destructive) {
                                    requestDelete(key)
                                }
                            }
                            if index < keys.count - 1 {
                                Divider().padding(.leading, 56)
                            }
                        }
                    }
                }
            }
            .padding(AppleDesign.Spacing.lg)
            .frame(maxWidth: AppleDesign.Layout.readingWidth)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showingNewKey) {
            SSHKeyEditorView(key: nil)
        }
        .sheet(item: $editingKey) { key in
            SSHKeyEditorView(key: key)
        }
        .confirmationDialog(
            "删除 \(keyPendingDeletion?.name ?? "密钥")？",
            isPresented: Binding(
                get: { keyPendingDeletion != nil },
                set: { if !$0 { keyPendingDeletion = nil } }
            )
        ) {
            Button("删除密钥", role: .destructive) {
                guard let key = keyPendingDeletion else { return }
                do {
                    modelContext.delete(key)
                    try KeychainMutationTransaction.commit([
                        .remove(account: KeychainService.importedKeyAccount(for: key.id)),
                        .remove(account: KeychainService.passphraseAccount(for: key.id))
                    ], coordinationKeys: ConnectionConfigurationCoordination.sshKey(key.id)) {
                        try modelContext.save()
                    }
                    keyPendingDeletion = nil
                } catch {
                    modelContext.rollback()
                    errorMessage = error.localizedDescription
                }
            }
        }
        .alert(
            "无法删除密钥",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func requestDelete(_ key: SSHKeyRecord) {
        let count = ResourceDeletionPolicy.keyReferenceCount(key.id, in: identities)
        guard count == 0 else {
            errorMessage = "此密钥正被 \(DisplayFormat.integer(count)) 个身份使用，请先更改身份配置。"
            return
        }
        keyPendingDeletion = key
    }
}

private struct SSHKeyRow: View {
    let key: SSHKeyRecord
    let identityCount: Int

    var body: some View {
        HStack(spacing: AppleDesign.Spacing.sm) {
            Image(systemName: "key")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: AppleDesign.Spacing.xxs) {
                Text(key.name).font(.headline).lineLimit(1)
                Text(key.fingerprint)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(key.algorithm)
                .font(.caption.weight(.semibold))
            Text("\(DisplayFormat.integer(identityCount)) 个身份")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 72, alignment: .trailing)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, AppleDesign.Spacing.md)
        .frame(minHeight: 62)
        .contentShape(Rectangle())
    }
}

enum SSHKeyPassphraseEdit: Equatable, Sendable {
    case preserve
    case replace(String)
    case remove
}

struct SSHKeyEditorCredentialPlan: Equatable, Sendable {
    let reuseImportedMaterial: Bool
    let requiresExplicitExternalFile: Bool
    let passphraseEdit: SSHKeyPassphraseEdit
    let resultingHasPassphrase: Bool

    static func make(
        existingStorageMode: SSHKeyStorageMode?,
        existingFilePath: String?,
        proposedFilePath: String,
        importIntoApp: Bool,
        newPassphrase: String,
        removeStoredPassphrase: Bool,
        hasStoredPassphrase: Bool,
        explicitFileSelection: Bool = false
    ) -> Self {
        let passphraseEdit: SSHKeyPassphraseEdit
        if !newPassphrase.isEmpty {
            passphraseEdit = .replace(newPassphrase)
        } else if removeStoredPassphrase, hasStoredPassphrase {
            passphraseEdit = .remove
        } else {
            passphraseEdit = .preserve
        }
        let resultingHasPassphrase = switch passphraseEdit {
        case .preserve: hasStoredPassphrase
        case .replace: true
        case .remove: false
        }
        return Self(
            reuseImportedMaterial: existingStorageMode == .imported
                && importIntoApp
                && proposedFilePath == existingFilePath
                && !explicitFileSelection,
            requiresExplicitExternalFile: existingStorageMode == .imported
                && !importIntoApp
                && !explicitFileSelection,
            passphraseEdit: passphraseEdit,
            resultingHasPassphrase: resultingHasPassphrase
        )
    }

    func passphraseMutation(for keyID: UUID) -> KeychainSecretMutation? {
        let account = KeychainService.passphraseAccount(for: keyID)
        return switch passphraseEdit {
        case .preserve: nil
        case let .replace(value): .replace(account: account, value: value)
        case .remove: .remove(account: account)
        }
    }

    func applyPassphrase(to keyID: UUID) throws {
        if let mutation = passphraseMutation(for: keyID) {
            try mutation.apply()
        }
    }
}

private enum SSHKeyEditorError: LocalizedError {
    case importedMaterialUnavailable
    case externalFileRequired
    case pastedMaterialRequiresImport

    var errorDescription: String? {
        switch self {
        case .importedMaterialUnavailable:
            "无法读取已导入的私钥。请重新选择密钥文件后再保存。"
        case .externalFileRequired:
            "改为外部文件存储时，请先选择可读取的私钥文件。"
        case .pastedMaterialRequiresImport:
            "粘贴的私钥必须导入应用 Keychain；请启用“导入到应用 Keychain”。"
        }
    }
}

private struct ResolvedSSHKeyMaterial {
    let path: String
    let displayPath: String
    let contents: String
    let bookmark: Data?
    let temporaryURL: URL?

    func removeTemporaryFile() {
        guard let temporaryURL else { return }
        try? FileManager.default.removeItem(at: temporaryURL)
    }
}

private enum SSHKeyEditorFocusField: Hashable { case name, file, passphrase }

struct SSHKeyEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var identities: [IdentityRecord]
    @Query private var servers: [ServerRecord]

    let key: SSHKeyRecord?

    @State private var name: String
    @State private var filePath: String
    @State private var notes: String
    @State private var isInspecting = false
    @State private var errorMessage: String?
    @State private var importIntoApp = false
    @State private var passphrase = ""
    @State private var hasStoredPassphrase = false
    @State private var removeStoredPassphrase = false
    @State private var revealedPublicKey = ""
    @State private var explicitlySelectedFilePath: String?
    @State private var draftID: UUID
    @FocusState private var focusedField: SSHKeyEditorFocusField?

    init(key: SSHKeyRecord?) {
        self.key = key
        _name = State(initialValue: key?.name ?? "")
        _filePath = State(initialValue: key?.filePath ?? "")
        _notes = State(initialValue: key?.notes ?? "")
        _importIntoApp = State(initialValue: key?.storageMode == .imported)
        _draftID = State(initialValue: key?.id ?? UUID())
        let storedPassphrase = Self.storedPassphraseExists(for: key)
        _hasStoredPassphrase = State(initialValue: storedPassphrase)
    }

    var body: some View {
        MacEditorSheetScaffold(
            title: key == nil ? "导入 SSH 密钥" : "编辑 SSH 密钥",
            accessibilityID: "mac.editor.ssh-key",
            saveTitle: isInspecting ? "正在验证" : "验证并保存",
            errorMessage: errorMessage,
            saveDisabled: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || filePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || isInspecting,
            maxContentWidth: 640,
            scrollsContent: false,
            onCancel: {
                guard !isInspecting else { return }
                dismiss()
            },
            onSave: inspectAndSave,
            onValidationError: focusFirstInvalidField
        ) {
            Form {
                Section("密钥") {
                    TextField("名称", text: $name)
                        .focused($focusedField, equals: .name)
                    HStack {
                        TextField("文件路径或粘贴私钥文本", text: $filePath, axis: .vertical)
                            .lineLimit(2...6)
                            .focused($focusedField, equals: .file)
                            .accessibilityIdentifier("mac.editor.ssh-key.file")
                            .onChange(of: filePath) { _, value in
                                if let explicitlySelectedFilePath,
                                   explicitlySelectedFilePath != value {
                                    self.explicitlySelectedFilePath = nil
                                }
                            }
                        Button("选择…", action: chooseFile)
                    }
                    Toggle("导入到应用 Keychain（不依赖外部文件）", isOn: $importIntoApp)
                    SecureField(
                        hasStoredPassphrase ? "新口令（留空则保留已保存口令）" : "私钥口令（可选）",
                        text: $passphrase
                    )
                    .focused($focusedField, equals: .passphrase)
                    .onChange(of: passphrase) { _, value in
                        if !value.isEmpty { removeStoredPassphrase = false }
                    }
                    if hasStoredPassphrase {
                        Toggle("移除已保存的私钥口令", isOn: $removeStoredPassphrase)
                            .disabled(!passphrase.isEmpty)
                        Text(removeStoredPassphrase ? "保存后将从本机 Keychain 删除口令。" : "留空会保留本机 Keychain 中的现有口令。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    TextField("备注", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }
                if let key {
                    Section("指纹") {
                        LabeledContent("算法", value: key.algorithm)
                        LabeledContent("SHA256", value: key.fingerprint)
                        if !revealedPublicKey.isEmpty {
                            Text(revealedPublicKey)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                        Button("查看并复制公钥") {
                            Task { await revealPublicKey() }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .disabled(isInspecting)
        }
        .interactiveDismissDisabled(isInspecting)
    }

    private func focusFirstInvalidField() {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            focusedField = .name
        } else if filePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || (key?.storageMode == .imported
                        && !importIntoApp
                        && explicitlySelectedFilePath != filePath) {
            focusedField = .file
        } else {
            focusedField = .file
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "选择 SSH 私钥"
        panel.prompt = "选择"
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            filePath = url.path
            explicitlySelectedFilePath = url.path
            if name.isEmpty {
                name = url.lastPathComponent
            }
        }
    }

    private func inspectAndSave() {
        isInspecting = true
        Task {
            do {
                let previousStorageMode = key?.storageMode
                let storedPassphraseExists = Self.storedPassphraseExists(for: key)
                let credentialPlan = SSHKeyEditorCredentialPlan.make(
                    existingStorageMode: key?.storageMode,
                    existingFilePath: key?.filePath,
                    proposedFilePath: filePath,
                    importIntoApp: importIntoApp,
                    newPassphrase: passphrase,
                    removeStoredPassphrase: removeStoredPassphrase,
                    hasStoredPassphrase: storedPassphraseExists,
                    explicitFileSelection: explicitlySelectedFilePath == filePath
                )
                let material = try resolvedKeyMaterial(using: credentialPlan)
                defer { material.removeTemporaryFile() }
                let recordID = draftID
                var credentialMutations: [KeychainSecretMutation] = []
                let importedAccount = KeychainService.importedKeyAccount(for: recordID)
                if importIntoApp, !credentialPlan.reuseImportedMaterial {
                    credentialMutations.append(.replace(account: importedAccount, value: material.contents))
                } else if previousStorageMode == .imported, !importIntoApp {
                    credentialMutations.append(.remove(account: importedAccount))
                }
                if let mutation = credentialPlan.passphraseMutation(for: recordID) {
                    credentialMutations.append(mutation)
                }
                try await KeychainMutationTransaction.commitAsync(
                    credentialMutations,
                    coordinationKeys: ConnectionConfigurationCoordination.sshKey(recordID)
                ) {
                    // Hold the key-record and concrete Keychain accounts from
                    // before the first suspension through the model commit. A
                    // second editor therefore fails fast instead of allowing
                    // an older inspection to overwrite its newer result.
                    let inspection = try await SSHKeyInspector.inspect(filePath: material.path)
                    let publicKey = (try? await SSHKeyInspector.publicKey(filePath: material.path))
                        ?? key?.publicKeyText
                        ?? ""
                    let record = key ?? SSHKeyRecord(
                        id: recordID,
                        name: name,
                        filePath: material.displayPath,
                        algorithm: inspection.algorithm,
                        fingerprint: inspection.fingerprint
                    )
                    if key == nil {
                        modelContext.insert(record)
                    }
                    record.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    record.filePath = material.displayPath
                    record.algorithm = inspection.algorithm
                    record.fingerprint = inspection.fingerprint
                    record.notes = notes
                    record.storageMode = importIntoApp ? .imported : .file
                    record.hasPassphrase = credentialPlan.resultingHasPassphrase
                    record.publicKeyText = publicKey
                    if let bookmark = material.bookmark {
                        record.bookmarkData = bookmark
                    }
                    let linkedIdentityIDs = Set(
                        identities.filter { $0.sshKeyID == record.id }.map(\.id)
                    )
                    for server in servers where server.identityID.map(linkedIdentityIDs.contains) == true {
                        server.privateKeyPath = record.filePath
                    }
                    try modelContext.save()
                }
                isInspecting = false
                dismiss()
            } catch {
                modelContext.rollback()
                isInspecting = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func revealPublicKey() async {
        guard await LocalAuth.authenticate(reason: "查看 SSH 公钥") else { return }
        if let existing = key?.publicKeyText, !existing.isEmpty {
            revealedPublicKey = existing
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(existing, forType: .string)
            return
        }
        do {
            let inspectionPath: String
            var temporaryURL: URL?
            if let key, key.storageMode == .imported {
                guard let contents = try KeychainService.secret(
                    account: KeychainService.importedKeyAccount(for: key.id)
                ) else {
                    throw SSHKeyEditorError.importedMaterialUnavailable
                }
                let file = try temporaryKeyFile(contents)
                temporaryURL = file
                inspectionPath = file.path
            } else {
                inspectionPath = filePath
            }
            defer { if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) } }
            let value = try await SSHKeyInspector.publicKey(filePath: inspectionPath)
            revealedPublicKey = value
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func resolvedKeyMaterial(using credentialPlan: SSHKeyEditorCredentialPlan) throws -> ResolvedSSHKeyMaterial {
        if credentialPlan.reuseImportedMaterial {
            guard let key,
                  let contents = try KeychainService.secret(
                    account: KeychainService.importedKeyAccount(for: key.id)
                  ),
                  !contents.isEmpty else {
                throw SSHKeyEditorError.importedMaterialUnavailable
            }
            let file = try temporaryKeyFile(contents)
            return ResolvedSSHKeyMaterial(
                path: file.path,
                displayPath: key.filePath,
                contents: contents,
                bookmark: key.bookmarkData,
                temporaryURL: file
            )
        }
        if credentialPlan.requiresExplicitExternalFile {
            throw SSHKeyEditorError.externalFileRequired
        }
        if filePath.contains("BEGIN") && filePath.contains("PRIVATE KEY") {
            guard importIntoApp else { throw SSHKeyEditorError.pastedMaterialRequiresImport }
            let file = try temporaryKeyFile(filePath)
            return ResolvedSSHKeyMaterial(
                path: file.path,
                displayPath: "imported",
                contents: filePath,
                bookmark: nil,
                temporaryURL: file
            )
        }
        let url = URL(fileURLWithPath: NSString(string: filePath).expandingTildeInPath)
        let contents = try String(contentsOf: url, encoding: .utf8)
        let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        return ResolvedSSHKeyMaterial(
            path: url.path,
            displayPath: url.path,
            contents: contents,
            bookmark: bookmark,
            temporaryURL: nil
        )
    }

    private func temporaryKeyFile(_ contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerDash/import", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let file = directory.appendingPathComponent(UUID().uuidString)
        try Data(contents.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }

    private static func storedPassphraseExists(for key: SSHKeyRecord?) -> Bool {
        guard let key else { return false }
        if key.hasPassphrase { return true }
        do {
            return try KeychainService.secret(
                account: KeychainService.passphraseAccount(for: key.id)
            ) != nil
        } catch {
            return false
        }
    }
}

struct SnippetManagementView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CommandSnippetRecord.title) private var snippets: [CommandSnippetRecord]

    @State private var searchText = ""
    @State private var showingNewSnippet = false
    @State private var editingSnippet: CommandSnippetRecord?
    @State private var snippetPendingDeletion: CommandSnippetRecord?
    @State private var errorMessage: String?

    private var filteredSnippets: [CommandSnippetRecord] {
        guard !searchText.isEmpty else { return snippets }
        return snippets.filter {
            [$0.title, $0.command, $0.category, $0.notes]
                .contains { $0.localizedCaseInsensitiveContains(searchText) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: AppleDesign.Spacing.md) {
                AppleWorkspaceHeader(
                    title: "代码片段", subtitle: "让常用命令随手可用，执行前由你确认。",
                    symbol: "curlybraces"
                ) {
                    Button("新建片段", systemImage: "plus") { showingNewSnippet = true }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("s", modifiers: [.command, .shift])
                }
                AppleSearchField(prompt: "搜索名称、命令或分类", text: $searchText)
                    .frame(maxWidth: 360)
            }
            .padding(AppleDesign.Spacing.lg)

            if filteredSnippets.isEmpty {
                ContentUnavailableView {
                    Label("没有代码片段", systemImage: "curlybraces")
                } description: {
                    Text(searchText.isEmpty ? "创建片段以复用常见运维命令。" : "请尝试其他搜索关键词。")
                } actions: {
                    if searchText.isEmpty {
                        Button("新建片段") { showingNewSnippet = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                ScrollView {
                    AppleUnifiedPanel {
                        ForEach(Array(filteredSnippets.enumerated()), id: \.element.id) { index, snippet in
                            SnippetRow(
                                snippet: snippet,
                                onCopy: { copy(snippet) },
                                onEdit: { editingSnippet = snippet }
                            )
                            .contextMenu {
                                Button("复制命令", systemImage: "doc.on.doc") { copy(snippet) }
                                Button("编辑片段", systemImage: "pencil") { editingSnippet = snippet }
                                Divider()
                                Button("删除片段", systemImage: "trash", role: .destructive) {
                                    snippetPendingDeletion = snippet
                                }
                            }
                            if index < filteredSnippets.count - 1 {
                                Divider().padding(.leading, 24)
                            }
                        }
                    }
                    .padding(.horizontal, AppleDesign.Spacing.lg)
                    .padding(.bottom, AppleDesign.Spacing.lg)
                    .frame(maxWidth: AppleDesign.Layout.readingWidth)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .sheet(isPresented: $showingNewSnippet) {
            SnippetEditorView(snippet: nil)
        }
        .sheet(item: $editingSnippet) { snippet in
            SnippetEditorView(snippet: snippet)
        }
        .confirmationDialog(
            "删除 \(snippetPendingDeletion?.title ?? "片段")？",
            isPresented: Binding(
                get: { snippetPendingDeletion != nil },
                set: { if !$0 { snippetPendingDeletion = nil } }
            )
        ) {
            Button("删除片段", role: .destructive) {
                guard let snippet = snippetPendingDeletion else { return }
                do {
                    modelContext.delete(snippet)
                    try modelContext.save()
                    snippetPendingDeletion = nil
                } catch {
                    modelContext.rollback()
                    errorMessage = error.localizedDescription
                }
            }
        }
        .alert(
            "无法更新代码片段",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func copy(_ snippet: CommandSnippetRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippet.command, forType: .string)
        snippet.lastUsedAt = .now
        try? modelContext.save()
    }
}

private struct SnippetRow: View {
    let snippet: CommandSnippetRecord
    let onCopy: () -> Void
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: AppleDesign.Spacing.md) {
            VStack(alignment: .leading, spacing: AppleDesign.Spacing.xs) {
                HStack {
                    Text(snippet.title).font(.headline).lineLimit(1)
                    Text(snippet.category)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, AppleDesign.Spacing.xs)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(Capsule())
                }
                Text(snippet.command)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("复制", systemImage: "doc.on.doc", action: onCopy)
                .buttonStyle(.borderless)
            Button("编辑", action: onEdit)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, AppleDesign.Spacing.md)
        .padding(.vertical, AppleDesign.Spacing.sm)
    }
}

private enum SnippetEditorFocusField: Hashable { case title, command }

struct SnippetEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let snippet: CommandSnippetRecord?

    @State private var title: String
    @State private var command: String
    @State private var category: String
    @State private var notes: String
    @State private var isFavorite: Bool
    @State private var errorMessage: String?
    @FocusState private var focusedField: SnippetEditorFocusField?

    init(snippet: CommandSnippetRecord?) {
        self.snippet = snippet
        _title = State(initialValue: snippet?.title ?? "")
        _command = State(initialValue: snippet?.command ?? "")
        _category = State(initialValue: snippet?.category ?? "常用")
        _notes = State(initialValue: snippet?.notes ?? "")
        _isFavorite = State(initialValue: snippet?.isFavorite ?? false)
    }

    var body: some View {
        MacEditorSheetScaffold(
            title: snippet == nil ? "新建代码片段" : "编辑代码片段",
            accessibilityID: "mac.editor.snippet",
            errorMessage: errorMessage,
            saveDisabled: !isValid,
            maxContentWidth: 640,
            scrollsContent: false,
            onCancel: { dismiss() },
            onSave: save,
            onValidationError: focusFirstInvalidField
        ) {
            Form {
                Section("代码片段") {
                    TextField("名称", text: $title)
                        .focused($focusedField, equals: .title)
                    TextField("分类", text: $category)
                    TextField("命令", text: $command, axis: .vertical)
                        .font(.body.monospaced())
                        .lineLimit(4...10)
                        .focused($focusedField, equals: .command)
                        .accessibilityIdentifier("mac.editor.snippet.command")
                    TextField("说明", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                    Toggle("收藏", isOn: $isFavorite)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func focusFirstInvalidField() {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            focusedField = .title
        } else {
            focusedField = .command
        }
    }

    private func save() {
        let record = snippet ?? CommandSnippetRecord(title: title, command: command)
        if snippet == nil {
            modelContext.insert(record)
        }
        record.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        record.command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        record.category = category.isEmpty ? "常用" : category
        record.notes = notes
        record.isFavorite = isFavorite
        record.updatedAt = .now
        do {
            try modelContext.save()
            dismiss()
        } catch {
            if snippet == nil {
                modelContext.delete(record)
            }
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }
}
