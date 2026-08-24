import Foundation
import SwiftData

enum DetailMode: String, CaseIterable, Identifiable {
    case monitor
    case terminal
    case sftp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .monitor: "监控"
        case .terminal: "终端"
        case .sftp: "SFTP"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var selectedServerID: UUID?
    @Published var detailMode: DetailMode = .monitor
    @Published private(set) var statuses: [UUID: ServerConnectionStatus] = [:]
    @Published private(set) var snapshots: [UUID: ServerSnapshot] = [:]
    @Published private(set) var histories: [UUID: [MetricPoint]] = [:]
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private(set) var diagnostics: [UUID: String] = [:]
    @Published private(set) var capabilities: [UUID: ServerCapabilities] = [:]
    @Published private(set) var configs: [UUID: ServerConnectionConfig] = [:]
    @Published private(set) var refreshingServerIDs: Set<UUID> = []
    @Published var selectedTerminalID: UUID?
    @Published var pendingTrust: HostTrustPrompt?
    @Published var refreshInterval: TimeInterval {
        didSet {
            UserDefaults.standard.set(refreshInterval, forKey: "refreshInterval")
            restartAutoRefresh()
        }
    }

    let terminalRegistry = TerminalSessionRegistry()
    let eventLog = EventLogStore.shared

    var terminalSessions: [TerminalSession] {
        terminalRegistry.sessions
    }

    private var selectedConfig: ServerConnectionConfig?
    private var selectedMonitorEnabled = true
    private var autoRefreshTask: Task<Void, Never>?

    init() {
        let savedInterval = UserDefaults.standard.double(forKey: "refreshInterval")
        refreshInterval = savedInterval == 0 && !UserDefaults.standard.bool(forKey: "refreshIntervalConfigured")
            ? 5
            : savedInterval
    }

    deinit {
        autoRefreshTask?.cancel()
    }

    func bootstrap(servers: [ServerRecord], context: ModelContext) {
        for server in servers where snapshots[server.id] == nil {
            initializeRuntime(for: server)
        }
    }

    func initializeRuntime(for server: ServerRecord) {
        configs[server.id] = configs[server.id] ?? server.connectionConfig
        snapshots[server.id] = snapshots[server.id] ?? .empty
        statuses[server.id] = statuses[server.id] ?? .unknown
        histories[server.id] = histories[server.id] ?? []
        errors[server.id] = errors[server.id]
        if capabilities[server.id] == nil,
           let data = server.capabilitiesJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(ServerCapabilities.self, from: data) {
            capabilities[server.id] = decoded
        }
    }

    func cacheConfig(_ config: ServerConnectionConfig) {
        configs[config.id] = config
    }

    func applyResolvedConfigs(_ resolved: [UUID: ServerConnectionConfig]) {
        configs.merge(resolved) { _, new in new }
        if let selectedServerID, let config = resolved[selectedServerID] {
            selectedConfig = config
        }
    }

    func connectionConfig(for server: ServerRecord) -> ServerConnectionConfig {
        configs[server.id] ?? server.connectionConfig
    }

    func select(_ server: ServerRecord?) {
        selectedServerID = server?.id
        selectedMonitorEnabled = server?.enableDashboardMonitor ?? false
        selectedConfig = server.flatMap { configs[$0.id] } ?? server?.connectionConfig
        if let server {
            configs[server.id] = selectedConfig ?? server.connectionConfig
        }
        if server != nil {
            detailMode = .monitor
        }
        restartAutoRefresh()
    }

    func status(for server: ServerRecord) -> ServerConnectionStatus {
        statuses[server.id] ?? .unknown
    }

    func snapshot(for server: ServerRecord) -> ServerSnapshot {
        snapshots[server.id] ?? .empty
    }

    func history(for server: ServerRecord) -> [MetricPoint] {
        histories[server.id] ?? []
    }

    func isRefreshing(_ server: ServerRecord) -> Bool {
        refreshingServerIDs.contains(server.id)
    }

    func isStale(_ server: ServerRecord) -> Bool {
        guard let last = server.lastSuccessfulMonitorAt ?? (
            snapshots[server.id]?.capturedAt == .distantPast ? nil : snapshots[server.id]?.capturedAt
        ) else {
            return false
        }
        let limit = max(15, refreshInterval * 3)
        return Date().timeIntervalSince(last) > limit
    }

    func applyValidatedSnapshot(_ snapshot: ServerSnapshot, to server: ServerRecord) {
        snapshots[server.id] = snapshot
        histories[server.id] = []
        appendHistory(snapshot, for: server.id)
        statuses[server.id] = .online
        errors[server.id] = nil
        server.lastConnectedAt = snapshot.capturedAt
        server.lastSuccessfulMonitorAt = snapshot.capturedAt
        server.verificationStatus = .monitorReady
        if selectedServerID == server.id {
            selectedConfig = server.connectionConfig
            restartAutoRefresh()
        }
    }

    func refresh(_ server: ServerRecord) async {
        await collect(server)
    }

    func refreshAll(_ servers: [ServerRecord], failedOnly: Bool = false) async {
        let targets = servers.filter { server in
            server.enableDashboardMonitor &&
            !refreshingServerIDs.contains(server.id) &&
            (!failedOnly || statuses[server.id] == .failed)
        }
        guard !targets.isEmpty else { return }
        for start in stride(from: 0, to: targets.count, by: 3) {
            let chunk = Array(targets[start..<min(start + 3, targets.count)])
            await withTaskGroup(of: Void.self) { group in
                for server in chunk {
                    group.addTask { await self.collect(server) }
                }
            }
        }
    }

    func testSSH(_ server: ServerRecord) async {
        do {
            let config = connectionConfig(for: server)
            try await ensureTrusted(config)
            let elapsed = try await SSHConnectionTester.test(config)
            server.lastLatencyMS = elapsed * 1000
            server.lastConnectedAt = .now
            if server.verificationStatus == .unverified {
                server.verificationStatus = .sshReady
            }
            statuses[server.id] = statuses[server.id] == .online ? .online : .unknown
            errors[server.id] = nil
            eventLog.append(serverID: server.id, module: .ssh, message: "SSH 测试成功")
        } catch {
            applyFailure(error, to: server.id, remoteOS: snapshots[server.id]?.distribution)
        }
    }

    func probeMonitor(_ server: ServerRecord) async {
        do {
            let config = connectionConfig(for: server)
            try await ensureTrusted(config)
            let capabilities = try await SSHMonitoringService.probeCapabilities(config)
            self.capabilities[server.id] = capabilities
            if let data = try? JSONEncoder().encode(capabilities),
               let json = String(data: data, encoding: .utf8) {
                server.capabilitiesJSON = json
            }
            await collect(server)
            if statuses[server.id] == .online {
                server.verificationStatus = .monitorReady
            }
        } catch {
            if server.verificationStatus == .sshReady {
                server.verificationStatus = .monitorUnsupported
            }
            applyFailure(error, to: server.id, remoteOS: snapshots[server.id]?.distribution)
        }
    }

    func openTerminal(for server: ServerRecord) {
        let controller = terminalRegistry.open(
            for: server,
            forceNew: false,
            config: connectionConfig(for: server)
        )
        selectedTerminalID = controller.id
        selectedServerID = server.id
        selectedConfig = server.connectionConfig
        detailMode = .terminal
    }

    func newTerminal(for server: ServerRecord) {
        let controller = terminalRegistry.open(
            for: server,
            forceNew: true,
            config: connectionConfig(for: server)
        )
        selectedTerminalID = controller.id
        selectedServerID = server.id
        selectedConfig = server.connectionConfig
        detailMode = .terminal
    }

    func selectTerminal(_ session: TerminalSession) {
        selectedTerminalID = session.id
        selectedServerID = session.serverID
        selectedConfig = session.config
        detailMode = .terminal
    }

    func closeTerminal(_ session: TerminalSession, context: ModelContext? = nil) {
        terminalRegistry.close(session.id)
        if let context {
            context.insert(
                TerminalSessionHistory(
                    serverID: session.serverID,
                    serverName: session.serverName,
                    startedAt: session.createdAt,
                    endedAt: .now,
                    result: session.status == .failed ? "failed" : "closed"
                )
            )
            try? context.save()
        }
        if selectedTerminalID == session.id {
            selectedTerminalID = terminalSessions.last?.id
            if terminalSessions.isEmpty {
                detailMode = .monitor
            }
        }
    }

    func reconnectTerminal(_ session: TerminalSession) {
        terminalRegistry.controller(for: session.id)?.reconnect()
    }

    func removeRuntimeData(for serverID: UUID) {
        statuses[serverID] = nil
        snapshots[serverID] = nil
        histories[serverID] = nil
        errors[serverID] = nil
        diagnostics[serverID] = nil
        capabilities[serverID] = nil
        configs[serverID] = nil
        refreshingServerIDs.remove(serverID)
        terminalRegistry.closeAll(for: serverID)
        Task {
            await ConnectionProcessController.shared.terminateAll(for: serverID)
        }
        if selectedServerID == serverID {
            selectedServerID = nil
            selectedConfig = nil
            detailMode = .monitor
        }
    }

    func shutdown() {
        autoRefreshTask?.cancel()
        terminalRegistry.terminateAll()
        KeyMaterialStore.cleanupAll()
        Task {
            await ConnectionProcessController.shared.terminateAll()
        }
    }

    func updateRefreshInterval(_ interval: TimeInterval) {
        UserDefaults.standard.set(true, forKey: "refreshIntervalConfigured")
        refreshInterval = interval
    }

    func resolveTrust(_ probe: SSHHostKeyProbe, replacing: Bool) async {
        do {
            try await SSHConnectionValidator.trust(probe, replacing: replacing)
            pendingTrust = nil
            eventLog.append(serverID: selectedServerID, module: .ssh, message: "已信任主机指纹")
            if let config = selectedConfig ?? configs.values.first(where: {
                $0.host == probe.host && $0.port == probe.port
            }) {
                errors[config.id] = nil
                statuses[config.id] = .connecting
                await refresh(config)
            }
        } catch {
            pendingTrust = nil
            if let selectedServerID {
                applyFailure(error, to: selectedServerID, remoteOS: nil)
            }
        }
    }

    private func restartAutoRefresh() {
        autoRefreshTask?.cancel()
        guard refreshInterval > 0, selectedMonitorEnabled, let config = selectedConfig else { return }
        let interval = refreshInterval
        let serverID = config.id
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                await self.refresh(config)
            }
        }
        _ = serverID
    }

    private func refresh(_ config: ServerConnectionConfig) async {
        guard !refreshingServerIDs.contains(config.id) else { return }
        refreshingServerIDs.insert(config.id)
        defer { refreshingServerIDs.remove(config.id) }
        do {
            try await ensureTrusted(config)
            var snapshot = try await SSHMonitoringService.collect(config)
            if PrivacySettings.disableLocationLookup {
                snapshot.geoLocation = nil
            }
            applyDerivedMetrics(
                to: &snapshot,
                previous: snapshots[config.id],
                serverID: config.id
            )
            snapshots[config.id] = snapshot
            appendHistory(snapshot, for: config.id)
            statuses[config.id] = .online
            errors[config.id] = nil
        } catch {
            applyFailure(error, to: config.id, remoteOS: snapshots[config.id]?.distribution)
        }
    }

    private func collect(_ server: ServerRecord) async {
        guard server.enableDashboardMonitor else { return }
        guard !refreshingServerIDs.contains(server.id) else { return }
        refreshingServerIDs.insert(server.id)
        defer { refreshingServerIDs.remove(server.id) }
        if statuses[server.id] == nil || statuses[server.id] == .unknown {
            statuses[server.id] = .connecting
        }
        do {
            let config = connectionConfig(for: server)
            try await ensureTrusted(config)
            let started = Date()
            var snapshot = try await SSHMonitoringService.collect(config)
            if PrivacySettings.disableLocationLookup {
                snapshot.geoLocation = nil
            }
            let elapsed = Date().timeIntervalSince(started)
            applyDerivedMetrics(
                to: &snapshot,
                previous: snapshots[server.id],
                serverID: server.id
            )
            snapshots[server.id] = snapshot
            appendHistory(snapshot, for: server.id)
            statuses[server.id] = .online
            errors[server.id] = nil
            diagnostics[server.id] = nil
            server.lastConnectedAt = .now
            server.lastSuccessfulMonitorAt = snapshot.capturedAt
            server.lastLatencyMS = elapsed * 1000
            eventLog.append(serverID: server.id, module: .monitoring, message: "监控采集成功")
        } catch {
            applyFailure(error, to: server.id, remoteOS: snapshots[server.id]?.distribution)
        }
    }

    private func ensureTrusted(_ config: ServerConnectionConfig) async throws {
        switch try await SSHConnectionValidator.inspect(config) {
        case .trusted(let probe):
            if !TrustedHostStore.hasUsableHostName(host: config.host, port: config.port) {
                try await SSHConnectionValidator.trust(probe)
            }
            return
        case .unknown(let probe):
            pendingTrust = HostTrustPrompt(probe: probe, replacing: false)
            throw ConnectionError.hostKeyUntrusted
        case .changed(let oldFingerprint, let probe):
            pendingTrust = HostTrustPrompt(
                probe: probe,
                replacing: true,
                oldFingerprint: oldFingerprint
            )
            throw ConnectionError.hostKeyChanged(
                oldFingerprint: oldFingerprint,
                newFingerprint: probe.fingerprint
            )
        }
    }

    private func applyFailure(_ error: Error, to serverID: UUID, remoteOS: String?) {
        let waitingForTrust: Bool = {
            switch error as? ConnectionError {
            case .hostKeyUntrusted, .hostKeyChanged:
                return true
            default:
                return false
            }
        }()
        statuses[serverID] = waitingForTrust ? .unknown : .failed
        errors[serverID] = waitingForTrust
            ? (error as? ConnectionError == .hostKeyUntrusted
                ? "请先确认主机指纹。"
                : error.localizedDescription)
            : error.localizedDescription
        let config = configs[serverID] ?? ServerConnectionConfig(
            id: serverID,
            credentialID: serverID,
            name: "",
            host: "",
            port: 22,
            username: "",
            authentication: .privateKey,
            privateKeyPath: ""
        )
        diagnostics[serverID] = SSHDiagnostics.report(
            config: config,
            error: error,
            remoteOS: remoteOS
        )
        eventLog.append(
            serverID: serverID,
            module: .ssh,
            level: "error",
            message: error.localizedDescription
        )
        if pendingTrust == nil, !config.host.isEmpty {
            switch error as? ConnectionError ?? ConnectionError.classify(error.localizedDescription) {
            case .hostKeyChanged, .hostKeyUntrusted:
                Task { await presentTrustPrompt(for: config) }
            default:
                break
            }
        }
    }

    private func presentTrustPrompt(for config: ServerConnectionConfig) async {
        do {
            switch try await SSHConnectionValidator.inspect(config) {
            case .trusted:
                return
            case .unknown(let probe):
                pendingTrust = HostTrustPrompt(probe: probe, replacing: false)
            case .changed(let oldFingerprint, let probe):
                pendingTrust = HostTrustPrompt(
                    probe: probe,
                    replacing: true,
                    oldFingerprint: oldFingerprint
                )
            }
        } catch {
            if let old = TrustedHostStore.existingFingerprint(host: config.host, port: config.port),
               let probe = try? TrustedHostStore.scan(host: config.host, port: config.port) {
                pendingTrust = HostTrustPrompt(
                    probe: probe,
                    replacing: true,
                    oldFingerprint: old
                )
            }
        }
    }

    private func appendHistory(_ snapshot: ServerSnapshot, for id: UUID) {
        var points = histories[id] ?? []
        points.append(
            MetricPoint(
                date: snapshot.capturedAt,
                cpu: snapshot.cpuUsage,
                memory: snapshot.memoryUsage,
                download: snapshot.downloadBytesPerSecond,
                upload: snapshot.uploadBytesPerSecond,
                load1: snapshot.load1,
                load5: snapshot.load5,
                load15: snapshot.load15,
                swapUsage: snapshot.swapUsage
            )
        )
        histories[id] = Array(points.suffix(120))
    }

    private func applyDerivedMetrics(
        to snapshot: inout ServerSnapshot,
        previous: ServerSnapshot?,
        serverID: UUID
    ) {
        guard let previous, previous.capturedAt != .distantPast else { return }
        let elapsed = max(0.1, snapshot.capturedAt.timeIntervalSince(previous.capturedAt))
        snapshot.networkInterfaces = snapshot.networkInterfaces.map { current in
            var updated = current
            if let prior = previous.networkInterfaces.first(where: { $0.name == current.name }) {
                updated.downloadBytesPerSecond = max(
                    0,
                    (current.receivedBytes - prior.receivedBytes) / elapsed
                )
                updated.uploadBytesPerSecond = max(
                    0,
                    (current.sentBytes - prior.sentBytes) / elapsed
                )
            }
            return updated
        }

        let pinnedName = UserDefaults.standard.string(
            forKey: "defaultNetworkInterface.\(serverID.uuidString)"
        )
        let selectedInterface = snapshot.networkInterfaces.first {
            $0.name == pinnedName
        } ?? snapshot.networkInterfaces.first {
            $0.name == snapshot.activeNetworkInterface
        } ?? snapshot.networkInterfaces.max {
            ($0.receivedBytes + $0.sentBytes) < ($1.receivedBytes + $1.sentBytes)
        }

        if let selectedInterface {
            snapshot.activeNetworkInterface = selectedInterface.name
            snapshot.networkReceivedBytes = selectedInterface.receivedBytes
            snapshot.networkSentBytes = selectedInterface.sentBytes
            snapshot.downloadBytesPerSecond = selectedInterface.downloadBytesPerSecond
            snapshot.uploadBytesPerSecond = selectedInterface.uploadBytesPerSecond
            snapshot.networkInterfaces = snapshot.networkInterfaces.map { item in
                var updated = item
                updated.isActive = item.name == selectedInterface.name
                return updated
            }
        } else {
            snapshot.downloadBytesPerSecond = max(
                0,
                (snapshot.networkReceivedBytes - previous.networkReceivedBytes) / elapsed
            )
            snapshot.uploadBytesPerSecond = max(
                0,
                (snapshot.networkSentBytes - previous.networkSentBytes) / elapsed
            )
        }
    }
}

struct HostTrustPrompt: Identifiable {
    let id = UUID()
    let probe: SSHHostKeyProbe
    let replacing: Bool
    var oldFingerprint: String?
}
