import AppKit
import SwiftData
import SwiftUI

struct TerminalBatchTarget: Identifiable, Equatable {
    let id: UUID
    let serverID: UUID
    let title: String
    let endpoint: String
}

struct TerminalBatchRequest: Equatable {
    let command: String
    let targets: [TerminalBatchTarget]
    var payload: String { command + "\r" }
    var isValid: Bool {
        !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && command.utf8.count <= 65536 &&
        !command.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" } &&
        !targets.isEmpty && Set(targets.map(\.id)).count == targets.count
    }
}

struct TerminalBatchExecutionSheet: View {
    @ObservedObject var registry: TerminalSessionRegistry
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hideIPInformation") private var privacy = false
    @State private var selected = Set<UUID>()
    @State private var command = ""
    @State private var pending: TerminalBatchRequest?
    @State private var result: String?
    private var targets: [TerminalBatchTarget] {
        registry.controllers.filter { $0.status == .connected }.map {
            TerminalBatchTarget(id: $0.id, serverID: $0.serverID, title: $0.serverName,
                                endpoint: "\($0.config.username)@\($0.config.host):\($0.config.port)")
        }
    }
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("选择已连接的 SSH 面板").font(.headline)
                if let pending {
                    Text("确认向以下 \(pending.targets.count) 个面板发送命令：").font(.callout)
                    targetList(pending.targets, editable: false)
                    ScrollView { Text(pending.command).font(.body.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .padding(12).frame(height: 160).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    Text("命令会提交到各终端当前程序。请确认目标均处于 Shell 提示符。断开的目标会跳过。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("返回编辑") { self.pending = nil }
                        Spacer()
                        Button("确认执行") { execute(pending) }.buttonStyle(.borderedProminent)
                    }
                } else {
                    targetList(targets, editable: true)
                    TextEditor(text: $command).font(.body.monospaced()).frame(height: 130)
                        .overlay { RoundedRectangle(cornerRadius: 6).stroke(.quaternary) }
                    if let result { Text(result).font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        Text("已选 \(selected.intersection(Set(targets.map(\.id))).count) 个面板").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("预览执行…") {
                            let request = TerminalBatchRequest(command: command, targets: targets.filter { selected.contains($0.id) })
                            if request.isValid { pending = request }
                        }.buttonStyle(.borderedProminent)
                            .disabled(!TerminalBatchRequest(command: command, targets: targets.filter { selected.contains($0.id) }).isValid)
                    }
                }
            }.padding(20)
                .navigationTitle("批量执行命令")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }.frame(width: 620, height: 590)
    }
    private func targetList(_ entries: [TerminalBatchTarget], editable: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if entries.isEmpty { Text("没有已连接的 SSH 面板").foregroundStyle(.secondary) }
                ForEach(entries) { target in
                    HStack {
                        if editable { Toggle("选择 \(target.title)", isOn: Binding(get: { selected.contains(target.id) }, set: { if $0 { selected.insert(target.id) } else { selected.remove(target.id) } })).labelsHidden() }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(target.title).font(.callout.bold())
                            Text("\(privacy ? "[连接地址]" : target.endpoint) · 面板 \(target.id.uuidString.prefix(6))").font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(height: 170)
    }
    private func execute(_ request: TerminalBatchRequest) {
        guard request.isValid else { return }
        // Capture concrete controllers before sending. No lookup of active pane or current selection is used.
        let recipients = request.targets.compactMap { target -> TerminalSessionController? in
            guard let controller = registry.controller(for: target.id), controller.serverID == target.serverID,
                  controller.status == .connected,
                  "\(controller.config.username)@\(controller.config.host):\(controller.config.port)" == target.endpoint else { return nil }
            return controller
        }
        for controller in recipients { controller.hostView.sendCommand(request.payload) }
        result = "已发送至 \(recipients.count) 个面板；跳过 \(request.targets.count - recipients.count) 个已关闭或断开的面板。"
        pending = nil
    }
}

struct TerminalTunnelManagerView: View {
    let server: ServerRecord
    @EnvironmentObject private var appState: AppState
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \PortForwardRuleRecord.createdAt) private var records: [PortForwardRuleRecord]
    @State private var name = ""
    @State private var direction: PortForwardDirection = .local
    @State private var bindAddress = "127.0.0.1"
    @State private var listenPort = 8080
    @State private var targetHost = "localhost"
    @State private var targetPort = 3306
    @State private var operationError: String?
    @State private var pendingRule: PortForwardRule?
    @State private var busy = false
    private var rules: [PortForwardRuleRecord] { records.filter { $0.serverID == server.id } }
    var body: some View {
        NavigationStack {
            Form {
                Section("创建隧道 · \(server.displayName)") {
                    Picker("类型", selection: $direction) {
                        ForEach(PortForwardDirection.allCases, id: \.self) { item in Text(item.title).tag(item) }
                    }.pickerStyle(.segmented)
                    TextField("名称（可选）", text: $name)
                    HStack { TextField("监听地址", text: $bindAddress); TextField("监听端口", value: $listenPort, format: .number.grouping(.never)).frame(width: 120) }
                    if direction == .local || direction == .remote {
                        HStack { TextField("目标主机", text: $targetHost); TextField("目标端口", value: $targetPort, format: .number.grouping(.never)).frame(width: 120) }
                    }
                    Text("默认监听 127.0.0.1。隧道由应用持有，关闭此窗口后继续运行。").font(.caption).foregroundStyle(.secondary)
                    Button("创建并启动") {
                        let rule = PortForwardRule(name: name.isEmpty ? "\(direction.title) :\(listenPort)" : name,
                            serverID: server.id, direction: direction, bindAddress: bindAddress,
                            listenPort: listenPort, targetHost: targetHost, targetPort: targetPort)
                        requestStart(rule)
                    }.disabled(busy).buttonStyle(.borderedProminent)
                }
                if let operationError { Section { Label(operationError, systemImage: "exclamationmark.triangle").foregroundStyle(.red) } }
                Section("已保存的隧道") {
                    if rules.isEmpty { Text("尚无隧道").foregroundStyle(.secondary) }
                    ForEach(rules) { record in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.name).font(.headline)
                                Text("\(record.rule.direction.title) · \(record.bindAddress):\(record.listenPort)").font(.caption.monospaced()).foregroundStyle(.secondary)
                                if let error = appState.portForwardSnapshots[record.id]?.lastError { Text(error).font(.caption).foregroundStyle(.red) }
                            }
                            Spacer()
                            let state = appState.portForwardSnapshots[record.id]?.state
                            if state == .ready || state == .starting || state == .reconnecting {
                                Button("停止") { Task { do { try await appState.stopPortForward(ruleID: record.id, serverID: server.id) } catch { operationError = error.localizedDescription } } }
                            } else { Button("启动") { requestStart(record.rule) }.disabled(busy) }
                        }
                    }
                }
            }.formStyle(.grouped).navigationTitle("SSH 隧道管理")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.frame(width: 650, height: 580)
            .task {
                while !Task.isCancelled {
                    await appState.refreshPortForwardSnapshots()
                    do { try await Task.sleep(for: .seconds(2)) } catch { break }
                }
            }
            .confirmationDialog("确认开放隧道监听？", isPresented: Binding(get: { pendingRule != nil }, set: { if !$0 { pendingRule = nil } })) {
                Button("确认并启动") { if let rule = pendingRule { start(rule, confirmed: true) }; pendingRule = nil }
                Button("取消", role: .cancel) { pendingRule = nil }
            } message: { Text("\(pendingRule?.direction.title ?? "") · \(pendingRule?.bindAddress ?? ""):\(pendingRule?.listenPort ?? 0)\n远端或广域监听可能允许其他设备使用此隧道。") }
    }
    private func requestStart(_ rule: PortForwardRule) {
        if rule.direction == .remote || rule.isWildcardExposure { pendingRule = rule } else { start(rule, confirmed: false) }
    }
    private func start(_ rule: PortForwardRule, confirmed: Bool) {
        busy = true; operationError = nil
        Task {
            defer { busy = false }
            do {
                try rule.validate(exposureConfirmed: confirmed, remoteForwardConfirmed: confirmed)
                if !rules.contains(where: { $0.id == rule.id }) {
                    context.insert(PortForwardRuleRecord(rule: rule)); try context.save()
                }
                try await appState.startPortForward(rule: rule, server: server, exposureConfirmed: confirmed, remoteForwardConfirmed: confirmed)
            } catch { operationError = error.localizedDescription }
        }
    }
}

struct TerminalWindowWidthReader: NSViewRepresentable {
    let update: (CGFloat) -> Void
    func makeNSView(context: Context) -> WidthView { WidthView(update: update) }
    func updateNSView(_ view: WidthView, context: Context) { view.update = update }
    final class WidthView: NSView {
        var update: (CGFloat) -> Void
        private var observer: NSObjectProtocol?
        init(update: @escaping (CGFloat) -> Void) { self.update = update; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            guard let window else { return }
            publish(window)
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self, weak window] _ in
                if let self, let window { self.publish(window) }
            }
        }
        private func publish(_ window: NSWindow) { let width = window.contentLayoutRect.width; DispatchQueue.main.async { [weak self] in self?.update(width) } }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}
