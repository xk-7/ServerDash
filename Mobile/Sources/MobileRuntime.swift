import Foundation
import SwiftUI

struct MobileFleetSummary {
    private(set) var online = 0
    private(set) var issues = 0
    private(set) var pending = 0
    private(set) var paused = 0

    init(servers: [ServerRecord], statuses: [UUID: ServerConnectionStatus]) {
        for server in servers {
            guard server.enableDashboardMonitor else { paused += 1; continue }
            switch statuses[server.id] ?? .unknown {
            case .online: online += 1
            case .failed, .offline: issues += 1
            case .unknown, .connecting: pending += 1
            }
        }
    }
}

@MainActor
final class MobileHostTrustBroker: ObservableObject {
    struct PendingRequest: Identifiable {
        let id: UUID
        let presentation: RemoteHostKeyPresentation
        let oldFingerprint: String?

        var changed: Bool { oldFingerprint != nil }
    }

    @Published private(set) var pending: PendingRequest?

    private struct QueueItem {
        let request: PendingRequest
        let continuation: CheckedContinuation<RemoteHostTrustDecision, Error>
    }

    private var queue: [QueueItem] = []
    private var current: QueueItem?

    func evaluate(
        _ presentation: RemoteHostKeyPresentation
    ) async throws -> RemoteHostTrustDecision {
        let stored = TrustedHostStore.existingKeys(
            host: presentation.host,
            port: presentation.port
        )
        if stored.contains(where: {
            $0.algorithm == presentation.algorithm && $0.fingerprint == presentation.fingerprint
        }) {
            return .trustOnce
        }

        let oldFingerprint = stored.first(where: {
            $0.algorithm == presentation.algorithm
        })?.fingerprint ?? stored.first?.fingerprint
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.append(
                    QueueItem(
                        request: PendingRequest(id: id, presentation: presentation, oldFingerprint: oldFingerprint),
                        continuation: continuation
                    )
                )
                presentNextIfNeeded()
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id: id) }
        }
    }

    private func cancel(id: UUID) {
        if current?.request.id == id {
            let continuation = current?.continuation
            current = nil
            pending = nil
            continuation?.resume(throwing: CancellationError())
            presentNextIfNeeded()
        } else if let index = queue.firstIndex(where: { $0.request.id == id }) {
            queue.remove(at: index).continuation.resume(throwing: CancellationError())
        }
    }

    func respond(_ decision: RemoteHostTrustDecision) {
        guard let current else { return }
        do {
            if decision == .trustAndStore {
                try TrustedHostStore.trust(
                    current.request.presentation.probe,
                    replacing: current.request.changed
                )
            }
            self.current = nil
            pending = nil
            current.continuation.resume(returning: decision)
        } catch {
            self.current = nil
            pending = nil
            current.continuation.resume(throwing: error)
        }
        presentNextIfNeeded()
    }

    func rejectAll() {
        if let current {
            current.continuation.resume(returning: .reject)
        }
        for item in queue {
            item.continuation.resume(returning: .reject)
        }
        current = nil
        queue.removeAll()
        pending = nil
    }

    private func presentNextIfNeeded() {
        guard current == nil, !queue.isEmpty else { return }
        current = queue.removeFirst()
        pending = current?.request
    }
}

@MainActor
final class MobileRuntime: ObservableObject {
    @Published private(set) var snapshots: [UUID: ServerSnapshot] = [:]
    @Published private(set) var statuses: [UUID: ServerConnectionStatus] = [:]
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private(set) var terminalControllers: [UUID: MobileTerminalController] = [:]
    @Published private(set) var isBackgrounded = false
    @Published private(set) var refreshingServerIDs: Set<UUID> = []

    let engine: any RemoteConnectionEngine
    let trustBroker: MobileHostTrustBroker

    private var monitorTasks: [UUID: Task<Void, Never>] = [:]
    private struct MonitorRequest {
        let id: UUID
        let server: ServerRecord
        let config: ServerConnectionConfig
    }
    private var monitorQueue: [MonitorRequest] = []
    private var requestIDs: [UUID: UUID] = [:]
    private var completionWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var failureCounts: [UUID: Int] = [:]
    private var retryAfter: [UUID: Date] = [:]
    private let maxConcurrentMonitors: Int

    init(
        engine: any RemoteConnectionEngine,
        trustBroker: MobileHostTrustBroker,
        maxConcurrentMonitors: Int = 3
    ) {
        self.engine = engine
        self.trustBroker = trustBroker
        self.maxConcurrentMonitors = max(1, maxConcurrentMonitors)
    }

    convenience init() {
        self.init(
            engine: CitadelRemoteConnectionEngine(),
            trustBroker: MobileHostTrustBroker()
        )
    }

    @discardableResult
    func refresh(
        server: ServerRecord,
        identities: [IdentityRecord],
        keys: [SSHKeyRecord],
        routes: [ConnectionRouteRecord],
        automatic: Bool = false
    ) -> UUID? {
        guard !isBackgrounded else { return nil }
        if let existing = requestIDs[server.id] { return existing }
        if automatic, let retry = retryAfter[server.id], retry > .now { return nil }
        let config = ConnectionConfigResolver.resolve(
            server: server,
            identities: identities,
            keys: keys,
            routes: routes
        )
        let id = UUID()
        requestIDs[server.id] = id
        refreshingServerIDs.insert(server.id)
        monitorQueue.append(MonitorRequest(id: id, server: server, config: config))
        startNextMonitors()
        return id
    }

    func refreshAll(
        servers: [ServerRecord], identities: [IdentityRecord], keys: [SSHKeyRecord],
        routes: [ConnectionRouteRecord], failedOnly: Bool = false, automatic: Bool = false
    ) async {
        guard !Task.isCancelled else { return }
        let ids = servers.filter {
            $0.enableDashboardMonitor && (!failedOnly || statuses[$0.id] == .failed || statuses[$0.id] == .offline)
        }.compactMap { server -> (UUID, UUID)? in
            guard let id = refresh(server: server, identities: identities, keys: keys, routes: routes, automatic: automatic) else { return nil }
            return (server.id, id)
        }
        for (serverID, id) in ids {
            guard requestIDs[serverID] == id else { continue }
            await withCheckedContinuation { completionWaiters[id, default: []].append($0) }
        }
    }

    private func startNextMonitors() {
        while !isBackgrounded, monitorTasks.count < maxConcurrentMonitors,
              let index = monitorQueue.firstIndex(where: { monitorTasks[$0.config.id] == nil }) {
            let request = monitorQueue.remove(at: index)
            let serverID = request.config.id
            // Keep a successful status while updating; stale data is labelled by the card.
            if snapshots[serverID] == nil { statuses[serverID] = .connecting }
            monitorTasks[serverID] = Task { [weak self] in
                await self?.collect(request)
            }
        }
    }

    private func collect(_ request: MonitorRequest) async {
        let serverID = request.config.id
        defer {
            monitorTasks[serverID] = nil
            if requestIDs[serverID] == request.id {
                requestIDs[serverID] = nil
                refreshingServerIDs.remove(serverID)
            }
            complete(request.id)
            startNextMonitors()
        }
        let engine = self.engine
        let broker = trustBroker
        do {
            var snapshot = try await Self.fetchSnapshot(config: request.config, engine: engine) { presentation in
                try await broker.evaluate(presentation)
            }
            guard !Task.isCancelled, requestIDs[serverID] == request.id else { return }
            if let previous = snapshots[serverID] {
                let elapsed = snapshot.capturedAt.timeIntervalSince(previous.capturedAt)
                if elapsed > 0, snapshot.activeNetworkInterface == previous.activeNetworkInterface {
                    snapshot.downloadBytesPerSecond = max(0, snapshot.networkReceivedBytes - previous.networkReceivedBytes) / elapsed
                    snapshot.uploadBytesPerSecond = max(0, snapshot.networkSentBytes - previous.networkSentBytes) / elapsed
                }
            }
            snapshots[serverID] = snapshot
            statuses[serverID] = .online
            errors[serverID] = nil
            failureCounts[serverID] = nil
            retryAfter[serverID] = nil
            request.server.lastSuccessfulMonitorAt = snapshot.capturedAt
            request.server.lastConnectedAt = .now
            request.server.verificationStatus = .monitorReady
        } catch {
            guard !Task.isCancelled, requestIDs[serverID] == request.id else { return }
            statuses[serverID] = .failed
            errors[serverID] = error.localizedDescription
            let failures = min(6, (failureCounts[serverID] ?? 0) + 1)
            failureCounts[serverID] = failures
            retryAfter[serverID] = Date().addingTimeInterval(min(300, 15 * pow(2, Double(failures - 1))))
        }
    }

    // Parsing runs off the main actor. A slot remains occupied until its SSH session closes.
    nonisolated private static func fetchSnapshot(
        config: ServerConnectionConfig, engine: any RemoteConnectionEngine,
        trustHandler: @escaping RemoteHostTrustHandler
    ) async throws -> ServerSnapshot {
        try Task.checkCancellation()
        let session = try await engine.connect(config, trustHandler: trustHandler)
        do {
            try Task.checkCancellation()
            let result = try await session.execute(SSHMonitoringService.remoteCommand, timeout: 60, maxOutputBytes: 512_000)
            let snapshot: ServerSnapshot
            do {
                snapshot = try MonitoringResponseParser.parse(result.output)
            } catch MonitoringError.invalidResponse {
                try Task.checkCancellation()
                let fallback = try await session.execute(SSHMonitoringService.fallbackRemoteCommand, timeout: 60, maxOutputBytes: 512_000)
                snapshot = try MonitoringResponseParser.parse(fallback.output)
            }
            await session.close()
            return snapshot
        } catch {
            await session.close()
            throw error
        }
    }

    private func complete(_ id: UUID) {
        for waiter in completionWaiters.removeValue(forKey: id) ?? [] { waiter.resume() }
    }

    func cancelMonitor(serverID: UUID) {
        if let id = requestIDs.removeValue(forKey: serverID) { complete(id) }
        monitorQueue.removeAll { $0.config.id == serverID }
        monitorTasks[serverID]?.cancel()
        refreshingServerIDs.remove(serverID)
        if statuses[serverID] == .connecting { statuses[serverID] = .unknown }
    }

    func removeServer(serverID: UUID) {
        cancelMonitor(serverID: serverID)
        closeTerminal(serverID: serverID)
        snapshots[serverID] = nil
        statuses[serverID] = nil
        errors[serverID] = nil
        failureCounts[serverID] = nil
        retryAfter[serverID] = nil
    }

    func reconcileServers(_ servers: [ServerRecord]) {
        let existing = Set(servers.map(\.id))
        let known = Set(statuses.keys).union(snapshots.keys).union(requestIDs.keys).union(terminalControllers.keys)
        for id in known.subtracting(existing) { removeServer(serverID: id) }
        for server in servers where !server.enableDashboardMonitor { cancelMonitor(serverID: server.id) }
    }

    func openTerminal(config: ServerConnectionConfig) -> MobileTerminalController {
        if let existing = terminalControllers[config.id] {
            return existing
        }
        let controller = MobileTerminalController(
            config: config,
            engine: engine,
            trustBroker: trustBroker
        )
        terminalControllers[config.id] = controller
        return controller
    }

    func closeTerminal(serverID: UUID) {
        guard let controller = terminalControllers.removeValue(forKey: serverID) else { return }
        Task { await controller.close() }
    }

    func suspendForBackground() {
        guard !isBackgrounded else { return }
        isBackgrounded = true
        for serverID in Array(requestIDs.keys) { cancelMonitor(serverID: serverID) }
        trustBroker.rejectAll()
        for controller in terminalControllers.values {
            Task { await controller.interruptForBackground() }
        }
    }

    func resumeFromBackground() {
        isBackgrounded = false
        retryAfter.removeAll()
    }
}

@MainActor
final class MobileTerminalController: ObservableObject, Identifiable {
    let id = UUID()
    let config: ServerConnectionConfig

    @Published private(set) var status: TerminalConnectionStatus = .connecting
    @Published private(set) var lastError: String?
    @Published private(set) var outputRevision = 0

    private let engine: any RemoteConnectionEngine
    private let trustBroker: MobileHostTrustBroker
    private var session: (any RemoteSession)?
    private var shell: (any RemoteShellSession)?
    private var readerTask: Task<Void, Never>?
    private var pendingOutput: [Data] = []

    init(
        config: ServerConnectionConfig,
        engine: any RemoteConnectionEngine,
        trustBroker: MobileHostTrustBroker
    ) {
        self.config = config
        self.engine = engine
        self.trustBroker = trustBroker
    }

    func connect(dimensions: RemoteShellDimensions = .standard) async {
        await close()
        status = .connecting
        lastError = nil
        do {
            let engine = self.engine
            let broker = trustBroker
            let session = try await engine.connect(config) { presentation in
                try await broker.evaluate(presentation)
            }
            let shell = try await session.openShell(dimensions: dimensions)
            self.session = session
            self.shell = shell
            status = .connected
            readerTask = Task { [weak self] in
                do {
                    for try await data in shell.events {
                        guard !Task.isCancelled else { return }
                        self?.pendingOutput.append(data)
                        self?.outputRevision &+= 1
                    }
                    if self?.status == .connected {
                        self?.status = .disconnected
                    }
                } catch is CancellationError {
                } catch {
                    self?.status = .failed
                    self?.lastError = error.localizedDescription
                }
            }
        } catch {
            status = .failed
            lastError = error.localizedDescription
        }
    }

    func drainOutput() -> [Data] {
        defer { pendingOutput.removeAll(keepingCapacity: true) }
        return pendingOutput
    }

    func send(_ data: Data) {
        guard let shell else { return }
        Task {
            do {
                try await shell.write(data)
            } catch {
                self.lastError = error.localizedDescription
                self.status = .failed
            }
        }
    }

    func resize(_ dimensions: RemoteShellDimensions) {
        guard let shell else { return }
        Task { try? await shell.resize(dimensions) }
    }

    func interruptForBackground() async {
        guard status == .connecting || status == .connected else { return }
        await close()
        status = .interrupted
        lastError = "iOS 已暂停后台 SSH；请返回终端后重新连接。"
    }

    func close() async {
        readerTask?.cancel()
        readerTask = nil
        if let shell { await shell.close() }
        if let session { await session.close() }
        shell = nil
        session = nil
        if status != .interrupted { status = .disconnected }
    }
}
