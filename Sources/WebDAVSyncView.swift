import AppKit
import CryptoKit
import SwiftData
import SwiftUI

@MainActor final class WebDAVSyncModel: ObservableObject {
    @Published var changes: [ConfigurationSyncChange] = []
    @Published var busy = false
    @Published var hasPreview = false
    @Published var message = ""
    @Published var error: String?
    private let transport = WebDAVSyncTransport()
    private var catalog: ConfigurationSyncCatalog?
    private var local: [SyncConfigurationObject] = []
    private var localStateFingerprint = Data()
    private var remote: [SyncConfigurationObject] = []
    private var endpoint: WebDAVSyncEndpoint?
    private var etag: String?
    private var key = Data()
    private var task: Task<Void, Never>?
    static func account(_ address: String, purpose: String) -> String {
        "webdav.\(purpose)." + SHA256.hash(data: Data(address.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func preview(address: String, username: String, password: String, container: ModelContainer) {
        guard !busy else { return }
        busy = true; hasPreview = false; error = nil; message = "读取并比较配置…"
        task = Task {
            defer { busy = false }
            do {
                let endpoint = try WebDAVSyncEndpoint(address: address, username: username, password: password)
                let secret = try KeychainService.secret(account: Self.account(endpoint.directory.absoluteString, purpose: "key")) ?? ""
                guard let key = Data(base64Encoded: secret), key.count == 32 else { throw ConfigurationSyncError.missingKey }
                try KeychainService.saveSecret(password, account: Self.account(endpoint.directory.absoluteString + "|" + username, purpose: "password"))
                let (bytes, etag) = try await transport.fetch(endpoint)
                let package = try bytes.map { try ConfigurationSyncCrypto.decrypt($0, key: key) }
                let spaceID: UUID
                let spaceAccount = Self.account(endpoint.directory.absoluteString, purpose: "space")
                if let package { spaceID = package.spaceID }
                else { spaceID = UserDefaults.standard.string(forKey: spaceAccount).flatMap(UUID.init(uuidString:)) ?? UUID() }
                let catalog = try ConfigurationSyncCatalog(container: container, spaceID: spaceID)
                let local = try catalog.capture()
                // Checkpoint only stable ID mappings. No configuration is applied during preview.
                try catalog.save()
                self.localStateFingerprint = try catalog.freshLocalStateFingerprint()
                UserDefaults.standard.set(spaceID.uuidString, forKey: spaceAccount)
                self.local = local; self.remote = package?.objects ?? []
                self.changes = ConfigurationSyncMerge.changes(local: local, remote: remote, baseline: catalog.baseline)
                self.endpoint = endpoint; self.etag = etag; self.key = key; self.catalog = catalog
                hasPreview = true
                message = changes.isEmpty ? "配置已一致。" : "\(changes.count) 项变更，请检查后同步。"
            } catch is CancellationError { message = "已取消" }
            catch { self.error = error.localizedDescription; message = "" }
        }
    }
    func commit(appState: AppState) {
        guard !busy, hasPreview, let catalog, let endpoint else { return }
        busy = true; error = nil; message = "写入加密配置…"
        task = Task {
            defer { busy = false }
            do {
                guard try catalog.freshCapture() == local,
                      try catalog.freshLocalStateFingerprint() == localStateFingerprint else { throw ConfigurationSyncError.localChanged }
                let merged = try ConfigurationSyncMerge.resolve(local: local, remote: remote, changes: changes)
                let package = ConfigurationSyncPackage(spaceID: catalog.spaceID, objects: merged)
                try catalog.stage(merged)
                let encrypted = try ConfigurationSyncCrypto.encrypt(package, key: key)
                try await transport.put(encrypted, endpoint: endpoint, etag: etag)
                guard try catalog.freshCapture() == local,
                      try catalog.freshLocalStateFingerprint() == localStateFingerprint else { throw ConfigurationSyncError.localChanged }
                try catalog.save()
                for object in merged where object.deleted {
                    let id = catalog.localID(kind: object.kind, remoteID: object.id)
                    if object.kind == "ssh" { appState.removeRuntimeData(for: id) }
                    if object.kind == "rdp" { appState.removeRDP(id) }
                    if object.kind == "serial" { appState.closeWorkspaceTabs(appState.terminalRegistry.workspace.tabs.filter { $0.serverID == id }) }
                }
                try appState.reloadConnectionConfigurations(from: catalog.context.container)
                changes = []; hasPreview = false; self.catalog = nil
                message = "同步完成。登录凭据和设备授权仍保存在本机。"
            } catch {
                catalog.context.rollback()
                self.catalog = nil; hasPreview = false
                self.error = error.localizedDescription
                message = "未完成同步。保留本机数据，重新预览可继续。"
            }
        }
    }
    func invalidate() { hasPreview = false; changes = [] }
    func cancel() { task?.cancel() }
}

struct WebDAVSyncView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @AppStorage("webdav.enabled") private var enabled = false
    @AppStorage("hideIPInformation") private var privacy = false
    @AppStorage("webdav.address") private var address = ""
    @AppStorage("webdav.username") private var username = ""
    @State private var password = ""
    @State private var keyAvailable = false
    @State private var keyError: String?
    @StateObject private var model = WebDAVSyncModel()
    var embedded = false
    var body: some View {
        VStack(spacing: 0) {
            if !embedded {
                HStack { Label("WebDAV 配置同步", systemImage: "arrow.triangle.2.circlepath").font(.title2.weight(.semibold)); Spacer(); Button("完成") { dismiss() }.disabled(model.busy) }.padding(20)
                Divider()
            }
            Form {
                Section("连接") {
                    Toggle("启用配置同步", isOn: $enabled)
                    TextField("WebDAV 目录", text: $address, prompt: Text("https://cloud.example.com/dav/ServerDash/"))
                    TextField("用户名", text: $username)
                    SecureField("密码", text: $password)
                    Text("点击预览时连接。同步主机、分组、标签、片段及连接配置；不上传登录凭据、历史、录制或本机授权。")
                        .font(.caption).foregroundStyle(.secondary)
                }.disabled(model.busy)
                Section("加密恢复密钥") {
                    Label(keyAvailable ? "此目录已配置恢复密钥" : "尚未配置恢复密钥", systemImage: keyAvailable ? "lock.shield" : "key")
                    HStack {
                        Button("生成新密钥") { generateKey() }.disabled(keyAvailable || address.isEmpty)
                        Button("导入恢复密钥…") { importKey() }
                        Button("导出恢复密钥…") { exportKey() }.disabled(!keyAvailable)
                    }
                    Text("另一台 Mac 使用同一目录与恢复密钥。请妥善保存导出的密钥；密钥不会上传到 WebDAV。").font(.caption).foregroundStyle(.secondary)
                }.disabled(model.busy)
                Section("预览") {
                    HStack {
                        Button("保存并预览") {
                            model.preview(address: address, username: username, password: password, container: context.container)
                        }.disabled(!enabled || model.busy || !keyAvailable)
                        if model.busy { ProgressView().controlSize(.small); Button("取消") { model.cancel() } }
                        Spacer()
                        Text(model.message).font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = model.error ?? keyError { Text(error).foregroundStyle(Color.appError).textSelection(.enabled) }
                    ForEach($model.changes) { $change in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Text(change.name).fontWeight(.medium); Spacer(); Text(change.detail).font(.caption).foregroundStyle(change.conflict ? Color.appWarning : .secondary) }
                            if change.conflict {
                                Picker("处理方式", selection: $change.choice) {
                                    ForEach(SyncChoice.allCases.filter { choice in
                                        choice != .both || ["ssh", "rdp", "vnc", "serial", "snippet"].contains(change.local?.kind ?? "")
                                    }) { Text($0.title).tag($0) }
                                }
                            }
                            if change.conflict || (change.local?.fields["host"] != change.remote?.fields["host"]) {
                                HStack(alignment: .top) {
                                    Text("本机：\(summary(change.local))").frame(maxWidth: .infinity, alignment: .leading)
                                    Text("远端：\(summary(change.remote))").frame(maxWidth: .infinity, alignment: .leading)
                                }.font(.caption).foregroundStyle(.secondary)
                            }
                            ConfigurationChangeDetails(local: change.local, incoming: change.remote)
                        }.padding(.vertical, 4)
                    }
                    if model.hasPreview {
                        Button("应用预览并同步") { model.commit(appState: appState) }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.busy || model.changes.contains { $0.choice == .unresolved })
                    }
                }
            }.formStyle(.grouped)
        }
        .frame(minWidth: embedded ? 440 : 680, idealWidth: 720, minHeight: 520, idealHeight: 700)
        .background(Color.appGround)
        .interactiveDismissDisabled(model.busy)
        .onAppear { loadSecrets() }
        .onChange(of: address) { _, _ in model.invalidate(); password = ""; loadSecrets() }
        .onChange(of: username) { _, _ in model.invalidate(); password = ""; loadSecrets() }
        .onChange(of: password) { _, _ in model.invalidate() }
    }
    private func summary(_ object: SyncConfigurationObject?) -> String {
        guard let object, !object.deleted else { return "已删除／不存在" }
        if privacy, object.fields["host"] != nil { return "连接地址已隐藏" }
        return object.fields["host"].map { (object.fields["username"].map { $0 + "@" } ?? "") + $0 + ":" + (object.fields["port"] ?? "") } ?? object.name
    }
    private var normalizedAddress: String {
        (try? WebDAVSyncEndpoint(address: address, username: username, password: "").directory.absoluteString) ?? address
    }
    private func loadSecrets() {
        let text = try? KeychainService.secret(account: WebDAVSyncModel.account(normalizedAddress, purpose: "key"))
        keyAvailable = text.flatMap { $0 }.flatMap { Data(base64Encoded: $0) }?.count == 32
        password = (try? KeychainService.secret(account: WebDAVSyncModel.account(normalizedAddress + "|" + username, purpose: "password"))) ?? ""
    }
    private func generateKey() {
        do {
            _ = try WebDAVSyncEndpoint(address: address, username: username, password: password)
            try KeychainService.saveSecret(ConfigurationSyncCrypto.newKey().base64EncodedString(), account: WebDAVSyncModel.account(normalizedAddress, purpose: "key"))
            keyAvailable = true; keyError = nil; model.invalidate()
        } catch { keyError = error.localizedDescription }
    }
    private func importKey() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try WebDAVSyncEndpoint(address: address, username: username, password: password)
            let bytes = try Data(contentsOf: url)
            guard bytes.count < 1024, let text = String(data: bytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  Data(base64Encoded: text)?.count == 32 else { throw ConfigurationSyncError.missingKey }
            try KeychainService.saveSecret(text, account: WebDAVSyncModel.account(normalizedAddress, purpose: "key"))
            keyAvailable = true; keyError = nil; model.invalidate()
        } catch { keyError = error.localizedDescription }
    }
    private func exportKey() {
        do {
            guard let key = try KeychainService.secret(account: WebDAVSyncModel.account(normalizedAddress, purpose: "key")) else { throw ConfigurationSyncError.missingKey }
            let panel = NSSavePanel(); panel.nameFieldStringValue = "ServerDash-recovery-key.txt"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try Data(key.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            keyError = nil
        } catch { keyError = error.localizedDescription }
    }
}
