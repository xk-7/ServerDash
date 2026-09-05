import AppKit
import SwiftData
import SwiftUI

struct ProfessionalConnectionsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appState: AppState
    @Query(sort: \ServerRecord.name) private var servers: [ServerRecord]
    @Query(sort: \ConnectionRouteRecord.updatedAt, order: .reverse)
    private var routeRecords: [ConnectionRouteRecord]
    @Query(sort: \PortForwardRuleRecord.updatedAt, order: .reverse)
    private var ruleRecords: [PortForwardRuleRecord]

    @State private var configURL: URL?
    @State private var alias = ""
    @State private var selectedServerID: UUID?
    @State private var importResult: SSHConfigRouteImport?
    @State private var importError: String?
    @State private var approveProxyCommand = false
    @State private var proxyKind: NetworkProxyKind = .socks5
    @State private var proxyHost = ""
    @State private var proxyPort = 1_080
    @State private var proxyUsername = ""
    @State private var proxySecret = ""
    @State private var proxyError: String?

    @State private var ruleName = ""
    @State private var direction: PortForwardDirection = .local
    @State private var bindAddress = "127.0.0.1"
    @State private var listenPort = 8_080
    @State private var targetHost = "127.0.0.1"
    @State private var targetPort = 80
    @State private var operationError: String?
    @State private var pendingUnsafeRule: PortForwardRuleRecord?

    private var defaultConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppleDesign.Spacing.lg) {
                header
                importCard
                proxyCard
                routeCard
                tunnelRuleCard
            }
            .padding(AppleDesign.Spacing.lg)
            .frame(maxWidth: AppleDesign.Layout.readingWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task {
            if configURL == nil,
               FileManager.default.isReadableFile(atPath: defaultConfigURL.path) {
                configURL = defaultConfigURL
            }
            if selectedServerID == nil { selectedServerID = servers.first?.id }
            while !Task.isCancelled {
                await appState.refreshPortForwardSnapshots()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .alert(
            pendingUnsafeRule?.rule.direction == .remote
                ? "确认远端监听"
                : "确认广域监听",
            isPresented: Binding(
                get: { pendingUnsafeRule != nil },
                set: { if !$0 { pendingUnsafeRule = nil } }
            )
        ) {
            Button("取消", role: .cancel) { pendingUnsafeRule = nil }
            Button("确认并启动", role: .destructive) {
                guard let record = pendingUnsafeRule else { return }
                pendingUnsafeRule = nil
                start(
                    record,
                    exposureConfirmed: record.rule.isWildcardExposure,
                    remoteForwardConfirmed: record.rule.direction == .remote
                )
            }
        } message: {
            if let rule = pendingUnsafeRule?.rule, rule.direction == .remote {
                Text("Remote Forward 会在远端服务器建立监听端口。请核验监听地址、远端防火墙、目标服务认证和实际暴露范围。")
            } else {
                Text("监听 0.0.0.0 或 :: 会让局域网或更广网络访问该端口。请确认防火墙、目标服务认证和实际暴露范围。")
            }
        }
    }

    private var header: some View {
        AppleWorkspaceHeader(
            title: "连接与隧道", subtitle: "配置跳板、网络代理和端口转发。",
            symbol: "point.3.connected.trianglepath.dotted"
        ) { EmptyView() }
    }

    private var importCard: some View {
        MonitorSectionPanel(title: "SSH Config 导入") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(configURL?.path ?? "尚未选择文件")
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    Button("选择文件") { chooseConfig() }
                }
                HStack {
                    TextField("Host 别名", text: $alias)
                        .textFieldStyle(.roundedBorder)
                    Picker("绑定服务器", selection: $selectedServerID) {
                        Text("选择服务器").tag(Optional<UUID>.none)
                        ForEach(servers) { server in
                            Text(server.displayName).tag(Optional(server.id))
                        }
                    }
                    .frame(width: 220)
                    Button("解析") { parseConfig() }
                        .disabled(alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || configURL == nil)
                }

                if let importError {
                    Label(importError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.appError)
                        .font(.callout)
                }

                if let importResult {
                    importReport(importResult)
                    if importResult.route.importedProxyCommand != nil {
                        Toggle("我已核验导入的 ProxyCommand，允许它作为本机命令执行", isOn: $approveProxyCommand)
                            .toggleStyle(.checkbox)
                        Text("未确认时路线可以保存，但任何连接都会被阻止。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Spacer()
                        Button("保存路线") { saveImportedRoute(importResult) }
                            .buttonStyle(.borderedProminent)
                            .disabled(selectedServerID == nil)
                    }
                }
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private func importReport(_ result: SSHConfigRouteImport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("最终解析值")
                .font(.headline)
            ForEach(Array(result.reports.enumerated()), id: \.offset) { _, report in
                VStack(alignment: .leading, spacing: 5) {
                    Text(report.alias)
                        .font(.subheadline.weight(.semibold))
                    ForEach(report.values) { value in
                        HStack(alignment: .firstTextBaseline) {
                            Text(value.field.title)
                                .frame(width: 140, alignment: .leading)
                            Text(value.value)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer()
                            Text(value.source.display)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    if !report.matches.isEmpty {
                        Text("匹配顺序：" + report.matches.map { $0.patterns.joined(separator: " ") }.joined(separator: " → "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            let unsupported = result.reports.flatMap(\.unsupported)
            if !unsupported.isEmpty {
                Text("不支持项（\(DisplayFormat.integer(unsupported.count))）")
                    .font(.headline)
                ForEach(unsupported) { item in
                    Label(
                        "\(item.name) · \(item.source.display) · \(item.reason)",
                        systemImage: "questionmark.diamond"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            let issues = result.reports.flatMap(\.issues)
            ForEach(issues) { issue in
                Label(issue.message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Color.appWarning)
            }
        }
    }

    private var routeCard: some View {
        MonitorSectionPanel(title: "已保存路线") {
            VStack(alignment: .leading, spacing: 10) {
                if routeRecords.isEmpty {
                    Text("尚未保存专业连接路线。未绑定路线的服务器继续使用严格校验的直接连接。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(routeRecords) { record in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(record.name).font(.headline)
                                Text(routeSummary(record))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("revision \(record.revision.uuidString)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            if let server = servers.first(where: { $0.id == record.serverID }) {
                                Text(server.displayName)
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.secondary.opacity(0.12), in: Capsule())
                            }
                        }
                        if record.id != routeRecords.last?.id { Divider() }
                    }
                }
            }
            .padding(8)
        }
    }

    private var proxyCard: some View {
        MonitorSectionPanel(title: "SOCKS5 / HTTP CONNECT 代理") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("代理类型", selection: $proxyKind) {
                        Text("SOCKS5").tag(NetworkProxyKind.socks5)
                        Text("HTTP CONNECT").tag(NetworkProxyKind.httpConnect)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Picker("绑定服务器", selection: $selectedServerID) {
                        Text("选择服务器").tag(Optional<UUID>.none)
                        ForEach(servers) { server in
                            Text(server.displayName).tag(Optional(server.id))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                HStack(alignment: .top, spacing: AppleDesign.Spacing.md) {
                    VStack(alignment: .leading, spacing: AppleDesign.Spacing.xxs) {
                        Text("代理主机").font(.caption).foregroundStyle(.secondary)
                        TextField("proxy.example.com", text: $proxyHost)
                            .accessibilityLabel("代理主机")
                    }
                    VStack(alignment: .leading, spacing: AppleDesign.Spacing.xxs) {
                        Text("端口").font(.caption).foregroundStyle(.secondary)
                        TextField("端口", value: $proxyPort, format: .number.grouping(.never))
                    }
                    .frame(width: 100)
                }
                HStack {
                    TextField("代理用户名（可选）", text: $proxyUsername)
                    SecureField("代理密码（可选）", text: $proxySecret)
                }
                HStack(alignment: .top, spacing: AppleDesign.Spacing.md) {
                    Text("需要认证时，请同时填写用户名和密码。密码安全保存在 macOS 钥匙串中。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("保存代理路线") { saveProxyRoute() }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            selectedServerID == nil ||
                                proxyHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                }
                if let proxyError {
                    Label(proxyError, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(Color.appError)
                }
            }
            .textFieldStyle(.roundedBorder)
            .padding(8)
        }
    }

    private var tunnelRuleCard: some View {
        MonitorSectionPanel(title: "端口转发") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    TextField("规则名称", text: $ruleName)
                    Picker("服务器", selection: $selectedServerID) {
                        Text("选择服务器").tag(Optional<UUID>.none)
                        ForEach(servers) { server in
                            Text(server.displayName).tag(Optional(server.id))
                        }
                    }
                    Picker("类型", selection: $direction) {
                        ForEach(PortForwardDirection.allCases, id: \.self) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .frame(width: 155)
                }
                HStack(alignment: .top, spacing: AppleDesign.Spacing.md) {
                    VStack(alignment: .leading, spacing: AppleDesign.Spacing.xxs) {
                        Text("监听地址").font(.caption).foregroundStyle(.secondary)
                        TextField("监听地址", text: $bindAddress)
                    }
                    VStack(alignment: .leading, spacing: AppleDesign.Spacing.xxs) {
                        Text("监听端口").font(.caption).foregroundStyle(.secondary)
                        TextField("监听端口", value: $listenPort, format: .number.grouping(.never))
                    }
                    .frame(width: 100)
                }
                if direction != .dynamic {
                    HStack(alignment: .top, spacing: AppleDesign.Spacing.md) {
                        VStack(alignment: .leading, spacing: AppleDesign.Spacing.xxs) {
                            Text("目标主机").font(.caption).foregroundStyle(.secondary)
                            TextField("目标主机", text: $targetHost)
                        }
                        VStack(alignment: .leading, spacing: AppleDesign.Spacing.xxs) {
                            Text("目标端口").font(.caption).foregroundStyle(.secondary)
                            TextField("目标端口", value: $targetPort, format: .number.grouping(.never))
                        }
                        .frame(width: 100)
                    }
                }
                HStack {
                    Spacer()
                    Button("添加规则") { addRule() }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedServerID == nil)
                }
                Text("默认仅允许本机访问。远端或广域监听需要在启动前确认。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let operationError {
                    Label(operationError, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(Color.appError)
                }

                if ruleRecords.isEmpty {
                    Text("尚无隧道规则。")
                        .foregroundStyle(.secondary)
                } else {
                    Divider()
                    ForEach(ruleRecords) { record in
                        tunnelRow(record)
                        if record.id != ruleRecords.last?.id { Divider() }
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            .padding(8)
        }
    }

    private func tunnelRow(_ record: PortForwardRuleRecord) -> some View {
        let rule = record.rule
        let snapshot = appState.portForwardSnapshots[record.id]
        return HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(record.name).font(.headline)
                    Text(snapshot?.state.rawValue ?? "stopped")
                        .font(.caption.monospaced())
                        .foregroundStyle(snapshot?.state == .ready ? Color.appLive : .secondary)
                }
                Text(tunnelSummary(rule))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                if let error = snapshot?.lastError, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Color.appError)
                } else if snapshot?.state == .ready {
                    Text("连接数与流量：当前 OpenSSH CLI Provider 不提供可靠统计")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if snapshot?.state == .ready || snapshot?.state == .reconnecting || snapshot?.state == .starting {
                Button("停止") { stop(record) }
            } else {
                Button("启动") {
                    if rule.isWildcardExposure || rule.direction == .remote {
                        pendingUnsafeRule = record
                    } else {
                        start(
                            record,
                            exposureConfirmed: false,
                            remoteForwardConfirmed: false
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func chooseConfig() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择 SSH Config"
        if panel.runModal() == .OK {
            configURL = panel.url
            importResult = nil
            importError = nil
        }
    }

    private func parseConfig() {
        guard let configURL else { return }
        do {
            importResult = try SSHConfigImporter().importRoute(alias: alias, from: configURL)
            importError = nil
            approveProxyCommand = false
        } catch {
            importResult = nil
            importError = error.localizedDescription
        }
    }

    private func saveImportedRoute(_ result: SSHConfigRouteImport) {
        guard let selectedServerID else { return }
        let oldProxySecretAccount = routeRecords
            .first(where: { $0.serverID == selectedServerID })?
            .route?
            .proxy?
            .secretAccount
        do {
            var route = result.route
            route.importedProxyCommandConfirmed = approveProxyCommand
            if let existing = routeRecords.first(where: { $0.serverID == selectedServerID }) {
                route.id = existing.id
                route.revision = UUID()
                let data = try JSONEncoder().encode(route)
                existing.name = route.name
                existing.revision = route.revision
                existing.routeJSON = String(decoding: data, as: UTF8.self)
                existing.sourceAlias = alias
                existing.sourcePathHint = configURL?.lastPathComponent ?? "config"
                existing.updatedAt = .now
            } else {
                modelContext.insert(
                    try ConnectionRouteRecord(
                        route: route,
                        serverID: selectedServerID,
                        sourceAlias: alias,
                        sourcePathHint: configURL?.lastPathComponent ?? "config"
                    )
                )
            }
            try modelContext.save()
            if let oldProxySecretAccount,
               oldProxySecretAccount != route.proxy?.secretAccount {
                try? KeychainService.deleteSecret(account: oldProxySecretAccount)
            }
            importError = nil
        } catch {
            importError = error.localizedDescription
        }
    }

    private func saveProxyRoute() {
        guard let selectedServerID else { return }
        let existing = routeRecords.first(where: { $0.serverID == selectedServerID })
        let routeID = existing?.id ?? UUID()
        let username = proxyUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = proxySecret
        guard username.isEmpty == secret.isEmpty else {
            proxyError = "代理用户名与 Secret 必须同时填写或同时留空。"
            return
        }
        let revision = UUID()
        let account = secret.isEmpty
            ? nil
            : KeychainService.proxyAccount(for: routeID, revision: revision)
        let oldAccount = existing?.route?.proxy?.secretAccount
        let previousRecord = existing.map {
            (
                name: $0.name,
                revision: $0.revision,
                routeJSON: $0.routeJSON,
                sourceAlias: $0.sourceAlias,
                sourcePathHint: $0.sourcePathHint,
                updatedAt: $0.updatedAt
            )
        }
        var insertedRecord: ConnectionRouteRecord?
        do {
            if let account { try KeychainService.saveSecret(secret, account: account) }
            let route = ConnectionRoute(
                id: routeID,
                revision: revision,
                name: "\(proxyKind == .socks5 ? "SOCKS5" : "HTTP CONNECT") · \(proxyHost)",
                proxy: NetworkProxy(
                    kind: proxyKind,
                    host: proxyHost,
                    port: proxyPort,
                    username: username.isEmpty ? nil : username,
                    secretAccount: account
                )
            )
            let server = try RouteEndpointLookup.server(selectedServerID, in: servers)
            _ = try route.validated(
                finalEndpoint: ConnectionEndpoint(
                    host: server.host,
                    port: server.port,
                    username: server.username
                )
            )
            if let existing {
                let data = try JSONEncoder().encode(route)
                existing.name = route.name
                existing.revision = route.revision
                existing.routeJSON = String(decoding: data, as: UTF8.self)
                existing.sourceAlias = ""
                existing.sourcePathHint = ""
                existing.updatedAt = .now
            } else {
                let record = try ConnectionRouteRecord(route: route, serverID: selectedServerID)
                insertedRecord = record
                modelContext.insert(record)
            }
            try modelContext.save()
            if let oldAccount, oldAccount != account {
                try? KeychainService.deleteSecret(account: oldAccount)
            }
            proxySecret = ""
            proxyError = nil
        } catch {
            if let account { try? KeychainService.deleteSecret(account: account) }
            if let existing, let previousRecord {
                existing.name = previousRecord.name
                existing.revision = previousRecord.revision
                existing.routeJSON = previousRecord.routeJSON
                existing.sourceAlias = previousRecord.sourceAlias
                existing.sourcePathHint = previousRecord.sourcePathHint
                existing.updatedAt = previousRecord.updatedAt
            }
            if let insertedRecord { modelContext.delete(insertedRecord) }
            proxyError = error.localizedDescription
        }
    }

    private func addRule() {
        guard let selectedServerID else { return }
        let name = ruleName.trimmingCharacters(in: .whitespacesAndNewlines)
        let rule = PortForwardRule(
            name: name.isEmpty ? "\(direction.title) \(listenPort)" : name,
            serverID: selectedServerID,
            direction: direction,
            bindAddress: bindAddress,
            listenPort: listenPort,
            targetHost: targetHost,
            targetPort: targetPort
        )
        do {
            try rule.validate(
                exposureConfirmed: rule.isWildcardExposure,
                remoteForwardConfirmed: rule.direction == .remote
            )
            modelContext.insert(PortForwardRuleRecord(rule: rule))
            try modelContext.save()
            ruleName = ""
            operationError = nil
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func start(
        _ record: PortForwardRuleRecord,
        exposureConfirmed: Bool,
        remoteForwardConfirmed: Bool
    ) {
        guard let server = servers.first(where: { $0.id == record.serverID }) else {
            operationError = "规则引用的服务器已不存在。"
            return
        }
        Task {
            do {
                try await appState.startPortForward(
                    rule: record.rule,
                    server: server,
                    exposureConfirmed: exposureConfirmed,
                    remoteForwardConfirmed: remoteForwardConfirmed
                )
                operationError = nil
            } catch {
                operationError = error.localizedDescription
            }
        }
    }

    private func stop(_ record: PortForwardRuleRecord) {
        Task {
            do {
                try await appState.stopPortForward(
                    ruleID: record.id,
                    serverID: record.serverID
                )
                operationError = nil
            } catch {
                operationError = error.localizedDescription
            }
        }
    }

    private func routeSummary(_ record: ConnectionRouteRecord) -> String {
        guard let route = record.route else { return "路线数据损坏，已阻止使用" }
        var parts = ["\(DisplayFormat.integer(route.hops.count)) 跳"]
        if let proxy = route.proxy { parts.append(proxy.kind.rawValue) }
        if route.importedProxyCommand != nil {
            parts.append(route.importedProxyCommandConfirmed ? "ProxyCommand 已确认" : "ProxyCommand 待确认")
        }
        return parts.joined(separator: " · ")
    }

    private func tunnelSummary(_ rule: PortForwardRule) -> String {
        switch rule.direction {
        case .dynamic:
            return "SOCKS \(rule.bindAddress):\(rule.listenPort)"
        case .local, .remote:
            return "\(rule.direction.title) \(rule.bindAddress):\(rule.listenPort) → \(rule.targetHost):\(rule.targetPort)"
        }
    }
}

private enum RouteEndpointLookup {
    static func server(_ id: UUID, in servers: [ServerRecord]) throws -> ServerRecord {
        guard let server = servers.first(where: { $0.id == id }) else {
            throw ConnectionRouteError.invalidEndpoint("代理服务器引用")
        }
        return server
    }
}
