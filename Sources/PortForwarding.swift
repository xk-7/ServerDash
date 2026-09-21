import Darwin
import Foundation

enum PortForwardSessionState: String, Codable, Sendable {
    case starting
    case ready
    case reconnecting
    case stopping
    case stopped
    case failed
}

struct PortForwardSnapshot: Identifiable, Equatable, Sendable {
    var id: UUID
    var ruleID: UUID
    var state: PortForwardSessionState
    var processIdentifier: Int32?
    var startedAt: Date?
    var reconnectAttempt: Int
    var activeConnections: Int?
    var transferredBytes: Int64?
    var lastError: String?
}

protocol TunnelProcessHandle: Sendable {
    var processIdentifier: Int32 { get }
    func isRunning() -> Bool
    func terminate()
    func kill()
    func waitForExit() async -> Int32
    func boundedErrorOutput() -> String
}

protocol TunnelProcessLaunching: Sendable {
    func launch(_ plan: OpenSSHLaunchPlan) throws -> any TunnelProcessHandle
}

struct FoundationTunnelProcessLauncher: TunnelProcessLaunching {
    func launch(_ plan: OpenSSHLaunchPlan) throws -> any TunnelProcessHandle {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: plan.executable)
        process.arguments = plan.arguments
        process.environment = plan.environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ConnectionRouteError.tunnelLaunchFailed(error.localizedDescription)
        }
        return FoundationTunnelProcessHandle(process: process, errorPipe: errorPipe)
    }
}

private final class FoundationTunnelProcessHandle: TunnelProcessHandle, @unchecked Sendable {
    private let process: Process
    private let errorPipe: Pipe
    private let errorLock = NSLock()
    private var errorData = Data()
    private let maxErrorBytes = 32_768

    init(process: Process, errorPipe: Pipe) {
        self.process = process
        self.errorPipe = errorPipe
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.appendError(data)
        }
    }

    deinit {
        errorPipe.fileHandleForReading.readabilityHandler = nil
        try? errorPipe.fileHandleForReading.close()
    }

    var processIdentifier: Int32 { process.processIdentifier }

    func isRunning() -> Bool {
        process.isRunning
    }

    func terminate() {
        guard process.isRunning else { return }
        _ = Darwin.kill(process.processIdentifier, SIGTERM)
    }

    func kill() {
        guard process.isRunning else { return }
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
    }

    func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            let completion = OneShotContinuation(continuation)
            process.terminationHandler = { terminatedProcess in
                completion.resume(returning: terminatedProcess.terminationStatus)
            }
            if !process.isRunning {
                completion.resume(returning: process.terminationStatus)
            }
        }
    }

    func boundedErrorOutput() -> String {
        errorLock.lock()
        defer { errorLock.unlock() }
        return String(decoding: errorData, as: UTF8.self)
    }

    private func appendError(_ data: Data) {
        errorLock.lock()
        defer { errorLock.unlock() }
        errorData.append(data)
        if errorData.count > maxErrorBytes {
            errorData.removeFirst(errorData.count - maxErrorBytes)
        }
    }
}

actor PortForwardSupervisor {
    static let shared = PortForwardSupervisor()

    private struct ActiveTunnel {
        var rule: PortForwardRule
        var config: ServerConnectionConfig
        var exposureConfirmed: Bool
        var handle: any TunnelProcessHandle
        var snapshot: PortForwardSnapshot
        var generation: UUID
        var stopRequested: Bool
        var transportRule: PortForwardRule
        var httpProxy: HTTPToSOCKSProxy?
        var cleanupPaths: [String]
        var handshakeMarker: URL?
    }

    private let provider: any ConnectionProvider
    private let launcher: any TunnelProcessLaunching
    private let maxReconnectAttempts: Int
    private let readinessTimeout: TimeInterval
    private var tunnels: [UUID: ActiveTunnel] = [:]
    private var acceptingNewTunnels = true

    init(
        provider: any ConnectionProvider = SystemOpenSSHConnectionProvider(),
        launcher: any TunnelProcessLaunching = FoundationTunnelProcessLauncher(),
        maxReconnectAttempts: Int = 3,
        readinessTimeout: TimeInterval = 2
    ) {
        self.provider = provider
        self.launcher = launcher
        self.maxReconnectAttempts = max(0, maxReconnectAttempts)
        self.readinessTimeout = max(0.2, readinessTimeout)
    }

    func start(
        rule: PortForwardRule,
        config: ServerConnectionConfig,
        exposureConfirmed: Bool = false,
        remoteForwardConfirmed: Bool = false
    ) async throws -> PortForwardSnapshot {
        guard acceptingNewTunnels else { throw CancellationError() }
        try rule.validate(
            exposureConfirmed: exposureConfirmed,
            remoteForwardConfirmed: remoteForwardConfirmed
        )
        guard rule.serverID == config.id else {
            throw ConnectionRouteError.invalidEndpoint("隧道服务器引用")
        }
        if let existing = tunnels[rule.id],
           existing.snapshot.state == .ready || existing.snapshot.state == .starting ||
            existing.snapshot.state == .reconnecting {
            return existing.snapshot
        }
        if rule.direction != .remote,
           !LocalPortAvailability.isAvailable(address: rule.bindAddress, port: rule.listenPort, reuseAddress: rule.direction == .http) {
            throw ConnectionRouteError.portUnavailable(rule.listenPort)
        }
        var transportRule = rule
        if rule.direction == .http {
            transportRule.direction = .dynamic; transportRule.bindAddress = "127.0.0.1"
            transportRule.listenPort = try HTTPToSOCKSProxy.availableLoopbackPort()
        }
        var plan = try provider.launchPlan(for: config, purpose: .portForward(transportRule))
        var handshakeMarker: URL?
        do {
            if transportRule.direction == .remote {
                let marker = try SSHSessionBootstrap.handshakeMarker()
                handshakeMarker = marker
                plan.arguments.insert(contentsOf: SSHSessionBootstrap.markerArguments(marker), at: 0)
            }
            let handle = try launcher.launch(plan)
            let generation = UUID()
            let active = ActiveTunnel(
                rule: rule,
                config: config,
                exposureConfirmed: exposureConfirmed,
                handle: handle,
                snapshot: PortForwardSnapshot(
                    id: UUID(),
                    ruleID: rule.id,
                    state: .starting,
                    processIdentifier: handle.processIdentifier,
                    startedAt: .now,
                    reconnectAttempt: 0,
                    activeConnections: nil,
                    transferredBytes: nil,
                    lastError: nil
                ),
                generation: generation,
                stopRequested: false,
                transportRule: transportRule,
                httpProxy: nil,
                cleanupPaths: plan.cleanupPaths,
                handshakeMarker: handshakeMarker
            )
            tunnels[rule.id] = active
            try await waitUntilReady(
                rule: transportRule,
                handle: handle,
                handshakeMarker: handshakeMarker
            )
            guard let current = currentTunnel(ruleID: rule.id, generation: generation) else {
                _ = await terminateAfterFailedStart(handle)
                throw CancellationError()
            }
            if isStopState(current) {
                _ = await terminateAfterFailedStart(handle)
                throw CancellationError()
            }
            var ready = current
            if rule.direction == .http {
                let proxy = HTTPToSOCKSProxy(socksPort: transportRule.listenPort)
                try proxy.start(bindAddress: rule.bindAddress, port: rule.listenPort)
                ready.httpProxy = proxy
            }
            ready.snapshot.state = .ready
            tunnels[rule.id] = ready
            monitorExit(ruleID: rule.id, generation: generation, handle: handle)
            return ready.snapshot
        } catch {
            TemporaryKeyMaterial.cleanup(plan.cleanupPaths)
            if let handshakeMarker {
                SSHSessionBootstrap.removeMarker(handshakeMarker)
            }
            if let current = tunnels[rule.id], isStopState(current) {
                throw error
            }
            let handle = tunnels[rule.id]?.handle
            let stopped = if let handle {
                await terminateAfterFailedStart(handle)
            } else {
                true
            }
            if var failed = tunnels[rule.id], !isStopState(failed) {
                failed.snapshot.state = .failed
                failed.snapshot.processIdentifier = stopped ? nil : failed.handle.processIdentifier
                failed.snapshot.lastError = stopped
                    ? error.localizedDescription
                    : ConnectionRouteError.tunnelStopTimedOut.localizedDescription
                failed.cleanupPaths = []
                failed.handshakeMarker = nil
                tunnels[rule.id] = failed
            }
            throw error
        }
    }

    func stop(ruleID: UUID) async throws -> PortForwardSnapshot? {
        guard var active = tunnels[ruleID] else { return nil }
        active.stopRequested = true
        active.snapshot.state = .stopping
        active.httpProxy?.stop(); active.httpProxy = nil
        tunnels[ruleID] = active
        let deadline = Date().addingTimeInterval(1)
        active.handle.terminate()
        while active.handle.isRunning(), Date() < deadline.addingTimeInterval(-0.45) {
            try? await Task.sleep(for: .milliseconds(25))
        }
        if active.handle.isRunning() {
            active.handle.kill()
        }
        while active.handle.isRunning(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard !active.handle.isRunning() else {
            active.snapshot.state = .failed
            active.snapshot.lastError = ConnectionRouteError.tunnelStopTimedOut.localizedDescription
            tunnels[ruleID] = active
            throw ConnectionRouteError.tunnelStopTimedOut
        }
        if active.rule.direction != .remote {
            while !LocalPortAvailability.isAvailable(
                address: active.rule.bindAddress,
                port: active.rule.listenPort,
                reuseAddress: active.rule.direction == .http
            ), Date() < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard LocalPortAvailability.isAvailable(
                address: active.rule.bindAddress,
                port: active.rule.listenPort,
                reuseAddress: active.rule.direction == .http
            ) else {
                active.snapshot.state = .failed
                active.snapshot.lastError = ConnectionRouteError.portStillInUse(
                    active.rule.listenPort
                ).localizedDescription
                tunnels[ruleID] = active
                throw ConnectionRouteError.portStillInUse(active.rule.listenPort)
            }
        }
        TemporaryKeyMaterial.cleanup(active.cleanupPaths)
        active.cleanupPaths = []
        if let marker = active.handshakeMarker {
            SSHSessionBootstrap.removeMarker(marker)
            active.handshakeMarker = nil
        }
        active.snapshot.state = .stopped
        active.snapshot.processIdentifier = nil
        tunnels[ruleID] = active
        return active.snapshot
    }

    func stopAll() async {
        let clock = ContinuousClock()
        _ = await stopAll(until: clock.now.advanced(by: .seconds(1)))
    }

    /// Stops every tunnel inside one absolute caller-owned budget. All handles
    /// receive TERM before this method waits, so a cancellation-insensitive
    /// child cannot serialize or extend shutdown.
    @discardableResult
    func stopAll(until deadline: ContinuousClock.Instant) async -> Bool {
        await stopAllOutcome(until: deadline) != .timedOut
    }

    private func stopAllOutcome(until deadline: ContinuousClock.Instant) async -> ShutdownOutcome {
        let ruleIDs = Array(tunnels.keys)
        let clock = ContinuousClock()
        for ruleID in ruleIDs {
            guard var active = tunnels[ruleID] else { continue }
            active.stopRequested = true
            active.snapshot.state = .stopping
            active.httpProxy?.stop()
            active.httpProxy = nil
            active.handle.terminate()
            tunnels[ruleID] = active
        }

        let forceAt = min(
            clock.now.advanced(by: .milliseconds(550)),
            deadline.advanced(by: .milliseconds(-250))
        )
        while hasRunningTunnel(in: ruleIDs),
              clock.now < forceAt,
              !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let forceIDs = ruleIDs.filter { tunnels[$0]?.handle.isRunning() == true }
        for ruleID in forceIDs {
            tunnels[ruleID]?.handle.kill()
        }
        while !allTunnelResourcesReleased(in: ruleIDs),
              clock.now < deadline,
              !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(20))
        }

        let stopped = allTunnelResourcesReleased(in: ruleIDs)
        for ruleID in ruleIDs {
            guard var active = tunnels[ruleID] else { continue }
            if active.handle.isRunning() {
                active.snapshot.state = .failed
                active.snapshot.lastError = ConnectionRouteError.tunnelStopTimedOut.localizedDescription
            } else if active.rule.direction != .remote,
                      !LocalPortAvailability.isAvailable(
                        address: active.rule.bindAddress,
                        port: active.rule.listenPort,
                        reuseAddress: active.rule.direction == .http
                      ) {
                active.snapshot.state = .failed
                active.snapshot.lastError = ConnectionRouteError.portStillInUse(
                    active.rule.listenPort
                ).localizedDescription
            } else {
                TemporaryKeyMaterial.cleanup(active.cleanupPaths)
                active.cleanupPaths = []
                if let marker = active.handshakeMarker {
                    SSHSessionBootstrap.removeMarker(marker)
                    active.handshakeMarker = nil
                }
                active.snapshot.state = .stopped
                active.snapshot.processIdentifier = nil
            }
            tunnels[ruleID] = active
        }
        guard stopped else { return .timedOut }
        return forceIDs.isEmpty ? .completed : .forced
    }

    /// Application shutdown closes admission before stopping the current set,
    /// preventing a reconnect or deferred UI action from racing the drain.
    func shutdownAndDrain(until deadline: ContinuousClock.Instant) async -> ShutdownOutcome {
        acceptingNewTunnels = false
        return await stopAllOutcome(until: deadline)
    }

    private func hasRunningTunnel(in ruleIDs: [UUID]) -> Bool {
        ruleIDs.contains { tunnels[$0]?.handle.isRunning() == true }
    }

    private func allTunnelResourcesReleased(in ruleIDs: [UUID]) -> Bool {
        ruleIDs.allSatisfy { ruleID in
            guard let active = tunnels[ruleID], !active.handle.isRunning() else { return false }
            guard active.rule.direction != .remote else { return true }
            return LocalPortAvailability.isAvailable(
                address: active.rule.bindAddress,
                port: active.rule.listenPort,
                reuseAddress: active.rule.direction == .http
            )
        }
    }

    func snapshot(ruleID: UUID) -> PortForwardSnapshot? {
        tunnels[ruleID]?.snapshot
    }

    func snapshots() -> [PortForwardSnapshot] {
        tunnels.values.map(\.snapshot).sorted {
            ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast)
        }
    }

    private func waitUntilReady(
        rule: PortForwardRule,
        handle: any TunnelProcessHandle,
        handshakeMarker: URL?
    ) async throws {
        let deadline = Date().addingTimeInterval(readinessTimeout)
        if rule.direction == .remote {
            guard let handshakeMarker else {
                throw ConnectionRouteError.tunnelReadinessTimedOut
            }
            while Date() < deadline {
                guard handle.isRunning() else {
                    throw ConnectionRouteError.tunnelLaunchFailed(
                        sanitized(handle.boundedErrorOutput())
                    )
                }
                if FileManager.default.fileExists(atPath: handshakeMarker.path) {
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        } else {
            while Date() < deadline {
                guard handle.isRunning() else {
                    throw ConnectionRouteError.tunnelLaunchFailed(
                        sanitized(handle.boundedErrorOutput())
                    )
                }
                if !LocalPortAvailability.isAvailable(
                    address: rule.bindAddress,
                    port: rule.listenPort
                ) {
                    return
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        throw ConnectionRouteError.tunnelReadinessTimedOut
    }

    private func monitorExit(
        ruleID: UUID,
        generation: UUID,
        handle: any TunnelProcessHandle
    ) {
        Task {
            _ = await handle.waitForExit()
            await observedExit(ruleID: ruleID, generation: generation)
        }
    }

    private func observedExit(ruleID: UUID, generation: UUID) async {
        guard var active = tunnels[ruleID], active.generation == generation else { return }
        if isStopState(active) {
            return
        }
        let error = sanitized(active.handle.boundedErrorOutput())
        active.httpProxy?.stop(); active.httpProxy = nil
        TemporaryKeyMaterial.cleanup(active.cleanupPaths)
        active.cleanupPaths = []
        if let marker = active.handshakeMarker {
            SSHSessionBootstrap.removeMarker(marker)
            active.handshakeMarker = nil
        }
        active.snapshot.lastError = error.isEmpty ? "SSH 隧道意外退出。" : error
        if active.snapshot.reconnectAttempt >= maxReconnectAttempts {
            active.snapshot.state = .failed
            active.snapshot.processIdentifier = nil
            tunnels[ruleID] = active
            return
        }
        active.snapshot.reconnectAttempt += 1
        active.snapshot.state = .reconnecting
        active.snapshot.processIdentifier = nil
        tunnels[ruleID] = active
        let delay = min(2, 0.25 * pow(2, Double(active.snapshot.reconnectAttempt - 1)))
        do {
            try await Task.sleep(for: .seconds(delay))
        } catch {
            return
        }
        guard let current = currentTunnel(ruleID: ruleID, generation: generation),
              !isStopState(current) else { return }
        var launchedHandle: (any TunnelProcessHandle)?
        var launchedGeneration: UUID?
        var launchedCleanup: [String] = []
        var launchedMarker: URL?
        do {
            if current.rule.direction != .remote,
               !LocalPortAvailability.isAvailable(
                   address: current.rule.bindAddress,
                   port: current.rule.listenPort,
                   reuseAddress: current.rule.direction == .http
               ) {
                throw ConnectionRouteError.portUnavailable(current.rule.listenPort)
            }
            var plan = try provider.launchPlan(
                for: current.config,
                purpose: .portForward(current.transportRule)
            )
            if current.transportRule.direction == .remote {
                let marker = try SSHSessionBootstrap.handshakeMarker()
                launchedMarker = marker
                plan.arguments.insert(contentsOf: SSHSessionBootstrap.markerArguments(marker), at: 0)
            }
            let nextHandle = try launcher.launch(plan)
            launchedHandle = nextHandle
            launchedCleanup = plan.cleanupPaths
            let nextGeneration = UUID()
            launchedGeneration = nextGeneration
            var latest = current
            latest.handle = nextHandle
            latest.generation = nextGeneration
            latest.cleanupPaths = plan.cleanupPaths
            latest.handshakeMarker = launchedMarker
            latest.snapshot.processIdentifier = nextHandle.processIdentifier
            tunnels[ruleID] = latest
            try await waitUntilReady(
                rule: latest.transportRule,
                handle: nextHandle,
                handshakeMarker: launchedMarker
            )
            guard let refreshed = currentTunnel(ruleID: ruleID, generation: nextGeneration) else {
                if let launchedHandle { _ = await terminateAfterFailedStart(launchedHandle) }
                TemporaryKeyMaterial.cleanup(launchedCleanup)
                if let launchedMarker { SSHSessionBootstrap.removeMarker(launchedMarker) }
                return
            }
            if isStopState(refreshed) {
                if let launchedHandle { _ = await terminateAfterFailedStart(launchedHandle) }
                TemporaryKeyMaterial.cleanup(launchedCleanup)
                if let launchedMarker { SSHSessionBootstrap.removeMarker(launchedMarker) }
                return
            }
            var ready = refreshed
            if ready.rule.direction == .http {
                let proxy = HTTPToSOCKSProxy(socksPort: ready.transportRule.listenPort)
                try proxy.start(bindAddress: ready.rule.bindAddress, port: ready.rule.listenPort)
                ready.httpProxy = proxy
            }
            ready.snapshot.state = .ready
            tunnels[ruleID] = ready
            monitorExit(ruleID: ruleID, generation: nextGeneration, handle: nextHandle)
        } catch {
            if let launchedHandle {
                _ = await terminateAfterFailedStart(launchedHandle)
            }
            TemporaryKeyMaterial.cleanup(launchedCleanup)
            if let launchedMarker { SSHSessionBootstrap.removeMarker(launchedMarker) }
            guard var latest = tunnels[ruleID], !isStopState(latest) else { return }
            let expectedGeneration = launchedGeneration ?? generation
            guard latest.generation == expectedGeneration else { return }
            latest.snapshot.lastError = error.localizedDescription
            latest.snapshot.processIdentifier = nil
            latest.cleanupPaths = []
            latest.handshakeMarker = nil
            tunnels[ruleID] = latest
            await observedExit(ruleID: ruleID, generation: latest.generation)
        }
    }

    private func currentTunnel(ruleID: UUID, generation: UUID) -> ActiveTunnel? {
        guard let active = tunnels[ruleID], active.generation == generation else { return nil }
        return active
    }

    private func isStopState(_ active: ActiveTunnel) -> Bool {
        active.stopRequested
            || active.snapshot.state == .stopping
            || active.snapshot.state == .stopped
    }

    private func terminateAfterFailedStart(
        _ handle: any TunnelProcessHandle
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(1)
        handle.terminate()
        while handle.isRunning(), Date() < deadline.addingTimeInterval(-0.45) {
            try? await Task.sleep(for: .milliseconds(25))
        }
        if handle.isRunning() {
            handle.kill()
        }
        while handle.isRunning(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return !handle.isRunning()
    }

    private func sanitized(_ value: String) -> String {
        let line = value.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return String(line.prefix(512))
    }
}

enum LocalPortAvailability {
    static func isAvailable(address: String, port: Int, reuseAddress: Bool = false) -> Bool {
        guard (1...65_535).contains(port) else { return false }
        let normalized = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.contains(":") || normalized == "::" || normalized == "[::]" {
            return canBindIPv6(address: normalized, port: port, reuseAddress: reuseAddress)
        }
        return canBindIPv4(address: normalized, port: port, reuseAddress: reuseAddress)
    }

    private static func canBindIPv4(address: String, port: Int, reuseAddress: Bool) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        if reuseAddress { var yes: Int32 = 1; _ = setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size)) }
        var socketAddress = sockaddr_in()
        socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        socketAddress.sin_family = sa_family_t(AF_INET)
        socketAddress.sin_port = in_port_t(port).bigEndian
        let value = address == "*" || address == "0.0.0.0" ? "0.0.0.0" : address
        guard inet_pton(AF_INET, value, &socketAddress.sin_addr) == 1 else { return false }
        return withUnsafePointer(to: &socketAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private static func canBindIPv6(address: String, port: Int, reuseAddress: Bool) -> Bool {
        let descriptor = socket(AF_INET6, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        if reuseAddress { var yes: Int32 = 1; _ = setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size)) }
        var socketAddress = sockaddr_in6()
        socketAddress.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        socketAddress.sin6_family = sa_family_t(AF_INET6)
        socketAddress.sin6_port = in_port_t(port).bigEndian
        let stripped = address.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard inet_pton(AF_INET6, stripped, &socketAddress.sin6_addr) == 1 else { return false }
        return withUnsafePointer(to: &socketAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0
            }
        }
    }
}
