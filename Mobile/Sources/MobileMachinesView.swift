import SwiftData
import SwiftUI

struct MobileMachinesView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var runtime: MobileRuntime
    @Query(sort: \ServerRecord.name) private var servers: [ServerRecord]
    @SceneStorage("mobile.machines.search") private var search = ""
    @SceneStorage("mobile.machines.group") private var group = ""
    @SceneStorage("mobile.machines.tag") private var tag = ""
    @SceneStorage("mobile.machines.sort") private var sort = ServerBrowserSort.name.rawValue
    @SceneStorage("mobile.machines.monitoring") private var monitoring = ServerMonitorFilter.all.rawValue
    @AppStorage("hideIPInformation") private var hideIPInformation = false
    @State private var editingServer: ServerRecord?
    @State private var showingNewServer = false
    @State private var pendingDelete: ServerRecord?
    @State private var deletionError: String?

    private var query: ServerBrowserQuery {
        ServerBrowserQuery(search: search, group: group, tag: tag,
                           sort: ServerBrowserSort(rawValue: sort) ?? .name,
                           monitoring: ServerMonitorFilter(rawValue: monitoring) ?? .all)
    }

    var body: some View {
        let filtered = query.apply(to: servers)
        List {
            if !servers.isEmpty {
                HStack {
                    Text("\(filtered.count) / \(servers.count) 台").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    MobileServerBrowserMenu(servers: servers, group: $group, tag: $tag, sort: $sort,
                                            monitoring: $monitoring, hasFilters: query.hasFilters, clear: clearFilters)
                }
                .listRowBackground(Color.clear)
            }
            ForEach(filtered) { server in
                NavigationLink {
                    MobileServerDetailView(server: server)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(hideIPInformation && server.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                 ? "未命名服务器" : server.displayName).font(.headline)
                            Spacer()
                            Text(server.enableDashboardMonitor ? (runtime.statuses[server.id]?.title ?? "等待检测") : "已暂停")
                                .font(.caption)
                                .foregroundStyle(runtime.statuses[server.id] == .online ? Color.appLive : .secondary)
                        }
                        Text(hideIPInformation ? "[地址已隐藏]" : "\(server.username)@\(server.host):\(server.port)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        if !server.tags.isEmpty {
                            Text(server.tags.joined(separator: " · "))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 5)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("编辑") { editingServer = server }.tint(.blue)
                    Button("删除", role: .destructive) { pendingDelete = server }
                }
            }
        }
        .searchable(text: $search, prompt: "名称、地址、标签或备注")
        .navigationTitle("机器")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingNewServer = true } label: {
                    Label("添加服务器", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingNewServer) {
            MobileServerEditor(server: nil)
        }
        .sheet(item: $editingServer) { server in
            MobileServerEditor(server: server)
        }
        .confirmationDialog("删除这台服务器？", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible) {
            Button("删除服务器", role: .destructive) {
                if let server = pendingDelete { delete(server) }
                pendingDelete = nil
            }
        } message: {
            Text("将移除本机配置与独立密码，并关闭该机器的会话。远程文件不会被删除。")
        }
        .alert("删除失败", isPresented: Binding(get: { deletionError != nil }, set: { if !$0 { deletionError = nil } })) {
            Button("好", role: .cancel) { deletionError = nil }
        } message: { Text(deletionError ?? "") }
        .overlay {
            if servers.isEmpty {
                ContentUnavailableView {
                    Label("还没有服务器", systemImage: "server.rack")
                } description: { Text("添加服务器后即可使用监控、终端与 SFTP。") }
                actions: {
                    Button("添加服务器", systemImage: "plus") { showingNewServer = true }
                        .buttonStyle(.borderedProminent).frame(minHeight: 44)
                }
            } else if filtered.isEmpty {
                ContentUnavailableView {
                    Label("没有匹配的服务器", systemImage: "magnifyingglass")
                } description: { Text("试试其他关键词、分组或标签。") }
                actions: { Button("清除筛选", action: clearFilters).frame(minHeight: 44) }
            }
        }
    }

    private func delete(_ server: ServerRecord) {
        let serverID = server.id
        do {
            modelContext.delete(server)
            try modelContext.save()
        } catch {
            modelContext.rollback()
            deletionError = error.localizedDescription
            return
        }
        runtime.removeServer(serverID: serverID)
        do { try KeychainService.deletePassword(for: serverID) }
        catch { deletionError = "配置已删除，但本机密码清理失败：\(error.localizedDescription)" }
    }

    private func clearFilters() { search = ""; group = ""; tag = ""; monitoring = "all" }
}

struct MobileServerDetailView: View {
    @EnvironmentObject private var runtime: MobileRuntime
    @Query private var identities: [IdentityRecord]
    @Query private var keys: [SSHKeyRecord]
    @Query private var routes: [ConnectionRouteRecord]
    let server: ServerRecord
    @State private var editing = false
    @AppStorage("hideIPInformation") private var hideIPInformation = false

    private var config: ServerConnectionConfig {
        ConnectionConfigResolver.resolve(
            server: server,
            identities: identities,
            keys: keys,
            routes: routes
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                MobileServerStatusCard(
                    server: server,
                    snapshot: runtime.snapshots[server.id],
                    status: runtime.statuses[server.id] ?? .unknown,
                    error: runtime.errors[server.id],
                    isRefreshing: runtime.refreshingServerIDs.contains(server.id)
                )

                HStack(spacing: 12) {
                    NavigationLink {
                        MobileTerminalScreen(controller: runtime.openTerminal(config: config))
                    } label: {
                        action("终端", symbol: "terminal")
                    }
                    NavigationLink {
                        MobileSFTPView(config: config)
                    } label: {
                        action("SFTP", symbol: "folder")
                    }
                }
                .buttonStyle(.plain)

                GroupBox("连接") {
                    VStack(spacing: 12) {
                        LabeledContent("地址", value: hideIPInformation ? "[地址已隐藏]" : server.host)
                        LabeledContent("端口", value: String(server.port))
                        LabeledContent("用户名", value: config.username)
                        LabeledContent("认证", value: config.authentication.title)
                        LabeledContent("路线", value: config.route.isDirect ? "直接连接" : "移动端不可用")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let snapshot = runtime.snapshots[server.id] {
                    GroupBox("系统") {
                        VStack(spacing: 12) {
                            LabeledContent("发行版", value: snapshot.distribution)
                            LabeledContent("内核", value: snapshot.kernel)
                            LabeledContent("运行时间", value: snapshot.uptime)
                            LabeledContent("进程", value: DisplayFormat.integer(snapshot.processCount))
                            LabeledContent("登录用户", value: DisplayFormat.integer(snapshot.loggedInUsers))
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(Color.appGround)
        .navigationTitle(hideIPInformation && server.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         ? "未命名服务器" : server.displayName)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { runtime.refresh(server: server, identities: identities, keys: keys, routes: routes) } label: {
                    Image(systemName: "arrow.clockwise").frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("刷新这台服务器")
                .disabled(runtime.isBackgrounded || runtime.refreshingServerIDs.contains(server.id))
                Button("编辑") { editing = true }
            }
        }
        .sheet(isPresented: $editing) { MobileServerEditor(server: server) }
    }

    private func action(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(Color.appAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct MobileServerEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \IdentityRecord.name) private var identities: [IdentityRecord]

    let server: ServerRecord?
    @State private var name: String
    @State private var host: String
    @State private var port: Int
    @State private var username: String
    @State private var authentication: AuthenticationMethod
    @State private var groupName: String
    @State private var tags: String
    @State private var notes: String
    @State private var identityID: UUID?
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var enableDashboardMonitor: Bool

    init(server: ServerRecord?) {
        self.server = server
        _name = State(initialValue: server?.name ?? "")
        _host = State(initialValue: server?.host ?? "")
        _port = State(initialValue: server?.port ?? 22)
        _username = State(initialValue: server?.username ?? "")
        _authentication = State(initialValue: server?.authentication ?? .password)
        _groupName = State(initialValue: server?.groupName ?? "默认分组")
        _tags = State(initialValue: server?.tagsText ?? "")
        _notes = State(initialValue: server?.notes ?? "")
        _identityID = State(initialValue: server?.identityID)
        _enableDashboardMonitor = State(initialValue: server?.enableDashboardMonitor ?? true)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("服务器") {
                    TextField("名称", text: $name)
                    TextField("主机或 IP", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("端口", value: $port, format: .number)
                        .keyboardType(.numberPad)
                }
                Section("身份认证") {
                    Picker("共享身份", selection: $identityID) {
                        Text("不使用共享身份").tag(UUID?.none)
                        ForEach(identities) { identity in
                            Text(identity.name).tag(UUID?.some(identity.id))
                        }
                    }
                    if identityID == nil {
                        TextField("用户名", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Picker("认证方式", selection: $authentication) {
                            Text(AuthenticationMethod.password.title).tag(AuthenticationMethod.password)
                        }
                        SecureField("密码", text: $password)
                    } else {
                        Text("共享身份中的用户名、密钥和密码将在连接时使用。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("整理") {
                    TextField("分组", text: $groupName)
                    TextField("标签（逗号分隔）", text: $tags)
                    TextField("备注", text: $notes, axis: .vertical)
                }
                Section("监控") {
                    Toggle("启用自动监控", isOn: $enableDashboardMonitor)
                    Text("暂停后仍可手动刷新、使用终端与 SFTP。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(Color.appError) }
                }
            }
            .navigationTitle(server == nil ? "添加服务器" : "编辑服务器")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }
            }
        }
    }

    private func save() {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty, (1...65_535).contains(port) else {
            errorMessage = "请输入有效的主机和端口。"
            return
        }
        if identityID == nil && username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errorMessage = "请输入用户名或选择共享身份。"
            return
        }

        let value = server ?? ServerRecord(
            name: name,
            host: cleanHost,
            port: port,
            username: username,
            authentication: authentication
        )
        value.name = name
        value.host = cleanHost
        value.port = port
        value.username = username
        value.authentication = authentication
        value.identityID = identityID
        value.groupName = groupName.isEmpty ? "默认分组" : groupName
        value.tagsText = tags
        value.notes = notes
        value.enableDashboardMonitor = enableDashboardMonitor
        if server == nil { modelContext.insert(value) }

        if let identityID, let identity = identities.first(where: { $0.id == identityID }) {
            value.username = identity.username
            value.authentication = identity.authentication
        } else if !password.isEmpty {
            do {
                try KeychainService.savePassword(password, for: value.id)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        do {
            try modelContext.save()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
