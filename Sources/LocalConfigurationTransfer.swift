import AppKit
import CryptoKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Host configuration files deliberately have a separate identity namespace from WebDAV.
struct LocalConfigurationPackage: Codable {
    static let maximumBytes = 32 * 1024 * 1024
    var format = "ServerDash.LocalHostConfiguration"
    var version = 1
    var sourceID: UUID
    var objects: [SyncConfigurationObject]

    var mappingSpaceID: UUID { Self.mappingSpaceID(sourceID) }
    static func mappingSpaceID(_ source: UUID) -> UUID {
        var b = Array(SHA256.hash(data: Data("ServerDash.LocalHostConfiguration.mapping.v1:\(source.uuidString)".utf8)).prefix(16))
        b[6] = (b[6] & 15) | 128; b[8] = (b[8] & 63) | 128
        return UUID(uuid: (b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))
    }
    func validate() throws {
        guard format == "ServerDash.LocalHostConfiguration", version == 1,
              objects.allSatisfy({ ["ssh", "rdp", "vnc", "serial", "group", "tag", "advanced", "route", "tunnel"].contains($0.kind) }) else {
            throw ConfigurationSyncError.invalidPackage
        }
        try ConfigurationSyncPackage(spaceID: mappingSpaceID, objects: objects).validate()
    }
    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw ConfigurationSyncError.invalidPackage }
        return data
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw ConfigurationSyncError.invalidPackage }
        let package = try JSONDecoder().decode(Self.self, from: data)
        try package.validate()
        return package
    }
}

@MainActor enum LocalConfigurationExport {
    static var sourceID: UUID {
        let key = "localConfigurationTransfer.sourceID"
        if let value = UserDefaults.standard.string(forKey: key).flatMap(UUID.init(uuidString:)) { return value }
        let value = UUID(); UserDefaults.standard.set(value.uuidString, forKey: key); return value
    }
    static func prepare(container: ModelContainer, selected: Set<String>?, sourceID: UUID) throws -> LocalConfigurationPackage {
        let catalog = try ConfigurationSyncCatalog(container: container, spaceID: LocalConfigurationPackage.mappingSpaceID(sourceID))
        let captured = try catalog.capture()
        let machines = captured.filter { object in
            guard ["ssh", "rdp", "vnc", "serial"].contains(object.kind) else { return false }
            guard let selected else { return true }
            return selected.contains(object.kind.uppercased() + "/" + catalog.localID(kind: object.kind, remoteID: object.id).uuidString)
        }
        guard !machines.isEmpty else { throw ConfigurationSyncError.message("没有可导出的主机。") }
        let hostIDs = Set(machines.filter { $0.kind == "ssh" }.map { $0.id.uuidString })
        let groupNames = Set(machines.compactMap { $0.fields["group"] })
        let tagNames = Set(machines.flatMap { ($0.fields["tags"] ?? "").split(whereSeparator: { ",，;；".contains($0) }).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } })
        var included = Set(machines.map(\.id))
        for object in captured {
            if ["advanced", "route", "tunnel"].contains(object.kind), let host = object.fields["server"], hostIDs.contains(host) { included.insert(object.id) }
            if object.kind == "group", groupNames.contains(object.fields["name"] ?? "") { included.insert(object.id) }
            if object.kind == "tag", tagNames.contains(object.fields["name"] ?? "") { included.insert(object.id) }
        }
        // Ancestors keep the selected hosts' group hierarchy intact.
        var changed = true
        while changed {
            changed = false
            for group in captured where group.kind == "group" && included.contains(group.id) {
                if let parent = group.fields["parent"].flatMap(UUID.init(uuidString:)), included.insert(parent).inserted { changed = true }
            }
        }
        let package = LocalConfigurationPackage(sourceID: sourceID, objects: captured.filter { included.contains($0.id) })
        _ = try package.encoded()
        try catalog.save() // Stable export IDs only; no host configuration is changed.
        return package
    }
}

@MainActor final class LocalConfigurationImportPlan {
    let package: LocalConfigurationPackage
    let catalog: ConfigurationSyncCatalog
    let local: [SyncConfigurationObject]
    let incoming: [SyncConfigurationObject]
    let initialChanges: [ConfigurationSyncChange]
    private let localFingerprint: Data
    private let incomingIDs: Set<UUID>
    let ignoredDeletions: Int

    init(package: LocalConfigurationPackage, container: ModelContainer) throws {
        try package.validate()
        self.package = package
        ignoredDeletions = package.objects.filter(\.deleted).count
        incoming = package.objects.filter { !$0.deleted }
        guard !incoming.isEmpty else { throw ConfigurationSyncError.message("配置包没有可导入的条目；删除记录不会应用。") }
        let ids = Set(incoming.map(\.id))
        incomingIDs = ids
        catalog = try ConfigurationSyncCatalog(container: container, spaceID: package.mappingSpaceID)
        local = try catalog.capture()
        try catalog.save()
        localFingerprint = try catalog.freshLocalStateFingerprint()
        initialChanges = ConfigurationSyncMerge.changes(local: local.filter { ids.contains($0.id) }, remote: incoming,
                                                        baseline: catalog.baseline.filter { ids.contains($0.key) })
    }
    func apply(changes: [ConfigurationSyncChange]) throws {
        guard try catalog.freshCapture() == local, try catalog.freshLocalStateFingerprint() == localFingerprint else {
            throw ConfigurationSyncError.localChanged
        }
        // A file is a selected subset, never a remote directory snapshot: omissions cannot delete.
        var combined = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        for object in incoming { combined[object.id] = object }
        let merged = try ConfigurationSyncMerge.resolve(local: local, remote: Array(combined.values), changes: changes).filter { !$0.deleted }
        let oldBaselines = Dictionary(uniqueKeysWithValues: catalog.links.map { ($0.remoteID, $0.baseline) })
        do {
            try catalog.stage(merged)
            // Local files are imported explicitly and may omit directory records. Keep this
            // repair in the local import transaction, never in the WebDAV merge primitive.
            let machines = merged.filter { ["ssh", "rdp", "vnc", "serial"].contains($0.kind) }
            try MachineOrganization.include(names: machines.compactMap { $0.fields["group"] },
                tags: machines.flatMap { ($0.fields["tags"] ?? "").split(whereSeparator: { ",，;；".contains($0) }).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } },
                context: catalog.context)
            // Do not acknowledge changes to entries that this file never contained.
            for link in catalog.links where !incomingIDs.contains(link.remoteID) { link.baseline = oldBaselines[link.remoteID] ?? Data() }
            try catalog.save()
        } catch { catalog.context.rollback(); throw error }
    }
}

extension AppState {
    /// Refresh value snapshots for future connections without restarting active session owners.
    @MainActor func reloadConnectionConfigurations(from container: ModelContainer) throws {
        let reader = ModelContext(container)
        let servers = try reader.fetch(FetchDescriptor<ServerRecord>())
        let identities = try reader.fetch(FetchDescriptor<IdentityRecord>())
        let keys = try reader.fetch(FetchDescriptor<SSHKeyRecord>())
        let routes = try reader.fetch(FetchDescriptor<ConnectionRouteRecord>())
        var resolved: [UUID: ServerConnectionConfig] = [:]
        for server in servers {
            var config = ConnectionConfigResolver.resolve(server: server, identities: identities, keys: keys, routes: routes)
            let advanced = SSHAdvancedSettingsRecord.load(serverID: server.id, in: reader)
            config.advancedSettings = advanced
            config.connectTimeout = TimeInterval(advanced.connectTimeout)
            resolved[server.id] = config
        }
        applyResolvedConfigs(resolved)
    }
}

enum LocalConfigurationTransferMode: Identifiable {
    case importFile, exportAll, exportSelected(Set<String>)
    var id: String { switch self { case .importFile: "import"; case .exportAll: "exportAll"; case .exportSelected: "exportSelected" } }
    var title: String { if case .importFile = self { return "导入主机配置包" }; return "导出主机配置包" }
}

struct LocalConfigurationTransferView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    let mode: LocalConfigurationTransferMode
    @State private var exportPackage: LocalConfigurationPackage?
    @State private var plan: LocalConfigurationImportPlan?
    @State private var changes: [ConfigurationSyncChange] = []
    @State private var error: String?
    @State private var completed = false
    @State private var filename = ""
    private var importing: Bool { if case .importFile = mode { return true }; return false }

    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(mode.title).font(.title2.weight(.semibold)); Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("包含 SSH、RDP、VNC、串口及其分组、标签、连接设置。密码、密钥、录制、文件内容和本机设备绑定不在配置包中。")
                        .foregroundStyle(.secondary)
                    if importing {
                        Button("选择配置包…", systemImage: "folder") { chooseImport() }
                        if !filename.isEmpty { Text(filename).font(.caption).foregroundStyle(.secondary) }
                        if let plan {
                            Text("\(plan.incoming.count) 项配置，\(changes.count) 项变更").font(.headline)
                            if plan.ignoredDeletions > 0 { Text("已忽略 \(plan.ignoredDeletions) 条删除记录。").font(.caption).foregroundStyle(.secondary) }
                            Text("包中未包含的本机配置会保留。导入的本地命令保持关闭，串口设备需在本机重新选择。").font(.caption).foregroundStyle(.secondary)
                            ForEach($changes) { $change in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack { Text(change.name).fontWeight(.medium); Spacer(); Text(change.conflict ? "存在冲突" : (change.choice == .local ? "保留本机" : "导入配置")).font(.caption).foregroundStyle(.secondary) }
                                    if change.conflict {
                                        Picker("处理方式", selection: $change.choice) {
                                            ForEach(SyncChoice.allCases.filter { $0 != .both || ["ssh", "rdp", "vnc", "serial"].contains(change.local?.kind ?? "") }) { Text($0.title).tag($0) }
                                        }
                                    }
                                    ConfigurationChangeDetails(local: change.local, incoming: change.remote, incomingTitle: "配置包")
                                }.padding(12).background(Color.appSurface, in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    } else if let package = exportPackage {
                        Text("\(package.objects.filter { ["ssh", "rdp", "vnc", "serial"].contains($0.kind) }.count) 台主机 · \(package.objects.count) 项配置").font(.headline)
                        Text("文件包含主机地址和连接配置，请选择本机保存位置。").font(.caption).foregroundStyle(.secondary)
                        ForEach(package.objects.filter { ["ssh", "rdp", "vnc", "serial"].contains($0.kind) }) { object in
                            HStack { Text(object.name); Spacer(); Text(object.kind.uppercased()).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    if let error { Text(error).foregroundStyle(Color.appError).textSelection(.enabled) }
                    if completed { Label(importing ? "配置已导入" : "配置包已保存", systemImage: "checkmark.circle.fill").foregroundStyle(Color.green) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }
            Divider()
            HStack {
                Spacer()
                if importing {
                    Button("应用预览并导入") { applyImport() }.buttonStyle(.borderedProminent)
                        .disabled(plan == nil || completed || changes.contains { $0.choice == .unresolved })
                } else {
                    Button("保存配置包…") { saveExport() }.buttonStyle(.borderedProminent).disabled(exportPackage == nil)
                }
            }.padding(16)
        }.frame(minWidth: 600, idealWidth: 740, minHeight: 500, idealHeight: 680).background(Color.appGround)
            .onAppear { prepareExport() }
    }
    private func prepareExport() {
        guard !importing, exportPackage == nil else { return }
        let ids: Set<String>?
        if case .exportSelected(let selected) = mode { ids = selected } else { ids = nil }
        do { exportPackage = try LocalConfigurationExport.prepare(container: context.container, selected: ids, sourceID: LocalConfigurationExport.sourceID) }
        catch { self.error = error.localizedDescription }
    }
    private func chooseImport() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        plan = nil; changes = []; error = nil; completed = false; filename = url.lastPathComponent
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= LocalConfigurationPackage.maximumBytes else { throw ConfigurationSyncError.invalidPackage }
            let package = try LocalConfigurationPackage.decode(Data(contentsOf: url))
            let candidate = try LocalConfigurationImportPlan(package: package, container: context.container)
            changes = candidate.initialChanges; plan = candidate
        } catch { self.error = error.localizedDescription }
    }
    private func applyImport() {
        guard let plan else { return }
        do {
            try plan.apply(changes: changes)
            try appState.reloadConnectionConfigurations(from: context.container)
            completed = true; error = nil
        } catch { self.error = error.localizedDescription; self.plan = nil }
    }
    private func saveExport() {
        guard let package = exportPackage else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "ServerDash-hosts.serverdashconfig"
        panel.allowedContentTypes = [UTType(filenameExtension: "serverdashconfig") ?? .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try package.encoded().write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            completed = true; error = nil
        } catch { self.error = error.localizedDescription }
    }
}
