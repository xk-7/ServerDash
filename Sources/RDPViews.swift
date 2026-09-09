import AppKit
import SwiftData
import SwiftUI

enum UnifiedMachineEntry: Identifiable {
    case ssh(ServerRecord), rdp(RDPConnectionRecord)
    var id: MachineReference { switch self { case .ssh(let value): .init(id: value.id, transport: .ssh); case .rdp(let value): value.machineReference } }
    var name: String { switch self { case .ssh(let value): value.displayName; case .rdp(let value): value.displayName } }
    var group: String { switch self { case .ssh(let value): value.groupName; case .rdp(let value): value.groupName } }
    var createdAt: Date { switch self { case .ssh(let value): value.createdAt; case .rdp(let value): value.createdAt } }
    static func browse(ssh: [ServerRecord], rdp: [RDPConnectionRecord], query: ServerBrowserQuery, protocolFilter: String) -> [Self] {
        let terms = query.search.split(whereSeparator: \.isWhitespace).map(String.init)
        let remote = protocolFilter == "ssh" || query.monitoring != .all ? [] : rdp.filter { record in
            (query.group.isEmpty || record.groupName == query.group) && (query.tag.isEmpty || record.tags.contains(query.tag)) &&
            terms.allSatisfy { term in [record.displayName, record.host, record.username, record.domain, record.groupName, record.tagsText, record.notes].contains { $0.localizedCaseInsensitiveContains(term) } }
        }
        let values = (protocolFilter == "rdp" ? [] : query.apply(to: ssh).map(Self.ssh)) + remote.map(Self.rdp)
        return values.sorted { lhs, rhs in
            if query.sort == .newest, lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            if query.sort == .group, lhs.group != rhs.group { return lhs.group.localizedStandardCompare(rhs.group) == .orderedAscending }
            let order = lhs.name.localizedStandardCompare(rhs.name)
            if order != .orderedSame { return order == (query.sort == .nameDescending ? .orderedDescending : .orderedAscending) }
            return lhs.id.id.uuidString + lhs.id.transport.rawValue < rhs.id.id.uuidString + rhs.id.transport.rawValue
        }
    }
}

struct RDPEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let record: RDPConnectionRecord?
    var onSave: (RDPConnectionRecord, Bool, String?) -> Void = { _, _, _ in }
    @State private var name = ""
    @State private var host = ""
    @State private var port = "3389"
    @State private var username = ""
    @State private var domain = ""
    @State private var password = ""
    @State private var savePassword = false
    @State private var group = ""
    @State private var tags = ""
    @State private var notes = ""
    @State private var settings = RDPSettings()
    @State private var error: String?
    @State private var loaded = false
    @State private var invalidStoredSettings = false
    var body: some View {
        VStack(spacing: 0) {
            HStack { Label(record == nil ? "添加 RDP 远程桌面" : "编辑 RDP 远程桌面", systemImage: "desktopcomputer").font(.title2.bold()); Spacer() }.padding(20)
            Form {
                Section("Windows 连接") {
                    TextField("名称", text: $name)
                    TextField("主机地址", text: $host)
                    TextField("端口", text: $port)
                    TextField("用户名", text: $username)
                    TextField("域（可选）", text: $domain)
                    SecureField(record?.credentialReference == nil ? "密码" : "新密码（留空保留已保存密码）", text: $password)
                    Toggle("保存密码到本机 Keychain", isOn: $savePassword)
                    Text("不保存密码时，仅“保存并连接”会将输入交给本次会话。密码不会导出或同步。使用 DOMAIN\\user 或 user@example.com 时通常无需另填域。")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("分组", text: $group); TextField("标签", text: $tags); TextField("备注", text: $notes, axis: .vertical)
                }
                Section("显示") {
                    HStack {
                        TextField("宽度", value: $settings.width, format: .number.grouping(.never))
                        Text("×")
                        TextField("高度", value: $settings.height, format: .number.grouping(.never))
                    }
                    Picker("色彩深度", selection: $settings.colorDepth) { ForEach([16, 24, 32], id: \.self) { Text("\($0) 位").tag($0) } }
                    Toggle("随窗口调整远程分辨率", isOn: $settings.dynamicResolution)
                    Text("固定分辨率默认等比适配，不裁切。多屏全屏使用下方选择的本机显示器。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(RDPScreenCatalog.screens, id: \.id) { screen in
                        Toggle(screen.name, isOn: Binding(get: { settings.screenIDs.contains(screen.id) }, set: { selected in
                            settings.screenIDs.removeAll { $0 == screen.id }; if selected { settings.screenIDs.append(screen.id) }
                        }))
                    }
                }
                Section("键盘与外设") {
                    Picker("快捷键", selection: $settings.keyboardMode) { ForEach(RDPKeyboardMode.allCases, id: \.self) { Text($0.title).tag($0) } }
                    Text("macOS 保留的快捷键仍由本机处理。Control+Option+Shift+Escape 释放远程键盘。")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("允许双向文本剪贴板", isOn: $settings.textClipboard)
                    Toggle("允许双向文件剪贴板", isOn: $settings.fileClipboard)
                    Text("开启后，仅前台活跃会话交换新复制的内容。文件需在目标处粘贴才开始传输；不会自动打开。")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("音频", selection: $settings.audio) { ForEach(RDPAudioMode.allCases, id: \.self) { Text($0.title).tag($0) } }
                    ForEach($settings.shares) { $share in
                        HStack {
                            Text(share.name)
                            Toggle("只读", isOn: $share.readOnly)
                            Button("移除", role: .destructive) { settings.shares.removeAll { $0.id == share.id } }
                        }
                    }
                    Button("添加映射目录…", action: addDirectory)
                    Text("目录在 Windows 中显示为 SD01、SD02 等。读写模式允许新建、重命名和删除；当前拒绝覆盖已有文件。打印机、智能卡和麦克风暂不支持。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("性能") {
                    Button("应用低带宽预设") { settings.applyLowBandwidthPreset() }
                    Toggle("位图缓存", isOn: $settings.bitmapCache)
                    Toggle("禁用壁纸", isOn: $settings.disableWallpaper)
                    Toggle("禁用拖动时的窗口内容", isOn: $settings.disableWindowDrag)
                    Toggle("禁用菜单动画", isOn: $settings.disableMenuAnimations)
                    Toggle("禁用桌面主题", isOn: $settings.disableThemes)
                }
                Section("安全与重连") {
                    Text("仅 NLA/CredSSP · TLS 1.2+，不自动降级。")
                    Picker("证书策略", selection: $settings.certificatePolicy) { ForEach(RDPCertificatePolicy.allCases, id: \.self) { Text($0.title).tag($0) } }
                    Toggle("网络中断后自动重连（最多五次）", isOn: $settings.autoReconnect)
                }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }.formStyle(.grouped)
            HStack {
                Button("取消", role: .cancel) { password = ""; dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") { save(connect: false) }.disabled(invalidStoredSettings)
                Button("保存并连接") { save(connect: true) }.buttonStyle(.borderedProminent).disabled(invalidStoredSettings).keyboardShortcut(.defaultAction)
            }.padding(16)
        }.frame(width: 620, height: 740).background(Color(nsColor: .windowBackgroundColor))
            .onAppear(perform: load)
    }
    private func load() {
        guard !loaded else { return }; loaded = true
        guard let record else { return }
        name = record.name; host = record.host; port = String(record.port); username = record.username; domain = record.domain
        group = record.groupName; tags = record.tagsText; notes = record.notes; savePassword = record.credentialReference != nil
        do { settings = try record.settings() } catch { self.error = error.localizedDescription; invalidStoredSettings = true }
    }
    private func addDirectory() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            settings.shares.append(.init(name: url.lastPathComponent, bookmark: bookmark))
        } catch { self.error = "无法授权目录，请重新选择。" }
    }
    private func save(connect: Bool) {
        var newCredential: UUID?
        do {
            guard let portNumber = Int(port), port.allSatisfy(\.isNumber) else { throw RDPValidationError.invalidPort }
            let candidate = try RDPConnectionRecord(id: record?.id ?? UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: portNumber,
                username: username.trimmingCharacters(in: .whitespacesAndNewlines), domain: domain.trimmingCharacters(in: .whitespacesAndNewlines),
                groupName: group, tagsText: tags, notes: notes, settings: settings)
            let config = try candidate.configuration()
            let oldCredential = record?.credentialReference
            let sameDestination = record.map { $0.host.lowercased() == config.host.lowercased() && $0.port == config.port && $0.username == config.username && $0.domain == config.domain } ?? false
            if savePassword && !password.isEmpty {
                let id = UUID(); try RDPCredentials.save(password, id: id); newCredential = id; candidate.credentialReference = id
            } else if savePassword && sameDestination { candidate.credentialReference = oldCredential }
            // An isolated context makes a failed RDP save unable to roll back unrelated UI edits.
            let writer = ModelContext(context.container)
            let id = candidate.id
            let existing = try writer.fetch(FetchDescriptor<RDPConnectionRecord>(predicate: #Predicate { $0.id == id })).first
            let saved = existing ?? candidate
            if existing == nil { writer.insert(saved) }
            saved.name = candidate.name; saved.host = candidate.host; saved.port = candidate.port
            saved.username = candidate.username; saved.domain = candidate.domain; saved.groupName = group
            saved.tagsText = tags; saved.notes = notes; saved.settingsData = candidate.settingsData
            saved.credentialReference = candidate.credentialReference; saved.updatedAt = .now
            try MachineOrganization.include(names: [saved.groupName], tags: saved.tags, context: writer)
            try writer.save()
            // From this point the new key belongs to the committed record, even if UI refresh fails.
            newCredential = nil
            if let oldCredential, oldCredential != saved.credentialReference { try? RDPCredentials.delete(oldCredential) }
            if let record {
                record.name = saved.name; record.host = saved.host; record.port = saved.port
                record.username = saved.username; record.domain = saved.domain; record.groupName = saved.groupName
                record.tagsText = saved.tagsText; record.notes = saved.notes; record.settingsData = saved.settingsData
                record.credentialReference = saved.credentialReference; record.updatedAt = saved.updatedAt
            }
            onSave(record ?? saved, connect, password.isEmpty ? nil : password)
            password = ""; dismiss()
        } catch {
            if let newCredential { try? RDPCredentials.delete(newCredential) }
            self.error = error.localizedDescription
        }
    }
}

struct RDPMachineDetail: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.modelContext) private var context
    let record: RDPConnectionRecord
    let onBack: () -> Void
    @State private var editing = false
    @State private var deleting = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Button("机器", systemImage: "chevron.left", action: onBack)
                Spacer()
                Button("编辑", systemImage: "pencil") { editing = true }
                Button("删除", systemImage: "trash", role: .destructive) { deleting = true }
            }
            Label(record.displayName, systemImage: "desktopcomputer").font(.largeTitle.bold())
            Text("RDP · \(record.username)@\(record.host):\(record.port)").font(.title3).textSelection(.enabled)
            if !record.domain.isEmpty { LabeledContent("域", value: record.domain) }
            if let settings = try? record.settings() {
                LabeledContent("显示", value: "\(settings.width) × \(settings.height) · \(settings.colorDepth) 位")
                LabeledContent("安全", value: "NLA/CredSSP · \(settings.certificatePolicy.title)")
                LabeledContent("音频", value: settings.audio.title)
            }
            Text("RDP 不参与 SSH 监控或 SSH 会话导入导出。Windows 实机兼容性仍待验收。")
                .foregroundStyle(.secondary)
            HStack {
                Button("连接远程桌面", systemImage: "play.fill") { appState.openRDP(record) }.buttonStyle(.borderedProminent)
                Button("新建 RDP 标签") { appState.openRDP(record, newTab: true) }
            }
            if let error { Text(error).foregroundStyle(.red) }
            Spacer()
        }.padding(28)
            .sheet(isPresented: $editing) { RDPEditorView(record: record) { value, connect, password in if connect { appState.openRDP(value, newTab: true, password: password) } } }
            .confirmationDialog("删除 RDP 机器并关闭其会话？", isPresented: $deleting) {
                Button("删除并取消传输", role: .destructive) {
                    do {
                        let credential = record.credentialReference
                        appState.removeRDP(record.id)
                        context.delete(record); try context.save()
                        if let credential { try? RDPCredentials.delete(credential) }
                        onBack()
                    } catch { self.error = error.localizedDescription }
                }
            }
    }
}

struct RDPSessionPicker: View {
    @Environment(\.dismiss) private var dismiss
    let servers: [ServerRecord]
    let rdpMachines: [RDPConnectionRecord]
    let onSSH: (ServerRecord) -> Void
    let onRDP: (RDPConnectionRecord) -> Void
    @State private var search = ""
    var body: some View {
        NavigationStack {
            List {
                Section("SSH") {
                    ForEach(servers.filter { search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search) || $0.host.localizedCaseInsensitiveContains(search) }) { server in
                        Button { dismiss(); onSSH(server) } label: { Label(server.displayName + " · " + server.host, systemImage: "terminal").frame(minHeight: 44) }.buttonStyle(.plain)
                    }
                }
                Section("RDP") {
                    ForEach(rdpMachines.filter { search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search) || $0.host.localizedCaseInsensitiveContains(search) }) { record in
                        Button { dismiss(); onRDP(record) } label: { Label(record.displayName + " · " + record.host, systemImage: "desktopcomputer").frame(minHeight: 44) }.buttonStyle(.plain)
                    }
                }
            }.searchable(text: $search, prompt: "搜索机器").navigationTitle("选择会话机器")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }.frame(width: 500, height: 440)
    }
}
