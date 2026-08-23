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
    @Published private(set) var refreshingServerIDs: Set<UUID> = []
    @Published var terminalSessions: [TerminalSession] = []
    @Published var selectedTerminalID: UUID?
    @Published var refreshInterval: TimeInterval {
        didSet {
            UserDefaults.standard.set(refreshInterval, forKey: "refreshInterval")
            restartAutoRefresh()
        }
    }

    private var selectedConfig: ServerConnectionConfig?
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
        var activeServers = servers

        if UserDefaults.standard.bool(forKey: "didSeedDemoServers") {
            let legacyNames: Set<String> = [
                "hj-mini", "mini02", "macbook-pro", "vps-aliyun01",
                "vps-ximiai", "mini03", "home-mini", "mini04"
            ]
            let legacyHosts: Set<String> = [
                "192.168.1.39", "100.77.195.67", "192.168.1.19", "47.92.50.33",
                "8.155.6.59", "192.168.1.50", "192.168.1.62", "192.168.1.28"
            ]
            let legacyServers = servers.filter {
                legacyNames.contains($0.name) || legacyHosts.contains($0.host)
            }

            for server in legacyServers {
                try? KeychainService.deletePassword(for: server.id)
                removeRuntimeData(for: server.id)
                context.delete(server)
            }
            try? context.save()
            activeServers.removeAll { legacy in
                legacyServers.contains { $0.id == legacy.id }
            }
            UserDefaults.standard.removeObject(forKey: "didSeedDemoServers")
        }

        for server in activeServers where snapshots[server.id] == nil {
            initializeRuntime(for: server)
        }
    }

    func initializeRuntime(for server: ServerRecord) {
        snapshots[server.id] = .empty
        statuses[server.id] = .unknown
        histories[server.id] = []
        errors[server.id] = nil
    }

    func select(_ server: ServerRecord?) {
        selectedServerID = server?.id
        selectedConfig = server?.connectionConfig
        detailMode = .monitor
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

    func applyValidatedSnapshot(_ snapshot: ServerSnapshot, to server: ServerRecord) {
        snapshots[server.id] = snapshot
        histories[server.id] = []
        appendHistory(snapshot, for: server.id)
        statuses[server.id] = .online
        errors[server.id] = nil
        server.lastConnectedAt = snapshot.capturedAt
        if selectedServerID == server.id {
            selectedConfig = server.connectionConfig
            restartAutoRefresh()
        }
    }

    func refresh(_ server: ServerRecord) async {
        let config = server.connectionConfig
        guard !refreshingServerIDs.contains(server.id) else { return }
        refreshingServerIDs.insert(server.id)
        defer { refreshingServerIDs.remove(server.id) }
        if statuses[server.id] == nil || statuses[server.id] == .unknown {
            statuses[server.id] = .connecting
        }

        do {
            var snapshot = try await SSHMonitoringService.collect(config)
            if let previous = snapshots[server.id], previous.capturedAt != .distantPast {
                let elapsed = max(0.1, snapshot.capturedAt.timeIntervalSince(previous.capturedAt))
                snapshot.downloadBytesPerSecond = max(
                    0,
                    (snapshot.networkReceivedBytes - previous.networkReceivedBytes) / elapsed
                )
                snapshot.uploadBytesPerSecond = max(
                    0,
                    (snapshot.networkSentBytes - previous.networkSentBytes) / elapsed
                )
            }
            snapshots[server.id] = snapshot
            appendHistory(snapshot, for: server.id)
            statuses[server.id] = .online
            errors[server.id] = nil
            server.lastConnectedAt = .now
        } catch {
            statuses[server.id] = .failed
            errors[server.id] = error.localizedDescription
        }
    }

    func refreshAll(_ servers: [ServerRecord]) async {
        let work = servers
            .filter { !refreshingServerIDs.contains($0.id) }
            .map { ($0.id, $0.connectionConfig) }
        guard !work.isEmpty else { return }

        let refreshingIDs = Set(work.map(\.0))
        refreshingServerIDs.formUnion(refreshingIDs)
        defer { refreshingServerIDs.subtract(refreshingIDs) }

        for start in stride(from: 0, to: work.count, by: 3) {
            let chunk = Array(work[start..<min(start + 3, work.count)])
            for (id, _) in chunk {
                if statuses[id] == nil || statuses[id] == .unknown {
                    statuses[id] = .connecting
                }
            }

            await withTaskGroup(of: (UUID, Result<ServerSnapshot, Error>).self) { group in
                for (id, config) in chunk {
                    group.addTask {
                        do {
                            return (id, .success(try await SSHMonitoringService.collect(config)))
                        } catch {
                            return (id, .failure(error))
                        }
                    }
                }

                for await (id, result) in group {
                    switch result {
                    case .success(var snapshot):
                        if let previous = snapshots[id], previous.capturedAt != .distantPast {
                            let elapsed = max(0.1, snapshot.capturedAt.timeIntervalSince(previous.capturedAt))
                            snapshot.downloadBytesPerSecond = max(
                                0,
                                (snapshot.networkReceivedBytes - previous.networkReceivedBytes) / elapsed
                            )
                            snapshot.uploadBytesPerSecond = max(
                                0,
                                (snapshot.networkSentBytes - previous.networkSentBytes) / elapsed
                            )
                        }
                        snapshots[id] = snapshot
                        appendHistory(snapshot, for: id)
                        statuses[id] = .online
                        errors[id] = nil
                    case .failure(let error):
                        statuses[id] = .failed
                        errors[id] = error.localizedDescription
                    }
                }
            }
        }
    }

    func openTerminal(for server: ServerRecord) {
        if let existing = terminalSessions.first(where: { $0.serverID == server.id }) {
            selectedTerminalID = existing.id
        } else {
            let session = TerminalSession(server: server)
            terminalSessions.append(session)
            selectedTerminalID = session.id
        }
        selectedServerID = server.id
        selectedConfig = server.connectionConfig
        detailMode = .terminal
    }

    func newTerminal(for server: ServerRecord) {
        let session = TerminalSession(server: server)
        terminalSessions.append(session)
        selectedTerminalID = session.id
        selectedServerID = server.id
        selectedConfig = server.connectionConfig
        detailMode = .terminal
    }

    func closeTerminal(_ session: TerminalSession) {
        guard let index = terminalSessions.firstIndex(of: session) else { return }
        terminalSessions.remove(at: index)
        if selectedTerminalID == session.id {
            selectedTerminalID = terminalSessions.last?.id
            if terminalSessions.isEmpty {
                detailMode = .monitor
            }
        }
    }

    func removeRuntimeData(for serverID: UUID) {
        statuses[serverID] = nil
        snapshots[serverID] = nil
        histories[serverID] = nil
        errors[serverID] = nil
        refreshingServerIDs.remove(serverID)
        terminalSessions.removeAll { $0.serverID == serverID }
        if selectedServerID == serverID {
            selectedServerID = nil
            selectedConfig = nil
            detailMode = .monitor
        }
    }

    func updateRefreshInterval(_ interval: TimeInterval) {
        UserDefaults.standard.set(true, forKey: "refreshIntervalConfigured")
        refreshInterval = interval
    }

    private func restartAutoRefresh() {
        autoRefreshTask?.cancel()
        guard refreshInterval > 0, let config = selectedConfig else { return }
        let interval = refreshInterval
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                await self.refresh(config)
            }
        }
    }

    private func refresh(_ config: ServerConnectionConfig) async {
        guard !refreshingServerIDs.contains(config.id) else { return }
        refreshingServerIDs.insert(config.id)
        defer { refreshingServerIDs.remove(config.id) }
        if statuses[config.id] == nil || statuses[config.id] == .unknown {
            statuses[config.id] = .connecting
        }
        do {
            var snapshot = try await SSHMonitoringService.collect(config)
            if let previous = snapshots[config.id], previous.capturedAt != .distantPast {
                let elapsed = max(0.1, snapshot.capturedAt.timeIntervalSince(previous.capturedAt))
                snapshot.downloadBytesPerSecond = max(
                    0,
                    (snapshot.networkReceivedBytes - previous.networkReceivedBytes) / elapsed
                )
                snapshot.uploadBytesPerSecond = max(
                    0,
                    (snapshot.networkSentBytes - previous.networkSentBytes) / elapsed
                )
            }
            snapshots[config.id] = snapshot
            appendHistory(snapshot, for: config.id)
            statuses[config.id] = .online
            errors[config.id] = nil
        } catch {
            statuses[config.id] = .failed
            errors[config.id] = error.localizedDescription
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
                upload: snapshot.uploadBytesPerSecond
            )
        )
        histories[id] = Array(points.suffix(120))
    }

}
