import AppKit
import SwiftData
import SwiftUI

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
                    try modelContext.save()
                    try KeychainService.deletePassword(for: identity.id)
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
    @State private var notes: String
    @State private var errorMessage: String?

    init(identity: IdentityRecord?, keys: [SSHKeyRecord]) {
        self.identity = identity
        self.keys = keys
        _draftID = State(initialValue: identity?.id ?? UUID())
        _name = State(initialValue: identity?.name ?? "")
        _username = State(initialValue: identity?.username ?? "root")
        _authentication = State(initialValue: identity?.authentication ?? .privateKey)
        _sshKeyID = State(initialValue: identity?.sshKeyID)
        _notes = State(initialValue: identity?.notes ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("身份") {
                    TextField("名称", text: $name)
                    TextField("用户名", text: $username)
                    Picker("认证方式", selection: $authentication) {
                        ForEach(AuthenticationMethod.allCases) { method in
                            Text(method.title).tag(method)
                        }
                    }
                }

                Section("凭据") {
                    if authentication.usesPassword {
                        SecureField(
                            identity == nil ? "密码" : "新密码（留空则不修改）",
                            text: $password
                        )
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
                    TextField("备注", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
            .padding(AppleDesign.Spacing.md)
        }
        .frame(width: 520, height: 480)
        .alert(
            "无法保存身份",
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

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (!authentication.usesPrivateKey || sshKeyID != nil)
    }

    private func save() {
        guard isValid else { return }
        if authentication == .password,
           password.isEmpty,
           !KeychainService.hasPassword(for: draftID) {
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

            if authentication.usesPassword {
                if !password.isEmpty {
                    try KeychainService.savePassword(password, for: record.id)
                }
            } else {
                try KeychainService.deletePassword(for: record.id)
            }

            let selectedKey = keys.first { $0.id == record.sshKeyID }
            for server in servers where server.identityID == record.id {
                server.username = record.username
                server.authentication = record.authentication
                server.privateKeyPath = selectedKey?.filePath ?? ""
            }
            try modelContext.save()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
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
                    try? KeychainService.deleteSecret(account: KeychainService.importedKeyAccount(for: key.id))
                    try? KeychainService.deleteSecret(account: KeychainService.passphraseAccount(for: key.id))
                    modelContext.delete(key)
                    try modelContext.save()
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
    @State private var revealedPublicKey = ""

    init(key: SSHKeyRecord?) {
        self.key = key
        _name = State(initialValue: key?.name ?? "")
        _filePath = State(initialValue: key?.filePath ?? "")
        _notes = State(initialValue: key?.notes ?? "")
        _importIntoApp = State(initialValue: key?.storageMode == .imported)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("密钥") {
                    TextField("名称", text: $name)
                    HStack {
                        TextField("文件路径或粘贴私钥文本", text: $filePath, axis: .vertical)
                            .lineLimit(2...6)
                        Button("选择…", action: chooseFile)
                    }
                    Toggle("导入到应用 Keychain（不依赖外部文件）", isOn: $importIntoApp)
                    SecureField("私钥口令（可选）", text: $passphrase)
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
            .disabled(isInspecting)

            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    inspectAndSave()
                } label: {
                    if isInspecting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("验证并保存")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || filePath.isEmpty || isInspecting)
            }
            .padding(AppleDesign.Spacing.md)
        }
        .frame(width: 560, height: 520)
        .alert(
            "无法导入密钥",
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

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "选择 SSH 私钥"
        panel.prompt = "选择"
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            filePath = url.path
            if name.isEmpty {
                name = url.lastPathComponent
            }
        }
    }

    private func inspectAndSave() {
        isInspecting = true
        Task {
            do {
                let material = try resolvedKeyMaterial()
                let inspection = try await SSHKeyInspector.inspect(filePath: material.path)
                let publicKey = (try? await SSHKeyInspector.publicKey(filePath: material.path)) ?? ""
                let record = key ?? SSHKeyRecord(
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
                record.hasPassphrase = !passphrase.isEmpty
                record.publicKeyText = publicKey
                if let bookmark = material.bookmark {
                    record.bookmarkData = bookmark
                }
                if importIntoApp {
                    try KeychainService.saveSecret(
                        material.contents,
                        account: KeychainService.importedKeyAccount(for: record.id)
                    )
                }
                if !passphrase.isEmpty {
                    try KeychainService.saveSecret(
                        passphrase,
                        account: KeychainService.passphraseAccount(for: record.id)
                    )
                }

                let linkedIdentityIDs = Set(
                    identities.filter { $0.sshKeyID == record.id }.map(\.id)
                )
                for server in servers where server.identityID.map(linkedIdentityIDs.contains) == true {
                    server.privateKeyPath = record.filePath
                }
                try modelContext.save()
                isInspecting = false
                dismiss()
            } catch {
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
            let value = try await SSHKeyInspector.publicKey(filePath: filePath)
            revealedPublicKey = value
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func resolvedKeyMaterial() throws -> (path: String, displayPath: String, contents: String, bookmark: Data?) {
        if filePath.contains("BEGIN") && filePath.contains("PRIVATE KEY") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ServerDash/import", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent(UUID().uuidString)
            try Data(filePath.utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return (file.path, "imported", filePath, nil)
        }
        let url = URL(fileURLWithPath: NSString(string: filePath).expandingTildeInPath)
        let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        return (url.path, url.path, contents, bookmark)
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

    init(snippet: CommandSnippetRecord?) {
        self.snippet = snippet
        _title = State(initialValue: snippet?.title ?? "")
        _command = State(initialValue: snippet?.command ?? "")
        _category = State(initialValue: snippet?.category ?? "常用")
        _notes = State(initialValue: snippet?.notes ?? "")
        _isFavorite = State(initialValue: snippet?.isFavorite ?? false)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("代码片段") {
                    TextField("名称", text: $title)
                    TextField("分类", text: $category)
                    TextField("命令", text: $command, axis: .vertical)
                        .font(.body.monospaced())
                        .lineLimit(4...10)
                    TextField("说明", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                    Toggle("收藏", isOn: $isFavorite)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(title.isEmpty || command.isEmpty)
            }
            .padding(AppleDesign.Spacing.md)
        }
        .frame(width: 560, height: 440)
        .alert(
            "无法保存代码片段",
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
