import Foundation
import os

enum ConnectionPhase: String, Sendable {
    case idle
    case resolving
    case connecting
    case awaitingTrust
    case authenticating
    case ready
    case reconnecting
    case disconnected
    case failed
    case cancelled

    var title: String {
        switch self {
        case .idle: "尚未连接"
        case .resolving: "正在解析地址"
        case .connecting: "正在连接"
        case .awaitingTrust: "等待确认主机指纹"
        case .authenticating: "正在认证"
        case .ready: "已连接"
        case .reconnecting: "正在重连"
        case .disconnected: "已断开"
        case .failed: "连接失败"
        case .cancelled: "已取消"
        }
    }
}

enum ConnectionError: LocalizedError, Sendable, Equatable {
    case dnsFailed
    case connectionRefused
    case networkUnreachable
    case timeout
    case authenticationFailed
    case privateKeyOrPassphraseFailed
    case hostKeyChanged(oldFingerprint: String?, newFingerprint: String?)
    case hostKeyUntrusted
    case keyboardInteractiveRequired
    case remoteCommandMissing
    case incompatibleMonitor(String)
    case identityReferenceMissing
    case privateKeyMissing
    case credentialMissing
    case cancelled
    case outputLimitExceeded
    case commandFailed(String)

    var code: String {
        switch self {
        case .dnsFailed: "SSH_DNS"
        case .connectionRefused: "SSH_REFUSED"
        case .networkUnreachable: "SSH_UNREACHABLE"
        case .timeout: "SSH_TIMEOUT"
        case .authenticationFailed: "SSH_AUTH"
        case .privateKeyOrPassphraseFailed: "SSH_KEY"
        case .hostKeyChanged: "SSH_HOSTKEY_CHANGED"
        case .hostKeyUntrusted: "SSH_HOSTKEY_UNTRUSTED"
        case .keyboardInteractiveRequired: "SSH_KBDINT"
        case .remoteCommandMissing: "SSH_CMD_MISSING"
        case .incompatibleMonitor: "MON_INCOMPATIBLE"
        case .identityReferenceMissing: "CFG_IDENTITY_MISSING"
        case .privateKeyMissing: "CFG_KEY_MISSING"
        case .credentialMissing: "CRED_SECRET_MISSING"
        case .cancelled: "SSH_CANCELLED"
        case .outputLimitExceeded: "SSH_OUTPUT_LIMIT"
        case .commandFailed: "SSH_FAILED"
        }
    }

    var phase: ConnectionPhase {
        switch self {
        case .dnsFailed: .resolving
        case .connectionRefused, .networkUnreachable, .timeout: .connecting
        case .hostKeyChanged, .hostKeyUntrusted: .awaitingTrust
        case .authenticationFailed, .privateKeyOrPassphraseFailed, .keyboardInteractiveRequired:
            .authenticating
        case .identityReferenceMissing, .privateKeyMissing, .credentialMissing: .failed
        case .cancelled: .cancelled
        default: .failed
        }
    }

    var errorDescription: String? {
        switch self {
        case .dnsFailed:
            "无法解析主机名。"
        case .connectionRefused:
            "连接被拒绝，请检查地址和端口。"
        case .networkUnreachable:
            "网络不可达。"
        case .timeout:
            "连接超时。"
        case .authenticationFailed:
            "认证失败，请检查用户名或密码。"
        case .privateKeyOrPassphraseFailed:
            "私钥或口令不正确。"
        case .hostKeyChanged(let oldFingerprint, let newFingerprint):
            "主机密钥已变化，可能存在中间人风险。旧指纹：\(oldFingerprint ?? "未知")；新指纹：\(newFingerprint ?? "未知")。"
        case .hostKeyUntrusted:
            "尚未信任该主机指纹。"
        case .keyboardInteractiveRequired:
            "此服务器需要交互式二次验证，无法进行无人值守监控。"
        case .remoteCommandMissing:
            "远程命令不存在或不可执行。"
        case .incompatibleMonitor(let detail):
            detail.isEmpty ? "当前主机不支持监控采集。" : detail
        case .identityReferenceMissing:
            "连接引用的共享身份已不存在，请重新选择身份后再连接。"
        case .privateKeyMissing:
            "连接需要 SSH 私钥，但私钥引用或文件路径缺失。"
        case .credentialMissing:
            "连接需要的本地凭据缺失，请重新保存凭据。"
        case .cancelled:
            "连接已取消。"
        case .outputLimitExceeded:
            "远程输出超过上限，已终止采集。"
        case .commandFailed(let message):
            message.isEmpty ? "SSH 命令失败。" : message
        }
    }

    static func classify(
        _ text: String,
        fallback: String = "",
        host: String? = nil,
        port: Int? = nil
    ) -> ConnectionError {
        let lowered = text.lowercased()
        if lowered.contains("could not resolve hostname") || lowered.contains("nodename nor servname") {
            return .dnsFailed
        }
        if lowered.contains("connection refused") {
            return .connectionRefused
        }
        if lowered.contains("network is unreachable") || lowered.contains("no route to host") {
            return .networkUnreachable
        }
        if lowered.contains("operation timed out") || lowered.contains("connection timed out") {
            return .timeout
        }
        if lowered.contains("remote host identification has changed") ||
            (lowered.contains("host key") && lowered.contains("has changed")) {
            let oldFingerprint = host.flatMap {
                TrustedHostStore.existingFingerprint(host: $0, port: port ?? 22)
            }
            return .hostKeyChanged(
                oldFingerprint: oldFingerprint,
                newFingerprint: extractedFingerprint(from: text)
            )
        }
        if lowered.contains("host key verification failed") {
            if let host {
                let resolvedPort = port ?? 22
                let existing = TrustedHostStore.existingFingerprint(host: host, port: resolvedPort)
                if let existing {
                    let newFingerprint = extractedFingerprint(from: text)
                    if newFingerprint == existing {
                        return .commandFailed(
                            "主机指纹一致，但 OpenSSH 无法读取应用信任文件。"
                        )
                    }
                    return .hostKeyChanged(
                        oldFingerprint: existing,
                        newFingerprint: newFingerprint
                    )
                }
            }
            return .hostKeyUntrusted
        }
        if lowered.contains("passphrase") || lowered.contains("unprotected private key") {
            return .privateKeyOrPassphraseFailed
        }
        if lowered.contains("permission denied") {
            return .authenticationFailed
        }
        if lowered.contains("keyboard-interactive") {
            return .keyboardInteractiveRequired
        }
        if lowered.contains("not found") && lowered.contains("command") {
            return .remoteCommandMissing
        }
        return .commandFailed(text.isEmpty ? fallback : text)
    }

    static func extractedFingerprint(from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"SHA256:[A-Za-z0-9+/=]+"#) else {
            return nil
        }
        func firstMatch(in value: String) -> String? {
            let nsValue = value as NSString
            guard let match = regex.firstMatch(
                in: value,
                range: NSRange(location: 0, length: nsValue.length)
            ) else {
                return nil
            }
            return nsValue.substring(with: match.range)
        }
        if let marker = text.range(of: "sent by the remote host", options: .caseInsensitive) {
            if let fingerprint = firstMatch(in: String(text[marker.upperBound...])) {
                return fingerprint
            }
        }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        return matches.last.map { nsText.substring(with: $0.range) }
    }
}

struct ProcessRunRequest: Sendable {
    let executable: String
    let arguments: [String]
    let environment: [String: String]
    var stdin: Data?
    var connectTimeout: TimeInterval
    var totalTimeout: TimeInterval
    var maxOutputBytes: Int
    var serverID: UUID?
    var module: DiagnosticModule
    var host: String?
    var port: Int?

    init(
        executable: String,
        arguments: [String],
        environment: [String: String],
        stdin: Data? = nil,
        connectTimeout: TimeInterval = 8,
        totalTimeout: TimeInterval = 45,
        maxOutputBytes: Int = 2_000_000,
        serverID: UUID? = nil,
        module: DiagnosticModule = .ssh,
        host: String? = nil,
        port: Int? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.stdin = stdin
        self.connectTimeout = connectTimeout
        self.totalTimeout = totalTimeout
        self.maxOutputBytes = maxOutputBytes
        self.serverID = serverID
        self.module = module
        self.host = host
        self.port = port
    }
}

struct ProcessRunResult: Sendable {
    let status: Int32
    let output: String
    let error: String
    let elapsed: TimeInterval
}

enum ProcessTerminationReason: String, Sendable, Equatable {
    case running
    case exited
    case cancelled
    case timeout
    case outputLimitExceeded
    case scopedTermination
}

struct ProcessRunSummary: Sendable, Equatable {
    let runID: UUID
    let serverID: UUID?
    let module: DiagnosticModule
    let processIdentifier: Int32
    let processGroupIdentifier: Int32?
    let startedAt: Date
    var terminationReason: ProcessTerminationReason
}

actor ConnectionLimiter {
    static let shared = ConnectionLimiter()

    private struct Waiter {
        let id: UUID
        let serverID: UUID?
        let continuation: CheckedContinuation<Void, Error>
    }

    private var globalCount = 0
    private var perServer: [UUID: Int] = [:]
    private var waiters: [Waiter] = []
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingWaiterIDs: Set<UUID> = []
    private var cancelledWaiterIDs: Set<UUID> = []
    private let maxGlobal: Int
    private let maxPerServer: Int
    private let waitTimeout: TimeInterval

    init(maxGlobal: Int = 6, maxPerServer: Int = 2, waitTimeout: TimeInterval = 20) {
        self.maxGlobal = max(1, maxGlobal)
        self.maxPerServer = max(1, maxPerServer)
        self.waitTimeout = max(0.1, waitTimeout)
    }

    func acquire(serverID: UUID?) async throws {
        let interval = PerformanceTrace.begin(.processQueueWait)
        defer { PerformanceTrace.end(interval) }

        try Task.checkCancellation()
        if waiters.isEmpty, canAcquire(serverID: serverID) {
            grant(serverID: serverID)
            return
        }

        let waiterID = UUID()
        let timeout = waitTimeout
        pendingWaiterIDs.insert(waiterID)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                pendingWaiterIDs.remove(waiterID)
                if cancelledWaiterIDs.remove(waiterID) != nil {
                    continuation.resume(throwing: ConnectionError.cancelled)
                    return
                }
                waiters.append(
                    Waiter(id: waiterID, serverID: serverID, continuation: continuation)
                )
                timeoutTasks[waiterID] = Task { [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(timeout))
                    } catch {
                        return
                    }
                    await self?.expire(waiterID: waiterID)
                }
                drainWaiters()
            }
        } onCancel: {
            Task { await self.cancel(waiterID: waiterID) }
        }
    }

    func release(serverID: UUID?) {
        globalCount = max(0, globalCount - 1)
        if let serverID {
            let next = max(0, (perServer[serverID] ?? 1) - 1)
            if next == 0 {
                perServer.removeValue(forKey: serverID)
            } else {
                perServer[serverID] = next
            }
        }
        drainWaiters()
    }

    func waitingCount() -> Int {
        waiters.count
    }

    private func canAcquire(serverID: UUID?) -> Bool {
        let serverCount = serverID.flatMap { perServer[$0] } ?? 0
        return globalCount < maxGlobal && serverCount < maxPerServer
    }

    private func grant(serverID: UUID?) {
        globalCount += 1
        if let serverID {
            perServer[serverID, default: 0] += 1
        }
    }

    private func drainWaiters() {
        while let waiter = waiters.first, canAcquire(serverID: waiter.serverID) {
            waiters.removeFirst()
            timeoutTasks.removeValue(forKey: waiter.id)?.cancel()
            grant(serverID: waiter.serverID)
            waiter.continuation.resume()
        }
    }

    private func cancel(waiterID: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else {
            if pendingWaiterIDs.contains(waiterID) {
                cancelledWaiterIDs.insert(waiterID)
            }
            return
        }
        let waiter = waiters.remove(at: index)
        timeoutTasks.removeValue(forKey: waiterID)?.cancel()
        waiter.continuation.resume(throwing: ConnectionError.cancelled)
        drainWaiters()
    }

    private func expire(waiterID: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else { return }
        let waiter = waiters.remove(at: index)
        timeoutTasks[waiterID] = nil
        waiter.continuation.resume(throwing: ConnectionError.timeout)
        drainWaiters()
    }
}

actor ConnectionProcessController {
    static let shared = ConnectionProcessController()

    private struct ActiveProcess {
        let process: Process
        var summary: ProcessRunSummary
    }

    private var processes: [UUID: ActiveProcess] = [:]
    private var recentRuns: [ProcessRunSummary] = []
    private var cancellationIntervals: [UUID: PerformanceInterval] = [:]
    private var escalationTasks: [UUID: Task<Void, Never>] = [:]
    private let limiter: ConnectionLimiter
    private let terminationGrace: TimeInterval

    init(
        limiter: ConnectionLimiter = .shared,
        terminationGrace: TimeInterval = 1
    ) {
        self.limiter = limiter
        self.terminationGrace = max(0.1, terminationGrace)
    }

    func run(_ request: ProcessRunRequest) async throws -> ProcessRunResult {
        let interval = PerformanceTrace.begin(.processRun)
        defer { PerformanceTrace.end(interval) }
        guard !Task.isCancelled else { throw ConnectionError.cancelled }
        do {
            try await limiter.acquire(serverID: request.serverID)
        } catch is CancellationError {
            throw ConnectionError.cancelled
        }

        let runID = UUID()
        let started = Date()
        DiagnosticLog.logger(for: request.module).debug(
            "启动子进程，参数 \(request.arguments.count, privacy: .public) 个"
        )

        do {
            let result = try await withTaskCancellationHandler {
                try await execute(request, runID: runID, started: started)
            } onCancel: {
                Task { await self.requestTermination(runID: runID, reason: .cancelled) }
            }
            await limiter.release(serverID: request.serverID)
            return result
        } catch {
            await limiter.release(serverID: request.serverID)
            throw error
        }
    }

    func terminate(runID: UUID, escalate: Bool) {
        requestTermination(runID: runID, reason: .cancelled)
        _ = escalate
    }

    func terminateAll(for serverID: UUID? = nil) {
        let runIDs = processes.compactMap { runID, active in
            serverID == nil || active.summary.serverID == serverID ? runID : nil
        }
        for runID in runIDs {
            requestTermination(runID: runID, reason: .scopedTermination)
        }
    }

    func activeProcessSummaries() -> [ProcessRunSummary] {
        processes.values
            .map(\.summary)
            .sorted { $0.startedAt < $1.startedAt }
    }

    func activeProcessCount(for serverID: UUID? = nil) -> Int {
        guard let serverID else { return processes.count }
        return processes.values.count { $0.summary.serverID == serverID }
    }

    func recentProcessSummaries() -> [ProcessRunSummary] {
        recentRuns
    }

    private func execute(
        _ request: ProcessRunRequest,
        runID: UUID,
        started: Date
    ) async throws -> ProcessRunResult {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let inputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: request.executable)
        process.arguments = request.arguments
        process.environment = request.environment
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = inputPipe

        do {
            try process.run()
        } catch {
            throw ConnectionError.commandFailed(error.localizedDescription)
        }
        let processID = process.processIdentifier
        let rawProcessGroupID = getpgid(processID)
        let processGroupID = rawProcessGroupID == processID ? rawProcessGroupID : nil
        processes[runID] = ActiveProcess(
            process: process,
            summary: ProcessRunSummary(
                runID: runID,
                serverID: request.serverID,
                module: request.module,
                processIdentifier: processID,
                processGroupIdentifier: processGroupID,
                startedAt: started,
                terminationReason: .running
            )
        )

        if let stdin = request.stdin {
            try? inputPipe.fileHandleForWriting.write(contentsOf: stdin)
        }
        try? inputPipe.fileHandleForWriting.close()

        let controller = self
        let outputTask = Task.detached(priority: .utility) {
            try Self.readCapped(
                outputPipe.fileHandleForReading,
                limit: request.maxOutputBytes,
                onLimit: {
                    Task {
                        await controller.requestTermination(
                            runID: runID,
                            reason: .outputLimitExceeded
                        )
                    }
                }
            )
        }
        let errorTask = Task.detached(priority: .utility) {
            try Self.readCapped(
                errorPipe.fileHandleForReading,
                limit: min(request.maxOutputBytes, 128_000),
                onLimit: {
                    Task {
                        await controller.requestTermination(
                            runID: runID,
                            reason: .outputLimitExceeded
                        )
                    }
                }
            )
        }

        let timeoutTask = Task.detached(priority: .utility) { [weak self] in
            do {
                try await Task.sleep(for: .seconds(request.totalTimeout))
            } catch {
                return
            }
            await self?.requestTermination(runID: runID, reason: .timeout)
        }

        await waitForExit(process)
        timeoutTask.cancel()
        if let cancellationInterval = cancellationIntervals.removeValue(forKey: runID) {
            PerformanceTrace.end(cancellationInterval)
        }

        var output = Data()
        var errorData = Data()
        var readFailure: Error?
        do {
            output = try await outputTask.value
        } catch {
            readFailure = error
        }
        do {
            errorData = try await errorTask.value
        } catch {
            if readFailure == nil {
                readFailure = error
            }
        }

        try? outputPipe.fileHandleForReading.close()
        try? errorPipe.fileHandleForReading.close()

        var terminationReason = processes[runID]?.summary.terminationReason ?? .exited
        if terminationReason == .running {
            terminationReason = .exited
        }
        if (readFailure as? ConnectionError) == .outputLimitExceeded {
            terminationReason = .outputLimitExceeded
        } else if Task.isCancelled, terminationReason == .exited {
            terminationReason = .cancelled
        }
        if var summary = processes[runID]?.summary {
            summary.terminationReason = terminationReason
            recentRuns.append(summary)
            recentRuns = Array(recentRuns.suffix(100))
        }
        processes[runID] = nil
        escalationTasks.removeValue(forKey: runID)?.cancel()

        let outputText = String(decoding: output, as: UTF8.self)
        let errorText = String(decoding: errorData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let elapsed = Date().timeIntervalSince(started)

        switch terminationReason {
        case .timeout:
            throw ConnectionError.timeout
        case .outputLimitExceeded:
            throw ConnectionError.outputLimitExceeded
        case .cancelled, .scopedTermination:
            throw ConnectionError.cancelled
        case .running, .exited:
            break
        }
        if let connectionError = readFailure as? ConnectionError {
            throw connectionError
        }
        if readFailure is CancellationError || Task.isCancelled {
            throw ConnectionError.cancelled
        }
        if let readFailure {
            throw ConnectionError.commandFailed(readFailure.localizedDescription)
        }
        if process.terminationStatus != 0 {
            throw ConnectionError.classify(
                errorText + "\n" + outputText,
                host: request.host,
                port: request.port
            )
        }
        return ProcessRunResult(
            status: process.terminationStatus,
            output: outputText,
            error: errorText,
            elapsed: elapsed
        )
    }

    private func requestTermination(runID: UUID, reason: ProcessTerminationReason) {
        guard var active = processes[runID] else { return }
        if active.summary.terminationReason == .running {
            active.summary.terminationReason = reason
            processes[runID] = active
        }
        if cancellationIntervals[runID] == nil {
            cancellationIntervals[runID] = PerformanceTrace.begin(.processCancelToExit)
        }
        send(signal: SIGTERM, to: active)
        guard escalationTasks[runID] == nil else { return }
        let grace = terminationGrace
        escalationTasks[runID] = Task.detached(priority: .utility) { [weak self] in
            do {
                try await Task.sleep(for: .seconds(grace))
            } catch {
                return
            }
            await self?.forceKill(runID: runID)
        }
    }

    private func forceKill(runID: UUID) {
        guard let active = processes[runID] else { return }
        send(signal: SIGKILL, to: active)
    }

    private func send(signal: Int32, to active: ActiveProcess) {
        if let groupID = active.summary.processGroupIdentifier,
           kill(-groupID, signal) == 0 {
            return
        }
        if active.process.isRunning {
            _ = kill(active.summary.processIdentifier, signal)
        }
    }

    private func waitForExit(_ process: Process) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let lock = NSLock()
            var resumed = false
            let resumeOnce = {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                continuation.resume()
            }
            process.terminationHandler = { _ in resumeOnce() }
            if !process.isRunning {
                resumeOnce()
            }
        }
    }

    private static func readCapped(
        _ handle: FileHandle,
        limit: Int,
        chunkSize: Int = 32_768,
        onLimit: @escaping @Sendable () -> Void
    ) throws -> Data {
        let resolvedLimit = max(0, limit)
        let resolvedChunkSize = min(65_536, max(16_384, chunkSize))
        var data = Data()
        data.reserveCapacity(min(resolvedLimit, resolvedChunkSize * 2))
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: resolvedChunkSize), !chunk.isEmpty else {
                return data
            }
            let remaining = max(0, resolvedLimit - data.count)
            guard chunk.count <= remaining else {
                onLimit()
                throw ConnectionError.outputLimitExceeded
            }
            data.append(chunk)
        }
    }
}

enum SSHConnectionTester {
    static func test(_ config: ServerConnectionConfig) async throws -> TimeInterval {
        let interval = PerformanceTrace.begin(.sshHandshake)
        defer { PerformanceTrace.end(interval) }
        let started = Date()
        let result = try await ConnectionProcessController.shared.run(
            ProcessRunRequest(
                executable: "/usr/bin/ssh",
                arguments: SSHSupport.arguments(
                    for: config,
                    strictHostChecking: "yes",
                    batchMode: config.authentication != .password,
                    remoteCommand: "printf serverdash-ok"
                ),
                environment: SSHSupport.environment(for: config),
                connectTimeout: config.connectTimeout,
                totalTimeout: max(12, config.connectTimeout + 8),
                maxOutputBytes: 4_096,
                serverID: config.id,
                module: .ssh,
                host: config.host,
                port: config.port
            )
        )
        guard result.output.contains("serverdash-ok") else {
            throw ConnectionError.commandFailed(result.error)
        }
        EventLogStore.shared.append(
            serverID: config.id,
            module: .ssh,
            message: "SSH 测试成功"
        )
        return Date().timeIntervalSince(started)
    }
}
