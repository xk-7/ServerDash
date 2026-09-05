import Foundation
import SwiftUI

@MainActor
final class MobileHostTrustBroker: ObservableObject {
    struct PendingRequest: Identifiable {
        let id = UUID()
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
        return try await withCheckedThrowingContinuation { continuation in
            queue.append(
                QueueItem(
                    request: PendingRequest(
                        presentation: presentation,
                        oldFingerprint: oldFingerprint
                    ),
                    continuation: continuation
                )
            )
            presentNextIfNeeded()
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

    let engine: any RemoteConnectionEngine
    let trustBroker: MobileHostTrustBroker

    private var monitorTasks: [UUID: Task<Void, Never>] = [:]

    init(
        engine: any RemoteConnectionEngine,
        trustBroker: MobileHostTrustBroker
    ) {
        self.engine = engine
        self.trustBroker = trustBroker
    }

    convenience init() {
        self.init(
            engine: CitadelRemoteConnectionEngine(),
            trustBroker: MobileHostTrustBroker()
        )
    }

    func refresh(
        server: ServerRecord,
        identities: [IdentityRecord],
        keys: [SSHKeyRecord],
        routes: [ConnectionRouteRecord]
    ) {
        guard !isBackgrounded, monitorTasks[server.id] == nil else { return }
        let config = ConnectionConfigResolver.resolve(
            server: server,
            identities: identities,
            keys: keys,
            routes: routes
        )
        statuses[server.id] = .connecting
        errors[server.id] = nil
        let engine = self.engine
        let broker = trustBroker
        monitorTasks[server.id] = Task { [weak self] in
            defer { self?.monitorTasks[server.id] = nil }
            do {
                let session = try await engine.connect(config) { presentation in
                    try await broker.evaluate(presentation)
                }
                defer { Task { await session.close() } }
                let result = try await session.execute(
                    SSHMonitoringService.remoteCommand,
                    timeout: 60,
                    maxOutputBytes: 512_000
                )
                let snapshot: ServerSnapshot
                do {
                    snapshot = try MonitoringResponseParser.parse(result.output)
                } catch MonitoringError.invalidResponse {
                    let fallback = try await session.execute(
                        SSHMonitoringService.fallbackRemoteCommand,
                        timeout: 60,
                        maxOutputBytes: 512_000
                    )
                    snapshot = try MonitoringResponseParser.parse(fallback.output)
                }
                guard !Task.isCancelled else { return }
                self?.snapshots[server.id] = snapshot
                self?.statuses[server.id] = .online
                server.lastSuccessfulMonitorAt = snapshot.capturedAt
                server.lastConnectedAt = .now
                server.verificationStatus = .monitorReady
            } catch is CancellationError {
                self?.statuses[server.id] = .unknown
            } catch {
                self?.statuses[server.id] = .failed
                self?.errors[server.id] = error.localizedDescription
            }
        }
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
        for task in monitorTasks.values { task.cancel() }
        monitorTasks.removeAll()
        trustBroker.rejectAll()
        for controller in terminalControllers.values {
            Task { await controller.interruptForBackground() }
        }
    }

    func resumeFromBackground() {
        isBackgrounded = false
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
