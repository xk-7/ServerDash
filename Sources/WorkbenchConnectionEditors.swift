import SwiftData
import SwiftUI

struct SSHConnectionRouteEditor: View {
    @Environment(\.dismiss) private var dismiss
    let server: ServerRecord
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("\(server.displayName) · 连接路线与代理").font(.title2.bold()); Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(20)
            Divider()
            ProfessionalConnectionsView(initialServerID: server.id, routeOnly: true)
        }.frame(width: 860, height: 700)
    }
}

struct VNCEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let record: VNCConnectionRecord?
    @State private var name: String
    @State private var host: String
    @State private var port: Int
    @State private var group: String
    @State private var tags: String
    @State private var notes: String
    @State private var error: String?
    @State private var opening = false
    @State private var savedRecord: VNCConnectionRecord?
    init(record: VNCConnectionRecord? = nil) {
        self.record = record; _name = State(initialValue: record?.name ?? "")
        _host = State(initialValue: record?.host ?? ""); _port = State(initialValue: record?.port ?? 5900)
        _group = State(initialValue: record?.groupName ?? "默认分组")
        _tags = State(initialValue: record?.tagsText ?? ""); _notes = State(initialValue: record?.notes ?? "")
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(record == nil ? "新建 VNC 主机" : "编辑 VNC 主机").font(.title2.bold()); Spacer() }.padding(20)
            Divider()
            Form {
                Section("连接信息") {
                    TextField("名称", text: $name); TextField("主机地址", text: $host)
                    TextField("端口", value: $port, format: .number.grouping(.never))
                    Text("连接时打开 macOS 屏幕共享；登录凭据由系统客户端处理。").font(.caption).foregroundStyle(.secondary)
                }
                Section("整理") {
                    TextField("分组", text: $group); TextField("标签（逗号分隔）", text: $tags)
                    TextField("备注", text: $notes, axis: .vertical).lineLimit(2...4)
                }
            }.formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red).font(.caption).padding(.horizontal, 20) }
            Divider()
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction); Spacer()
                Button("保存") { save(connect: false) }
                Button("保存并打开屏幕共享") { save(connect: true) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }.padding(16).disabled(opening)
        }.frame(width: 550, height: 500)
    }
    private func save(connect: Bool) {
        do {
            _ = try VNCAddress.url(host: host, port: port)
            let item = savedRecord ?? record ?? VNCConnectionRecord(name: name, host: host, port: port)
            item.name = name; item.host = host.trimmingCharacters(in: .whitespacesAndNewlines); item.port = port
            item.groupName = group; item.tagsText = tags; item.notes = notes; item.updatedAt = .now
            if item.modelContext == nil { context.insert(item) }
            try MachineOrganization.include(names: [item.groupName], tags: item.tags, context: context)
            try context.save(); savedRecord = item
            if connect {
                opening = true
                Task { do { try await WorkbenchConnectionLauncher.openVNC(item); dismiss() } catch { self.error = error.localizedDescription }; opening = false }
            } else { dismiss() }
        } catch { self.error = error.localizedDescription }
    }
}

struct SerialEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    let record: SerialConnectionRecord?
    @State private var name: String
    @State private var configuration: SerialPortConfiguration
    @State private var group: String
    @State private var tags: String
    @State private var notes: String
    @State private var devices: [SerialDevice] = []
    @State private var error: String?
    init(record: SerialConnectionRecord? = nil) {
        self.record = record; _name = State(initialValue: record?.name ?? "")
        _configuration = State(initialValue: record?.configuration ?? SerialPortConfiguration(devicePath: ""))
        _group = State(initialValue: record?.groupName ?? "默认分组")
        _tags = State(initialValue: record?.tagsText ?? ""); _notes = State(initialValue: record?.notes ?? "")
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(record == nil ? "新建串口连接" : "编辑串口连接").font(.title2.bold()); Spacer() }.padding(20)
            Divider()
            Form {
                Section("设备") {
                    TextField("名称", text: $name)
                    HStack {
                        Picker("本机设备", selection: $configuration.devicePath) {
                            Text("选择串口…").tag("")
                            if !configuration.devicePath.isEmpty, !devices.contains(where: { $0.path == configuration.devicePath }) {
                                Text("\(configuration.devicePath)（未检测到）").tag(configuration.devicePath)
                            }
                            ForEach(devices) { device in Text(device.name).tag(device.path) }
                        }
                        Button { devices = SerialDeviceDiscovery.devices() } label: { Image(systemName: "arrow.clockwise") }.help("刷新串口设备")
                    }
                    if devices.isEmpty { Text("未检测到串口。连接 USB 串口适配器后刷新。").font(.caption).foregroundStyle(.secondary) }
                }
                Section("通信参数") {
                    Picker("波特率", selection: $configuration.baudRate) { ForEach(SerialPortConfiguration.baudRates, id: \.self) { Text(String($0)).tag($0) } }
                    Picker("数据位", selection: $configuration.dataBits) { ForEach(5...8, id: \.self) { Text(String($0)).tag($0) } }
                    Picker("校验", selection: $configuration.parity) { Text("无").tag(SerialParity.none); Text("偶校验").tag(SerialParity.even); Text("奇校验").tag(SerialParity.odd) }
                    Picker("停止位", selection: $configuration.stopBits) { Text("1").tag(1); Text("2").tag(2) }
                    Picker("流控", selection: $configuration.flowControl) { Text("无").tag(SerialFlowControl.none); Text("RTS/CTS").tag(SerialFlowControl.hardware); Text("XON/XOFF").tag(SerialFlowControl.software) }
                }
                Section("整理") {
                    TextField("分组", text: $group); TextField("标签（逗号分隔）", text: $tags)
                    TextField("备注", text: $notes, axis: .vertical).lineLimit(2...4)
                }
            }.formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red).font(.caption).padding(.horizontal, 20) }
            Divider()
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction); Spacer()
                Button("保存") { save(connect: false) }
                Button("保存并连接") { save(connect: true) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }.padding(16)
        }.frame(width: 550, height: 620).onAppear { devices = SerialDeviceDiscovery.devices() }
    }
    private func save(connect: Bool) {
        do {
            try configuration.validate()
            let item = record ?? SerialConnectionRecord(name: name)
            item.name = name; item.devicePath = configuration.devicePath; item.baudRate = configuration.baudRate
            item.dataBits = configuration.dataBits; item.parityRawValue = configuration.parity.rawValue
            item.stopBits = configuration.stopBits; item.flowControlRawValue = configuration.flowControl.rawValue
            item.groupName = group; item.tagsText = tags; item.notes = notes; item.updatedAt = .now
            if record == nil { context.insert(item) }
            try MachineOrganization.include(names: [item.groupName], tags: item.tags, context: context)
            try context.save()
            if connect { try WorkbenchConnectionLauncher.openSerial(item, appState: appState, reconnect: true) }; dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct SSHAdvancedEditorSection: View {
    @Binding var draft: SSHAdvancedSettingsDraft
    var body: some View {
        Section("高级连接设置") {
            Toggle("保持连接（Keep-Alive）", isOn: $draft.keepAliveEnabled)
            if draft.keepAliveEnabled {
                TextField("心跳间隔（10–300 秒）", value: $draft.keepAliveInterval, format: .number.grouping(.never))
                TextField("最大失败次数（1–10）", value: $draft.keepAliveCountMax, format: .number.grouping(.never))
            }
            TextField("TCP 连接超时（5–300 秒）", value: $draft.connectTimeout, format: .number.grouping(.never))
            TextField("SSH 认证等待（10–120 秒）", value: $draft.authenticationTimeout, format: .number.grouping(.never))
            Toggle("保存本机会话输出日志", isOn: $draft.logOutput)
            if draft.logOutput { Text("原始终端输出写入本机 Application Support/ServerDash/SessionLogs，可能包含服务器回显的敏感信息。").font(.caption).foregroundStyle(.secondary) }
            Toggle("启用本地连接命令", isOn: $draft.commandsEnabled)
            TextField("连接前执行", text: $draft.beforeConnectCommand, axis: .vertical).lineLimit(2...5).font(.system(.body, design: .monospaced))
            TextField("认证成功后执行", text: $draft.afterConnectCommand, axis: .vertical).lineLimit(2...5).font(.system(.body, design: .monospaced))
            Text("命令在本机独立 Shell 中执行，仅在主动打开或重连 SSH 终端时运行；不会在监控、SFTP 或同步时运行。单次命令最长 30 秒。").font(.caption).foregroundStyle(.secondary)
        }
    }
}
