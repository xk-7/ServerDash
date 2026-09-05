import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct MobileIdentitiesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \IdentityRecord.name) private var identities: [IdentityRecord]
    @Query private var servers: [ServerRecord]
    @State private var editing: IdentityRecord?
    @State private var showingNew = false
    @State private var blockedMessage: String?

    var body: some View {
        List {
            ForEach(identities) { identity in
                Button { editing = identity } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(identity.name).font(.headline).foregroundStyle(.primary)
                            Text("\(identity.username) · \(identity.authentication.title)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button("删除", role: .destructive) { delete(identity) }
                }
            }
        }
        .navigationTitle("身份")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingNew = true } label: { Label("添加身份", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $showingNew) { MobileIdentityEditor(identity: nil) }
        .sheet(item: $editing) { MobileIdentityEditor(identity: $0) }
        .alert("无法删除身份", isPresented: Binding(
            get: { blockedMessage != nil },
            set: { if !$0 { blockedMessage = nil } }
        )) { Button("好") {} } message: { Text(blockedMessage ?? "") }
        .overlay {
            if identities.isEmpty {
                ContentUnavailableView("还没有共享身份", systemImage: "person.crop.circle.badge.checkmark")
            }
        }
    }

    private func delete(_ identity: IdentityRecord) {
        let count = ResourceDeletionPolicy.identityReferenceCount(identity.id, in: servers)
        guard count == 0 else {
            blockedMessage = "仍有 \(count) 台服务器使用此身份。"
            return
        }
        try? KeychainService.deletePassword(for: identity.id)
        modelContext.delete(identity)
        try? modelContext.save()
    }
}

private struct MobileIdentityEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SSHKeyRecord.name) private var keys: [SSHKeyRecord]
    let identity: IdentityRecord?

    @State private var name: String
    @State private var username: String
    @State private var authentication: AuthenticationMethod
    @State private var keyID: UUID?
    @State private var password = ""
    @State private var notes: String
    @State private var errorMessage: String?

    init(identity: IdentityRecord?) {
        self.identity = identity
        _name = State(initialValue: identity?.name ?? "")
        _username = State(initialValue: identity?.username ?? "")
        _authentication = State(initialValue: identity?.authentication ?? .password)
        _keyID = State(initialValue: identity?.sshKeyID)
        _notes = State(initialValue: identity?.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("身份") {
                    TextField("名称", text: $name)
                    TextField("用户名", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("认证方式", selection: $authentication) {
                        ForEach(AuthenticationMethod.allCases) { Text($0.title).tag($0) }
                    }
                }
                if authentication.usesPrivateKey {
                    Section("私钥") {
                        Picker("导入的密钥", selection: $keyID) {
                            Text("请选择").tag(UUID?.none)
                            ForEach(keys) { Text($0.name).tag(UUID?.some($0.id)) }
                        }
                        if keys.isEmpty {
                            Text("请先在“SSH 密钥”中导入 Ed25519 或 RSA 私钥。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if authentication.usesPassword {
                    Section("密码") {
                        SecureField(identity == nil ? "密码" : "新密码（留空则不修改）", text: $password)
                        Text("密码仅保存在本设备 Keychain。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("备注") { TextField("备注", text: $notes, axis: .vertical) }
                if let errorMessage { Section { Text(errorMessage).foregroundStyle(Color.appError) } }
            }
            .navigationTitle(identity == nil ? "添加身份" : "编辑身份")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }
            }
        }
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "请输入名称和用户名。"
            return
        }
        guard !authentication.usesPrivateKey || keyID != nil else {
            errorMessage = "请选择已导入的私钥。"
            return
        }
        let value = identity ?? IdentityRecord(
            name: name,
            username: username,
            authentication: authentication
        )
        value.name = name
        value.username = username
        value.authentication = authentication
        value.sshKeyID = authentication.usesPrivateKey ? keyID : nil
        value.notes = notes
        value.updatedAt = .now
        if identity == nil { modelContext.insert(value) }
        do {
            if authentication.usesPassword, !password.isEmpty {
                try KeychainService.savePassword(password, for: value.id)
            }
            try modelContext.save()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct MobileKeysView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SSHKeyRecord.name) private var keys: [SSHKeyRecord]
    @Query private var identities: [IdentityRecord]
    @State private var showingImporter = false
    @State private var importDraft: MobileKeyImportDraft?
    @State private var errorMessage: String?

    var body: some View {
        List {
            ForEach(keys) { key in
                VStack(alignment: .leading, spacing: 5) {
                    Text(key.name).font(.headline)
                    Text("\(key.algorithm) · \(key.fingerprint)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Label("仅本设备 Keychain", systemImage: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 5)
                .swipeActions {
                    Button("删除", role: .destructive) { delete(key) }
                }
            }
        }
        .navigationTitle("SSH 密钥")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingImporter = true } label: { Label("导入私钥", systemImage: "square.and.arrow.down") }
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.data, .plainText],
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let url = try result.get().first else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                guard let pem = String(data: data, encoding: .utf8),
                      pem.contains("BEGIN OPENSSH PRIVATE KEY") else {
                    throw RemoteConnectionFailure.invalidPrivateKey
                }
                importDraft = MobileKeyImportDraft(
                    suggestedName: url.deletingPathExtension().lastPathComponent,
                    pem: pem
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .sheet(item: $importDraft) { draft in
            MobileKeyImportView(draft: draft) { name, passphrase, inspection in
                save(draft: draft, name: name, passphrase: passphrase, inspection: inspection)
            }
        }
        .alert("密钥操作失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) { Button("好") {} } message: { Text(errorMessage ?? "") }
        .overlay {
            if keys.isEmpty {
                ContentUnavailableView(
                    "还没有 SSH 密钥",
                    systemImage: "key",
                    description: Text("从“文件”导入 OpenSSH Ed25519 或 RSA 私钥。")
                )
            }
        }
    }

    private func save(
        draft: MobileKeyImportDraft,
        name: String,
        passphrase: String,
        inspection: MobileSSHKeyCodec.Inspection
    ) {
        let key = SSHKeyRecord(
            name: name,
            filePath: "",
            algorithm: inspection.algorithm,
            fingerprint: inspection.fingerprint,
            storageMode: .imported,
            hasPassphrase: !passphrase.isEmpty,
            publicKeyText: inspection.publicKey
        )
        do {
            try KeychainService.saveSecret(
                draft.pem,
                account: KeychainService.importedKeyAccount(for: key.id)
            )
            if !passphrase.isEmpty {
                try KeychainService.saveSecret(
                    passphrase,
                    account: KeychainService.passphraseAccount(for: key.id)
                )
            }
            modelContext.insert(key)
            try modelContext.save()
            importDraft = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ key: SSHKeyRecord) {
        let count = ResourceDeletionPolicy.keyReferenceCount(key.id, in: identities)
        guard count == 0 else {
            errorMessage = "仍有 \(count) 个身份使用此密钥。"
            return
        }
        try? KeychainService.deleteSecret(account: KeychainService.importedKeyAccount(for: key.id))
        try? KeychainService.deleteSecret(account: KeychainService.passphraseAccount(for: key.id))
        modelContext.delete(key)
        try? modelContext.save()
    }
}

private struct MobileKeyImportDraft: Identifiable {
    let id = UUID()
    let suggestedName: String
    let pem: String
}

private struct MobileKeyImportView: View {
    @Environment(\.dismiss) private var dismiss
    let draft: MobileKeyImportDraft
    let onSave: (String, String, MobileSSHKeyCodec.Inspection) -> Void
    @State private var name: String
    @State private var passphrase = ""
    @State private var errorMessage: String?

    init(
        draft: MobileKeyImportDraft,
        onSave: @escaping (String, String, MobileSSHKeyCodec.Inspection) -> Void
    ) {
        self.draft = draft
        self.onSave = onSave
        _name = State(initialValue: draft.suggestedName)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("私钥") {
                    TextField("名称", text: $name)
                    SecureField("口令（如有）", text: $passphrase)
                }
                Section {
                    Label("导入后，原文件路径不会保存。", systemImage: "lock.doc")
                    Text("私钥仅写入本设备 Keychain，不参与 iCloud 同步。")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let errorMessage { Section { Text(errorMessage).foregroundStyle(Color.appError) } }
            }
            .navigationTitle("导入 SSH 私钥")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") {
                        do {
                            let inspection = try MobileSSHKeyCodec.inspect(
                                pem: draft.pem,
                                passphrase: passphrase.isEmpty ? nil : passphrase
                            )
                            onSave(name, passphrase, inspection)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            }
        }
    }
}

struct MobileSnippetsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CommandSnippetRecord.title) private var snippets: [CommandSnippetRecord]
    @State private var editing: CommandSnippetRecord?
    @State private var showingNew = false

    var body: some View {
        List {
            ForEach(snippets) { snippet in
                Button { editing = snippet } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(snippet.title).font(.headline).foregroundStyle(.primary)
                            if snippet.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                        }
                        Text(snippet.command)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button("删除", role: .destructive) {
                        modelContext.delete(snippet)
                        try? modelContext.save()
                    }
                }
            }
        }
        .navigationTitle("命令片段")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingNew = true } label: { Label("添加片段", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $showingNew) { MobileSnippetEditor(snippet: nil) }
        .sheet(item: $editing) { MobileSnippetEditor(snippet: $0) }
        .overlay {
            if snippets.isEmpty { ContentUnavailableView("还没有命令片段", systemImage: "curlybraces") }
        }
    }
}

private struct MobileSnippetEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let snippet: CommandSnippetRecord?
    @State private var title: String
    @State private var command: String
    @State private var category: String
    @State private var favorite: Bool

    init(snippet: CommandSnippetRecord?) {
        self.snippet = snippet
        _title = State(initialValue: snippet?.title ?? "")
        _command = State(initialValue: snippet?.command ?? "")
        _category = State(initialValue: snippet?.category ?? "常用")
        _favorite = State(initialValue: snippet?.isFavorite ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("标题", text: $title)
                TextField("命令", text: $command, axis: .vertical)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("分类", text: $category)
                Toggle("收藏", isOn: $favorite)
            }
            .navigationTitle(snippet == nil ? "添加片段" : "编辑片段")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let value = snippet ?? CommandSnippetRecord(title: title, command: command)
                        value.title = title
                        value.command = command
                        value.category = category
                        value.isFavorite = favorite
                        value.updatedAt = .now
                        if snippet == nil { modelContext.insert(value) }
                        try? modelContext.save()
                        dismiss()
                    }
                    .disabled(title.isEmpty || command.isEmpty)
                }
            }
        }
    }
}

struct MobileTrustedHostsView: View {
    @State private var revision = UUID()
    @State private var errorMessage: String?

    private var keys: [TrustedHostRow] {
        _ = revision
        return TrustedHostStore.allKeys().compactMap(TrustedHostRow.init)
    }

    var body: some View {
        List {
            ForEach(keys) { key in
                VStack(alignment: .leading, spacing: 5) {
                    Text(key.host).font(.headline)
                    Text("\(key.algorithm) · \(key.fingerprint)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.vertical, 5)
                .swipeActions {
                    Button("移除", role: .destructive) {
                        do {
                            try TrustedHostStore.remove(host: key.host, port: key.port)
                            revision = UUID()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            }
        }
        .navigationTitle("可信主机")
        .overlay {
            if keys.isEmpty {
                ContentUnavailableView(
                    "没有可信主机",
                    systemImage: "checkmark.shield",
                    description: Text("首次连接时核对并保存的主机密钥会显示在这里。")
                )
            }
        }
        .alert("无法移除", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) { Button("好") {} } message: { Text(errorMessage ?? "") }
    }
}

private struct TrustedHostRow: Identifiable {
    let host: String
    let port: Int
    let algorithm: String
    let fingerprint: String
    var id: String { "\(host):\(port):\(algorithm)" }

    init?(_ value: (algorithm: String, fingerprint: String, line: String)) {
        guard let marker = value.line.split(separator: " ").first.map(String.init) else { return nil }
        if marker.hasPrefix("["), let separator = marker.lastIndex(of: "]") {
            host = String(marker[marker.index(after: marker.startIndex)..<separator])
            let portText = marker[marker.index(separator, offsetBy: 2)...]
            port = Int(portText) ?? 22
        } else {
            host = marker.split(separator: ",").first.map(String.init) ?? marker
            port = 22
        }
        algorithm = TrustedHostStore.algorithmDisplayName(value.algorithm)
        fingerprint = value.fingerprint
    }
}
