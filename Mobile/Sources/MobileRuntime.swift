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
    @Published var destination: MobileDestination = .dashboard
    @Published private(set) var snapshots: [UUID: ServerSnapshot] = [:]
    @Published private(set) var statuses: [UUID: ServerConnectionStatus] = [:]
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private(set) var terminalControllers: [UUID: MobileTerminalController] = [:]
    let terminalWorkspace = TerminalWorkspace()
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
        let known = Set(statuses.keys).union(snapshots.keys).union(requestIDs.keys).union(terminalWorkspace.tabs.map(\.serverID))
        for id in known.subtracting(existing) { removeServer(serverID: id) }
        for server in servers where !server.enableDashboardMonitor { cancelMonitor(serverID: server.id) }
    }

    @discardableResult
    func openSession(_ request: SessionOpenRequest, config: ServerConnectionConfig) -> MobileTerminalController? {
        guard request.serverID == config.id else { return nil }
        if case .split(let pane, _) = request.policy, !terminalWorkspace.canSplit(pane) { return nil }
        destination = .sessions
        let controller = openTerminal(config: config, forceNew: request.policy != .reuseRecent)
        if case .split(let pane, let axis) = request.policy,
           !terminalWorkspace.split(pane, inserting: controller.id, axis: axis) {
            closeTerminal(sessionID: controller.id)
            return nil
        }
        // The controller owns the task, independent of whether the pane is on screen.
        controller.beginIfNeeded()
        return controller
    }

    func openTerminal(config: ServerConnectionConfig, forceNew: Bool = false) -> MobileTerminalController {
        if !forceNew, let id = terminalWorkspace.mostRecentTerminal(for: config.id), let existing = terminalControllers[id] {
            terminalWorkspace.select(pane: existing.id)
            return existing
        }
        let controller = MobileTerminalController(
            config: config,
            engine: engine,
            trustBroker: trustBroker
        )
        terminalControllers[controller.id] = controller
        terminalWorkspace.add(sessionID: controller.id, serverID: config.id, title: config.name)
        return controller
    }

    @Published private(set) var fileControllers: [UUID: MobileSFTPController] = [:]

    func openSFTP(config: ServerConnectionConfig, initialPath: String = ".") {
        destination = .sessions
        let id = UUID()
        let controller = MobileSFTPController(config: config, engine: engine, broker: trustBroker, initialPath: initialPath)
        fileControllers[id] = controller
        terminalWorkspace.add(sessionID: id, serverID: config.id, title: config.name, kind: .sftp)
        controller.beginIfNeeded()
    }

    func closeWorkspaceTabs(_ tabs: [WorkspaceTab]) {
        for tab in tabs {
            for id in tab.layout.panes {
                if let controller = fileControllers.removeValue(forKey: id) { Task { await controller.stop() } }
                closeTerminal(sessionID: id)
            }
            terminalWorkspace.remove(tab: tab.id)
        }
    }

    func closeTerminal(serverID: UUID) {
        for (id, controller) in fileControllers where controller.config.id == serverID {
            fileControllers[id] = nil
            Task { await controller.stop() }
        }
        for controller in terminalControllers.values where controller.config.id == serverID { closeTerminal(sessionID: controller.id) }
        for tab in terminalWorkspace.tabs where tab.serverID == serverID && tab.kind != .terminal { terminalWorkspace.remove(tab: tab.id) }
    }

    func closeTerminal(sessionID: UUID) {
        guard let controller = terminalControllers.removeValue(forKey: sessionID) else { return }
        terminalWorkspace.remove(pane: sessionID)
        Task { await controller.dispose() }
    }

    func suspendForBackground() {
        guard !isBackgrounded else { return }
        isBackgrounded = true
        for serverID in Array(requestIDs.keys) { cancelMonitor(serverID: serverID) }
        trustBroker.rejectAll()
        for controller in fileControllers.values { Task { await controller.stop(background: true) } }
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
    private(set) var config: ServerConnectionConfig
    private var disposed = false
    lazy var surface = MobileTerminalSurface(controller: self)
    lazy var tools = TerminalTools(serverID: config.id)
    private var hasStarted = false
    private var initialConnectionTask: Task<Void, Never>?
    private var generation = UUID()
    private var dimensions = RemoteShellDimensions.standard
    private var writeTask: Task<Void, Never>?

    @Published private(set) var status: TerminalConnectionStatus = .connecting
    @Published private(set) var lastError: String?

    private let engine: any RemoteConnectionEngine
    private let trustBroker: MobileHostTrustBroker
    private var session: (any RemoteSession)?
    private var shell: (any RemoteShellSession)?
    private var readerTask: Task<Void, Never>?

    init(
        config: ServerConnectionConfig,
        engine: any RemoteConnectionEngine,
        trustBroker: MobileHostTrustBroker
    ) {
        self.config = config
        self.engine = engine
        self.trustBroker = trustBroker
    }

    func beginIfNeeded() {
        guard !hasStarted, !disposed else { return }
        hasStarted = true
        initialConnectionTask = Task { [weak self] in await self?.connect() }
    }

    func reconnect(config: ServerConnectionConfig) {
        guard !disposed else { return }
        self.config = config
        initialConnectionTask?.cancel()
        initialConnectionTask = Task { [weak self] in await self?.connect() }
    }

    func startIfNeeded() async {
        guard !hasStarted, !disposed else { return }
        hasStarted = true
        // The session owns initial connection work. Unmounting a tab must not cancel its handshake.
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.connect()
        }
        initialConnectionTask = task
        await task.value
        initialConnectionTask = nil
    }

    func connect(dimensions: RemoteShellDimensions? = nil) async {
        guard !disposed, !Task.isCancelled else { return }
        hasStarted = true
        let request = UUID()
        generation = request
        await detach()
        guard generation == request else { return }
        if let dimensions { self.dimensions = dimensions }
        tools.resetCommandBoundary()
        status = .connecting
        lastError = nil
        do {
            let engine = self.engine
            let broker = trustBroker
            let session = try await engine.connect(config) { presentation in
                try await broker.evaluate(presentation)
            }
            guard generation == request, !Task.isCancelled else { await session.close(); return }
            let shell: any RemoteShellSession
            do { shell = try await session.openShell(dimensions: self.dimensions) }
            catch { await session.close(); throw error }
            guard generation == request, !Task.isCancelled else { await shell.close(); await session.close(); return }
            self.session = session
            self.shell = shell
            status = .connected
            readerTask = Task { [weak self] in
                do {
                    for try await data in shell.events {
                        guard !Task.isCancelled, self?.generation == request else { return }
                        self?.surface.terminal.feed(byteArray: Array(data)[...])
                        self?.tools.refreshPrompt()
                    }
                    if self?.generation == request, self?.status == .connected {
                        self?.status = .disconnected
                    }
                } catch is CancellationError {
                } catch {
                    if self?.generation == request {
                        self?.status = .failed
                        self?.lastError = error.localizedDescription
                    }
                }
                if self?.generation == request { await self?.detach() }
            }
        } catch {
            guard generation == request else { return }
            status = .failed
            lastError = error.localizedDescription
        }
    }

    func send(_ data: Data) {
        guard let shell else { return }
        let request = generation, previous = writeTask
        writeTask = Task {
            await previous?.value
            guard !Task.isCancelled, generation == request else { return }
            do {
                try await shell.write(data)
            } catch {
                guard generation == request else { return }
                self.lastError = error.localizedDescription
                self.status = .failed
            }
        }
    }

    func resize(_ dimensions: RemoteShellDimensions) {
        self.dimensions = dimensions
        guard let shell else { return }
        Task { try? await shell.resize(dimensions) }
    }

    func interruptForBackground() async {
        guard status == .connecting || status == .connected else { return }
        initialConnectionTask?.cancel()
        let request = UUID()
        generation = request
        hasStarted = true
        await detach()
        guard generation == request else { return }
        status = .interrupted
        lastError = "iOS 已暂停后台 SSH；请返回终端后重新连接。"
    }

    func close() async {
        initialConnectionTask?.cancel()
        let request = UUID()
        generation = request
        hasStarted = true
        await detach()
        guard generation == request else { return }
        if status != .interrupted { status = .disconnected }
    }

    func dispose() async {
        disposed = true
        surface.terminal.onFocus = nil
        surface.terminal.onShortcut = nil
        surface.terminal.updateUiClosed()
        await close()
    }

    private func detach() async {
        writeTask?.cancel()
        writeTask = nil
        readerTask?.cancel()
        readerTask = nil
        let oldShell = shell, oldSession = session
        shell = nil
        session = nil
        if let oldShell { await oldShell.close() }
        if let oldSession { await oldSession.close() }
    }
}
