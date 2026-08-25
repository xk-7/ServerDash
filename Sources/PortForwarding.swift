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
            let lock = NSLock()
            var resumed = false
            let resumeOnce = { [process] in
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: process.terminationStatus)
            }
            process.terminationHandler = { _ in resumeOnce() }
            if !process.isRunning { resumeOnce() }
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
    }

    private let provider: any ConnectionProvider
    private let launcher: any TunnelProcessLaunching
    private let maxReconnectAttempts: Int
    private let readinessTimeout: TimeInterval
    private var tunnels: [UUID: ActiveTunnel] = [:]

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
           !LocalPortAvailability.isAvailable(address: rule.bindAddress, port: rule.listenPort) {
            throw ConnectionRouteError.portUnavailable(rule.listenPort)
        }
        let plan = try provider.launchPlan(for: config, purpose: .portForward(rule))
        let handle = try launcher.launch(plan)
        let generation = UUID()
        var active = ActiveTunnel(
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
            stopRequested: false
        )
        tunnels[rule.id] = active
        do {
            try await waitUntilReady(rule: rule, handle: handle)
            active.snapshot.state = .ready
            tunnels[rule.id] = active
            monitorExit(ruleID: rule.id, generation: generation, handle: handle)
            return active.snapshot
        } catch {
            let stopped = await terminateAfterFailedStart(handle)
            active.snapshot.state = .failed
            active.snapshot.processIdentifier = stopped ? nil : handle.processIdentifier
            active.snapshot.lastError = stopped
                ? error.localizedDescription
                : ConnectionRouteError.tunnelStopTimedOut.localizedDescription
            tunnels[rule.id] = active
            throw error
        }
    }

    func stop(ruleID: UUID) async throws -> PortForwardSnapshot? {
        guard var active = tunnels[ruleID] else { return nil }
        active.stopRequested = true
        active.snapshot.state = .stopping
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
                port: active.rule.listenPort
            ), Date() < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard LocalPortAvailability.isAvailable(
                address: active.rule.bindAddress,
                port: active.rule.listenPort
            ) else {
                active.snapshot.state = .failed
                active.snapshot.lastError = ConnectionRouteError.portStillInUse(
                    active.rule.listenPort
                ).localizedDescription
                tunnels[ruleID] = active
                throw ConnectionRouteError.portStillInUse(active.rule.listenPort)
            }
        }
        active.snapshot.state = .stopped
        active.snapshot.processIdentifier = nil
        tunnels[ruleID] = active
        return active.snapshot
    }

    func stopAll() async {
        let ruleIDs = Array(tunnels.keys)
        await withTaskGroup(of: Void.self) { group in
            for ruleID in ruleIDs {
                group.addTask { [weak self] in
                    _ = try? await self?.stop(ruleID: ruleID)
                }
            }
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
        handle: any TunnelProcessHandle
    ) async throws {
        let deadline = Date().addingTimeInterval(readinessTimeout)
        if rule.direction == .remote {
            while Date() < deadline {
                guard handle.isRunning() else {
                    throw ConnectionRouteError.tunnelLaunchFailed(
                        sanitized(handle.boundedErrorOutput())
                    )
                }
                try? await Task.sleep(for: .milliseconds(50))
                if Date().timeIntervalSince(deadline) > -max(0.2, readinessTimeout - 0.2) {
                    return
                }
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
        if active.stopRequested || active.snapshot.state == .stopping ||
            active.snapshot.state == .stopped {
            return
        }
        let error = sanitized(active.handle.boundedErrorOutput())
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
        guard var latest = tunnels[ruleID], !latest.stopRequested,
              latest.generation == generation else { return }
        var launchedHandle: (any TunnelProcessHandle)?
        do {
            if latest.rule.direction != .remote,
               !LocalPortAvailability.isAvailable(
                   address: latest.rule.bindAddress,
                   port: latest.rule.listenPort
               ) {
                throw ConnectionRouteError.portUnavailable(latest.rule.listenPort)
            }
            let plan = try provider.launchPlan(
                for: latest.config,
                purpose: .portForward(latest.rule)
            )
            let nextHandle = try launcher.launch(plan)
            launchedHandle = nextHandle
            let nextGeneration = UUID()
            latest.handle = nextHandle
            latest.generation = nextGeneration
            latest.snapshot.processIdentifier = nextHandle.processIdentifier
            tunnels[ruleID] = latest
            try await waitUntilReady(rule: latest.rule, handle: nextHandle)
            latest.snapshot.state = .ready
            tunnels[ruleID] = latest
            monitorExit(ruleID: ruleID, generation: nextGeneration, handle: nextHandle)
        } catch {
            if let launchedHandle {
                _ = await terminateAfterFailedStart(launchedHandle)
            }
            latest.snapshot.lastError = error.localizedDescription
            latest.snapshot.processIdentifier = nil
            tunnels[ruleID] = latest
            await observedExit(ruleID: ruleID, generation: latest.generation)
        }
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
    static func isAvailable(address: String, port: Int) -> Bool {
        guard (1...65_535).contains(port) else { return false }
        let normalized = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.contains(":") || normalized == "::" || normalized == "[::]" {
            return canBindIPv6(address: normalized, port: port)
        }
        return canBindIPv4(address: normalized, port: port)
    }

    private static func canBindIPv4(address: String, port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
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

    private static func canBindIPv6(address: String, port: Int) -> Bool {
        let descriptor = socket(AF_INET6, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
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
