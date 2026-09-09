import AppKit
import SwiftData
import SwiftUI

enum MachineTagTint: String, CaseIterable, Identifiable {
    case accent, blue, purple, green, red, orange, gray
    var id: String { rawValue }
    var title: String { switch self { case .accent: "强调色"; case .blue: "蓝色"; case .purple: "紫色"; case .green: "绿色"; case .red: "红色"; case .orange: "橙色"; case .gray: "灰色" } }
    var color: Color { switch self { case .accent: .appAccent; case .blue: .blue; case .purple: .purple; case .green: .green; case .red: .red; case .orange: .orange; case .gray: .gray } }
}

enum WorkbenchMachine: Identifiable {
    case ssh(ServerRecord), rdp(RDPConnectionRecord), vnc(VNCConnectionRecord), serial(SerialConnectionRecord)
    var uuid: UUID { switch self { case .ssh(let r): r.id; case .rdp(let r): r.id; case .vnc(let r): r.id; case .serial(let r): r.id } }
    var id: String { kind + "/" + uuid.uuidString }
    var kind: String { switch self { case .ssh: "SSH"; case .rdp: "RDP"; case .vnc: "VNC"; case .serial: "SERIAL" } }
    var name: String { switch self { case .ssh(let r): r.displayName; case .rdp(let r): r.displayName; case .vnc(let r): r.displayName; case .serial(let r): r.displayName } }
    var group: String {
        let value: String = switch self { case .ssh(let r): r.groupName; case .rdp(let r): r.groupName; case .vnc(let r): r.groupName; case .serial(let r): r.groupName }
        let clean = MachineOrganization.cleanName(value)
        return clean.isEmpty ? "默认分组" : clean
    }
    var tags: [String] { switch self { case .ssh(let r): r.tags; case .rdp(let r): r.tags; case .vnc(let r): r.tags; case .serial(let r): r.tags } }
    var notes: String { switch self { case .ssh(let r): r.notes; case .rdp(let r): r.notes; case .vnc(let r): r.notes; case .serial(let r): r.notes } }
    var address: String { switch self { case .ssh(let r): "\(r.username)@\(r.host):\(r.port)"; case .rdp(let r): "\(r.username)@\(r.host):\(r.port)"; case .vnc(let r): "\(r.host):\(r.port)"; case .serial(let r): r.devicePath } }
    var createdAt: Date { switch self { case .ssh(let r): r.createdAt; case .rdp(let r): r.createdAt; case .vnc(let r): r.createdAt; case .serial(let r): r.createdAt } }
    @MainActor var lastOpened: Date? { switch self { case .ssh(let r): r.lastConnectedAt; case .rdp(let r): RDPConnectionActivityStore.shared.lastConnectedAt(for: r.id); case .vnc(let r): r.lastLaunchedAt; case .serial(let r): r.lastConnectedAt } }
    var symbol: String { switch self { case .ssh: "terminal"; case .rdp, .vnc: "desktopcomputer"; case .serial: "cable.connector" } }
    func setGroup(_ name: String) {
        switch self { case .ssh(let r): r.groupName = name; case .rdp(let r): r.groupName = name; case .vnc(let r): r.groupName = name; case .serial(let r): r.groupName = name }
    }
    func setTags(_ names: [String]) {
        let value = names.joined(separator: ",")
        switch self { case .ssh(let r): r.tagsText = value; case .rdp(let r): r.tagsText = value; case .vnc(let r): r.tagsText = value; case .serial(let r): r.tagsText = value }
    }
}

struct MachineManagementView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var rdpActivity = RDPConnectionActivityStore.shared
    @Environment(\.modelContext) private var context
    @Query(sort: \VNCConnectionRecord.name) private var vnc: [VNCConnectionRecord]
    @Query(sort: \SerialConnectionRecord.name) private var serial: [SerialConnectionRecord]
    @Query(sort: \MachineGroupRecord.name) private var groups: [MachineGroupRecord]
    @Query(sort: \MachineTagRecord.name) private var tags: [MachineTagRecord]
    @AppStorage("hideIPInformation") private var hideIP = false
    @AppStorage("machineViewMode") private var mode = MachineViewMode.grid.rawValue
    @SceneStorage("machines.filter.group") private var group = ""
    @SceneStorage("machines.filter.tag") private var tag = ""
    @SceneStorage("machines.sort") private var sort = ServerBrowserSort.name.rawValue
    @SceneStorage("machines.filter.monitoring") private var monitoring = ServerMonitorFilter.all.rawValue
    @SceneStorage("machines.filter.protocol") private var protocolFilter = "all"
    @SceneStorage("machines.groups.visible") private var showsGroups = true
    @State private var selection = Set<String>()
    @State private var organization = false
    @State private var batchEdit = false
    @State private var batchGroup = ""
    @State private var batchTag = ""
    @State private var confirmDelete = false
    @State private var selectedImport: SessionTransferSource?
    @State private var exportSelection = false
    @State private var localTransfer: LocalConfigurationTransferMode?
    @State private var showsSync = false
    @State private var error: String?
    @State private var editingRDP: RDPConnectionRecord?
    @State private var editingVNC: VNCConnectionRecord?
    @State private var editingSerial: SerialConnectionRecord?

    let servers: [ServerRecord]
    var rdpMachines: [RDPConnectionRecord] = []
    var onSelectRDP: (RDPConnectionRecord) -> Void = { _ in }
    @Binding var searchText: String
    @Binding var scrollAnchor: UUID?
    let onSelect: (ServerRecord) -> Void
    let onAdd: () -> Void
    let onImport: () -> Void
    let onExport: () -> Void
    let onEdit: (ServerRecord) -> Void
    let onDelete: (ServerRecord) -> Void

    private var all: [WorkbenchMachine] {
        servers.map(WorkbenchMachine.ssh) + rdpMachines.map(WorkbenchMachine.rdp) +
        vnc.map(WorkbenchMachine.vnc) + serial.map(WorkbenchMachine.serial)
    }
    private var filtered: [WorkbenchMachine] {
        let terms = searchText.split(whereSeparator: \.isWhitespace).map(String.init)
        let includedGroups = groupNames(in: group)
        return all.filter { item in
            let monitorMatches: Bool
            if case .ssh(let server) = item {
                monitorMatches = monitoring == "all" || (monitoring == "enabled" ? server.enableDashboardMonitor : !server.enableDashboardMonitor)
            } else { monitorMatches = monitoring == "all" }
            return (protocolFilter == "all" || item.kind.lowercased() == protocolFilter) &&
                (group.isEmpty || includedGroups.contains(item.group)) && (tag.isEmpty || item.tags.contains(tag)) && monitorMatches &&
                terms.allSatisfy { term in [item.name, item.address, item.group, item.tags.joined(separator: " "), item.notes].contains { $0.localizedCaseInsensitiveContains(term) } }
        }.sorted {
            if sort == "newest", $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            if sort == "group", $0.group != $1.group { return $0.group.localizedStandardCompare($1.group) == .orderedAscending }
            let order = $0.name.localizedStandardCompare($1.name)
            if order != .orderedSame { return order == (sort == "nameDescending" ? .orderedDescending : .orderedAscending) }
            return $0.id < $1.id
        }
    }
    private var selected: [WorkbenchMachine] { all.filter { selection.contains($0.id) } }
    private var hasFilters: Bool { !searchText.isEmpty || !group.isEmpty || !tag.isEmpty || protocolFilter != "all" || monitoring != "all" }
    private func groupNames(in name: String) -> Set<String> {
        guard let parent = groups.first(where: { $0.name == name }) else { return [name] }
        let ids = MachineOrganization.descendants(of: parent.id, groups: groups)
        return Set(groups.filter { ids.contains($0.id) }.map(\.name))
    }

    var body: some View {
        GeometryReader { geometry in
            let groupPanelVisible = showsGroups && geometry.size.width >= 960
            let contentWidth = geometry.size.width - (groupPanelVisible ? 191 : 0)
            VStack(spacing: 0) {
                header(compact: geometry.size.width < 760)
                Divider()
                HStack(spacing: 0) {
                    if groupPanelVisible {
                        groupPanel.frame(width: 190)
                        Divider()
                    }
                    VStack(spacing: 0) {
                        filters(compact: !groupPanelVisible)
                        Divider()
                        if filtered.isEmpty { emptyState }
                        else if mode == MachineViewMode.list.rawValue { machineTable(compact: contentWidth < 760) }
                        else { machineGrid }
                    }
                }
            }
            .background(Color.appGround)
        }
        .onChange(of: filtered.map(\.id)) { _, ids in selection.formIntersection(ids) }
        .onChange(of: Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.name) })) { before, after in
            if let id = before.first(where: { $0.value == group })?.key { group = after[id] ?? "" }
        }
        .onChange(of: Dictionary(uniqueKeysWithValues: tags.map { ($0.id, $0.name) })) { before, after in
            if let id = before.first(where: { $0.value == tag })?.key { tag = after[id] ?? "" }
        }
        .sheet(isPresented: $organization) { MachineOrganizationEditor(machines: all) }
        .sheet(isPresented: $showsSync) { WebDAVSyncView() }
        .sheet(item: $localTransfer) { LocalConfigurationTransferView(mode: $0) }
        .sheet(isPresented: $exportSelection) { SessionExportWizard(servers: selected.compactMap { if case .ssh(let r) = $0 { return r }; return nil }) }
        .sheet(item: $selectedImport) { source in SessionImportWizard(existingServers: servers, initialSource: source) }
        .sheet(item: $editingRDP) { record in
            RDPEditorView(record: record) { value, connect, password in
                if connect { appState.openRDP(value, newTab: true, password: password) }
            }
        }
        .sheet(item: $editingVNC) { VNCEditorView(record: $0) }
        .sheet(item: $editingSerial) { SerialEditorView(record: $0) }
        .sheet(isPresented: $batchEdit) { batchEditor }
        .confirmationDialog("删除所选 \(selection.count) 台主机？", isPresented: $confirmDelete) {
            Button("删除主机", role: .destructive) { deleteSelected() }
        } message: { Text("配置及专用凭据会被移除，活动连接会关闭。共享身份会保留。") }
        .alert("操作失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func header(compact: Bool) -> some View {
        HStack(spacing: AppleDesign.Spacing.sm) {
            VStack(alignment: .leading, spacing: 3) {
                Label("主机管理", systemImage: "server.rack").font(.headline)
                Text("\(all.count) 台主机 · \(appState.terminalRegistry.workspace.tabs.count) 个会话")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 8)
            HStack(spacing: AppleDesign.Spacing.sm) {
            Toggle(isOn: $hideIP) { Label("隐私模式", systemImage: hideIP ? "eye.slash" : "eye") }
                .toggleStyle(.button).help("隐藏连接地址和位置信息")
            Menu {
                Button("本机主机配置包…") { localTransfer = .importFile }
                Divider()
                ForEach(SessionTransferSource.allCases) { source in Button(source.title) { selectedImport = source } }
            } label: { Label("导入", systemImage: "square.and.arrow.down") }
            Menu {
                Button("主机配置包（全部协议）…") { localTransfer = .exportAll }.disabled(all.isEmpty)
                Button("SSH 兼容格式…", action: onExport).disabled(servers.isEmpty)
            } label: { Image(systemName: "square.and.arrow.up") }.help("导出主机配置").accessibilityLabel("导出主机配置")
            Button { showsSync = true } label: { Label("同步", systemImage: "arrow.triangle.2.circlepath") }.help("WebDAV 配置同步")
            Button("新建主机", systemImage: "plus", action: onAdd).buttonStyle(.borderedProminent)
                .help("新建主机")
            }.labelStyle(WorkbenchMachineActionLabelStyle(compact: compact))
        }
        .controlSize(.regular).padding(AppleDesign.Spacing.md)
    }

    private func filters(compact: Bool) -> some View {
        VStack(spacing: 10) {
            HStack {
                if !compact {
                    Button { showsGroups.toggle() } label: { Image(systemName: "sidebar.leading") }
                        .help("显示或隐藏分组").accessibilityLabel("显示或隐藏分组")
                }
                AppleSearchField(prompt: "搜索主机、地址、标签或备注", text: $searchText)
                Picker("协议", selection: $protocolFilter) {
                    Text("全部协议").tag("all")
                    ForEach(["SSH", "RDP", "VNC", "SERIAL"], id: \.self) { Text($0).tag($0.lowercased()) }
                }.frame(width: 130).labelsHidden()
                Menu {
                    Picker("排序", selection: $sort) { ForEach(ServerBrowserSort.allCases) { Text($0.title).tag($0.rawValue) } }
                    Picker("监控", selection: $monitoring) { ForEach(ServerMonitorFilter.allCases) { Text($0.title).tag($0.rawValue) } }
                    Button("管理分组与标签") { organization = true }
                } label: { Image(systemName: "line.3.horizontal.decrease") }.help("排序与监控筛选")
                Picker("显示方式", selection: $mode) {
                    ForEach(MachineViewMode.allCases) { Image(systemName: $0.symbol).tag($0.rawValue).accessibilityLabel($0.title) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 76)
            }
            if compact || !showsGroups {
                HStack {
                    Picker("分组", selection: $group) {
                        Text("全部分组").tag("")
                        if !groups.contains(where: { $0.name == "默认分组" }) { Text("默认分组").tag("默认分组") }
                        ForEach(groupRows(), id: \.0.id) { item in Text(String(repeating: "　", count: item.1) + item.0.name).tag(item.0.name) }
                    }
                    Picker("标签", selection: $tag) { Text("全部标签").tag(""); ForEach(tags) { Text($0.name).tag($0.name) } }
                }
            }
            HStack {
                Toggle("全选", isOn: Binding(get: { !filtered.isEmpty && selection.count == filtered.count },
                                             set: { selection = $0 ? Set(filtered.map(\.id)) : [] })).toggleStyle(.checkbox)
                Text(selection.isEmpty ? "\(filtered.count) 台" : "已选 \(selection.count) 台").foregroundStyle(.secondary)
                if !selection.isEmpty {
                    Button("整理") { batchGroup = ""; batchTag = ""; batchEdit = true }
                    Button("导出配置包") { localTransfer = .exportSelected(selection) }
                    Button("删除", role: .destructive) { confirmDelete = true }
                }
                Spacer()
                if hasFilters { Button("清除筛选") { searchText = ""; group = ""; tag = ""; protocolFilter = "all"; monitoring = "all" } }
            }.font(.caption).buttonStyle(.borderless)
        }.padding(AppleDesign.Spacing.md)
    }

    private var groupPanel: some View {
        VStack(spacing: 0) {
            List {
                Section("分组导航") {
                    Button { group = "" } label: { Label("全部主机", systemImage: "square.grid.2x2").foregroundStyle(group.isEmpty ? Color.appAccent : .primary) }
                    if !groups.contains(where: { $0.name == "默认分组" }) {
                        Button { group = "默认分组" } label: {
                            Label("默认分组", systemImage: "folder").foregroundStyle(group == "默认分组" ? Color.appAccent : .primary)
                        }
                    }
                    ForEach(groupRows(), id: \.0.id) { item in
                        Button { group = item.0.name } label: {
                            HStack {
                                Label(item.0.name, systemImage: "folder").lineLimit(1)
                                Spacer()
                                Text("\(all.filter { groupNames(in: item.0.name).contains($0.group) }.count)").foregroundStyle(.secondary)
                            }.padding(.leading, CGFloat(item.1) * 12)
                                .foregroundStyle(group == item.0.name ? Color.appAccent : .primary)
                        }.help("\(item.0.name)（包含子分组）")
                    }
                }
                Section("标签筛选") {
                    Button("全部标签") { tag = "" }
                    ForEach(tags) { value in
                        Button { tag = value.name } label: {
                            Label { Text(value.name).foregroundStyle(tag == value.name ? Color.appAccent : .secondary) }
                                icon: { Image(systemName: "tag").foregroundStyle((MachineTagTint(rawValue: value.colorName) ?? .accent).color) }
                        }
                    }
                }
            }.listStyle(.sidebar).buttonStyle(.plain)
            Button("管理分组与标签", systemImage: "slider.horizontal.3") { organization = true }
                .frame(maxWidth: .infinity).padding(12)
        }
    }
    private func groupRows() -> [(MachineGroupRecord, Int)] {
        var rows: [(MachineGroupRecord, Int)] = []
        var visited = Set<UUID>()
        func append(_ parent: UUID?, depth: Int) {
            for value in groups where value.parentID == parent && !visited.contains(value.id) {
                visited.insert(value.id); rows.append((value, depth)); append(value.id, depth: depth + 1)
            }
        }
        append(nil, depth: 0)
        for value in groups where !visited.contains(value.id) { rows.append((value, 0)) }
        return rows
    }

    private var machineGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16)], spacing: 16) {
                ForEach(filtered) { item in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: item.symbol).font(.title2).foregroundStyle(.secondary)
                            Spacer()
                            machineStatus(item)
                            Toggle("选择 \(item.name)", isOn: selectionBinding(item)).labelsHidden().toggleStyle(.checkbox)
                        }
                        Button { show(item) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack { Text(item.name).font(.headline).lineLimit(1); protocolBadge(item.kind) }
                                Text(hideIP ? "连接地址已隐藏" : item.address).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                machineSystem(item)
                                Text(item.notes.isEmpty ? "暂无备注" : item.notes).font(.caption).foregroundStyle(.secondary).lineLimit(2).frame(height: 30, alignment: .top)
                                HStack {
                                    Text(item.group.isEmpty ? "默认分组" : item.group).lineLimit(1)
                                    Spacer()
                                    if item.kind == "VNC", let date = item.lastOpened { Text(date, style: .relative).help("最后启动时间") }
                                }.font(.caption).foregroundStyle(.secondary)
                                tagSummary(item.tags).font(.caption).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Divider()
                        Button { connect(item) } label: { Label(item.kind == "VNC" ? "打开屏幕共享" : "快速连接", systemImage: "bolt.horizontal").frame(maxWidth: .infinity) }
                    }.applePanel(radius: AppleDesign.Radius.card)
                        .overlay { RoundedRectangle(cornerRadius: AppleDesign.Radius.card).stroke(selection.contains(item.id) ? Color.appAccent : .clear, lineWidth: 2) }
                        .contextMenu { itemMenu(item) }
                        .id(item.uuid)
                }
            }.scrollTargetLayout().padding(16)
        }.scrollPosition(id: $scrollAnchor, anchor: .top)
    }

    private func machineTable(compact: Bool) -> some View {
        Group {
            if compact {
                Table(filtered, selection: $selection) {
                    TableColumn("主机信息") { machineInformation($0, compact: true) }.width(min: 160, ideal: 240)
                    TableColumn("状态 / 延迟") { machineStatus($0) }.width(min: 90, ideal: 100)
                    TableColumn("协议") { protocolBadge($0.kind) }.width(60)
                    TableColumn("") { machineConnectButton($0) }.width(36)
                }
            } else {
                Table(filtered, selection: $selection) {
                    TableColumn("主机信息") { machineInformation($0, compact: false) }.width(min: 160, ideal: 240)
                    TableColumn("状态 / 延迟") { machineStatus($0) }.width(min: 90, ideal: 100)
                    TableColumn("协议") { protocolBadge($0.kind) }.width(60)
                    TableColumn("分组") { Text($0.group).lineLimit(1) }.width(min: 65, ideal: 100)
                    TableColumn("标签") { tagSummary($0.tags).lineLimit(1) }.width(min: 65, ideal: 100)
                    TableColumn("最近连接 / 启动") { item in
                        if let date = item.lastOpened { Text(date, style: .relative).font(.caption).help(item.kind == "VNC" ? "最后启动系统屏幕共享的时间，不代表连接成功" : "最近连接时间") }
                        else { Text("—").foregroundStyle(.secondary) }
                    }.width(110)
                    TableColumn("") { machineConnectButton($0) }.width(36)
                }
            }
        }.contextMenu(forSelectionType: String.self) { ids in
            if ids.count == 1, let item = all.first(where: { ids.contains($0.id) }) { itemMenu(item) }
            if !ids.isEmpty {
                Button("整理所选主机") { selection = ids; batchGroup = ""; batchTag = ""; batchEdit = true }
                Button("导出所选主机配置包") { selection = ids; localTransfer = .exportSelected(ids) }
                Button("导出所选 SSH") { selection = ids; exportSelection = true }
                    .disabled(!all.contains { ids.contains($0.id) && $0.kind == "SSH" })
                Button("删除所选主机", role: .destructive) { selection = ids; confirmDelete = true }
            }
        } primaryAction: { ids in if let item = all.first(where: { ids.contains($0.id) }) { show(item) } }
    }
    private func machineInformation(_ item: WorkbenchMachine, compact: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Button { show(item) } label: { Text(item.name).fontWeight(.medium).lineLimit(1) }
                    .buttonStyle(.plain).foregroundStyle(Color.appAccent).help("查看 \(item.name) 详情")
                Text(hideIP ? "连接地址已隐藏" : item.address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                machineSystem(item)
                if compact {
                    (Text(item.group + (item.tags.isEmpty ? "" : " · ")).foregroundColor(.secondary) + tagSummary(item.tags, empty: "")).font(.caption).lineLimit(1)
                    if let date = item.lastOpened { Text(date, style: .relative).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }.padding(.vertical, 7).onTapGesture(count: 2) { show(item) }.contextMenu { itemMenu(item) }
    }
    private func machineConnectButton(_ item: WorkbenchMachine) -> some View {
        Button { connect(item) } label: { Image(systemName: "bolt.horizontal") }
            .help(item.kind == "VNC" ? "打开系统屏幕共享" : "连接 \(item.name)")
    }
    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "server.rack").font(.largeTitle).foregroundStyle(.secondary)
            Text(hasFilters ? "没有匹配的主机" : "还没有任何主机").font(.title2.weight(.semibold))
            Text(hasFilters ? "调整搜索、协议、分组或标签。" : "新建主机，或导入已有连接配置。").foregroundStyle(.secondary)
            if !hasFilters {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 175))], spacing: 12) {
                    ForEach(SessionTransferSource.allCases.filter { [.xShell, .finalShell, .secureCRT, .mobaXterm, .xTerminal, .putty].contains($0) }) { source in
                        Button { selectedImport = source } label: { Label("从 \(source.title) 导入", systemImage: source.symbol).frame(maxWidth: .infinity, alignment: .leading).padding(10) }
                    }
                }.frame(maxWidth: 720)
                Button("新建主机", systemImage: "plus", action: onAdd).buttonStyle(.borderedProminent)
            }
            Spacer()
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    @ViewBuilder private func machineStatus(_ item: WorkbenchMachine) -> some View {
        if case .ssh(let server) = item { MachineLiveState(server: server, runtime: appState.runtime(for: server)) }
        else if case .vnc = item { Text("由系统管理").font(.caption).foregroundStyle(.secondary).help("系统屏幕共享独立运行，ServerDash 无法读取其在线状态。") }
        else if case .serial = item { MachineSerialLiveState(registry: appState.workbenchSessions, machineID: item.uuid) }
        else if let controller = appState.rdpControllers.values.filter({ $0.machineID == item.uuid }).sorted(by: { $0.state == .connected && $1.state != .connected }).first {
            MachineRDPLiveState(controller: controller)
        } else { Text("未连接").font(.caption).foregroundStyle(.secondary) }
    }
    @ViewBuilder private func machineSystem(_ item: WorkbenchMachine) -> some View {
        if case .ssh(let server) = item {
            MachineSystemLabel(runtime: appState.runtime(for: server))
        } else {
            Text(item.kind == "RDP" ? "Windows" : "—").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func protocolBadge(_ value: String) -> some View {
        Text(value).font(.caption.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 3)
            .background(Color.appTrack, in: RoundedRectangle(cornerRadius: AppleDesign.Radius.chip))
    }
    private func tagSummary(_ names: [String], empty: String = "无标签") -> Text {
        guard !names.isEmpty else { return Text(empty).foregroundColor(.secondary) }
        return names.enumerated().reduce(Text("")) { result, item in
            let color = tags.first { $0.name == item.element }.flatMap { MachineTagTint(rawValue: $0.colorName) }?.color ?? .appAccent
            return result + Text((item.offset == 0 ? "" : "  ") + "#" + item.element).foregroundColor(color)
        }
    }
    private func selectionBinding(_ item: WorkbenchMachine) -> Binding<Bool> {
        Binding(get: { selection.contains(item.id) }, set: { if $0 { selection.insert(item.id) } else { selection.remove(item.id) } })
    }
    @ViewBuilder private func itemMenu(_ item: WorkbenchMachine) -> some View {
        Button(item.kind == "VNC" ? "打开屏幕共享" : "快速连接") { connect(item) }
        Button("详情") { show(item) }
        Button("编辑") {
            switch item { case .ssh(let r): onEdit(r); case .rdp(let r): editingRDP = r; case .vnc(let r): editingVNC = r; case .serial(let r): editingSerial = r }
        }
        Button("删除", role: .destructive) { selection = [item.id]; confirmDelete = true }
    }
    private func show(_ item: WorkbenchMachine) {
        scrollAnchor = item.uuid
        switch item { case .ssh(let r): onSelect(r); case .rdp(let r): onSelectRDP(r); case .vnc(let r): editingVNC = r; case .serial(let r): editingSerial = r }
    }
    private func connect(_ item: WorkbenchMachine) {
        switch item {
        case .ssh(let r): appState.openTerminal(for: r)
        case .rdp(let r): appState.openRDP(r)
        case .vnc(let r): Task { do { try await WorkbenchConnectionLauncher.openVNC(r); try context.save() } catch { self.error = error.localizedDescription } }
        case .serial(let r): do { try WorkbenchConnectionLauncher.openSerial(r, appState: appState) } catch { self.error = error.localizedDescription }
        }
    }
    private var batchEditor: some View {
        VStack(spacing: 16) {
            Text("整理 \(selection.count) 台主机").font(.title2)
            Form {
                TextField("移动到分组（留空不变）", text: $batchGroup)
                TextField("添加标签（逗号分隔）", text: $batchTag)
            }.formStyle(.grouped)
            HStack { Button("取消") { batchEdit = false }; Spacer(); Button("应用") {
                for item in selected {
                    let input = MachineOrganization.cleanName(batchGroup)
                    let name = groups.first { $0.name.localizedCaseInsensitiveCompare(input) == .orderedSame }?.name ?? input
                    if !name.isEmpty { item.setGroup(name) }
                    let added = batchTag.split(whereSeparator: { ",，;；".contains($0) }).map { value in
                        let input = MachineOrganization.cleanName(String(value))
                        return tags.first { $0.name.localizedCaseInsensitiveCompare(input) == .orderedSame }?.name ?? input
                    }.filter { !$0.isEmpty }
                    if !added.isEmpty { item.setTags(Array(Set(item.tags + added)).sorted()) }
                }
                do {
                    try MachineOrganization.include(names: selected.map(\.group), tags: selected.flatMap(\.tags), context: context)
                    try context.save(); batchEdit = false
                } catch { self.error = error.localizedDescription }
            }.buttonStyle(.borderedProminent) }
        }.padding(20).frame(width: 440, height: 250)
    }
    private func deleteSelected() {
        let victims = selected
        Task {
            do {
                for item in victims {
                    switch item {
                    case .ssh(let r):
                        let id = r.id
                        for rule in try context.fetch(FetchDescriptor<PortForwardRuleRecord>()) where rule.serverID == id {
                            try await appState.stopPortForward(ruleID: rule.id, serverID: id); context.delete(rule)
                        }
                        for route in try context.fetch(FetchDescriptor<ConnectionRouteRecord>()) where route.serverID == id {
                            if let account = route.route?.proxy?.secretAccount { try? KeychainService.deleteSecret(account: account) }
                            context.delete(route)
                        }
                        for advanced in try context.fetch(FetchDescriptor<SSHAdvancedSettingsRecord>()) where advanced.serverID == id { context.delete(advanced) }
                        try KeychainService.deletePassword(for: id)
                        try? KeychainService.deleteSecret(account: KeychainService.passphraseAccount(for: id))
                        appState.removeRuntimeData(for: id); context.delete(r)
                    case .rdp(let r): appState.removeRDP(r.id); if let id = r.credentialReference { try RDPCredentials.delete(id) }; context.delete(r)
                    case .vnc(let r): context.delete(r)
                    case .serial(let r): appState.closeWorkspaceTabs(appState.terminalRegistry.workspace.tabs.filter { $0.serverID == r.id }); context.delete(r)
                    }
                }
                try context.save(); selection = []
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct WorkbenchMachineActionLabelStyle: LabelStyle {
    let compact: Bool
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) { configuration.icon; if !compact { configuration.title } }
    }
}

private struct MachineRDPLiveState: View {
    @ObservedObject var controller: RDPSessionController
    var body: some View {
        Text(controller.needsPassword ? "等待密码" : controller.state.rawValue)
            .font(.caption).foregroundStyle(controller.state == .failed ? Color.appError : .secondary)
    }
}

private struct MachineSerialLiveState: View {
    @ObservedObject var registry: WorkbenchSessionRegistry
    let machineID: UUID
    var body: some View {
        if let controller = registry.controllers.values.filter({ $0.recordID == machineID }).sorted(by: { $0.status == .connected && $1.status != .connected }).first {
            MachineSerialControllerState(controller: controller)
        } else { Text("未连接").font(.caption).foregroundStyle(.secondary) }
    }
}

private struct MachineSerialControllerState: View {
    @ObservedObject var controller: WorkbenchSessionController
    var body: some View {
        Text(controller.status.title).font(.caption)
            .foregroundStyle(controller.status == .failed ? Color.appError : .secondary)
    }
}

private struct MachineLiveState: View {
    let server: ServerRecord
    @ObservedObject var runtime: ServerRuntimeState
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ServerStatusBadge(status: runtime.renderState.status)
            Text(server.lastLatencyMS > 0 ? "\(Int(server.lastLatencyMS)) ms" : "—").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

private struct MachineSystemLabel: View {
    @ObservedObject var runtime: ServerRuntimeState
    var body: some View {
        Text(runtime.renderState.snapshot.distribution.isEmpty ? "—" : runtime.renderState.snapshot.distribution)
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
    }
}
