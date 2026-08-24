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
            let parsed = extractedFingerprint(from: text)
            if parsed == nil, let host, let probe = try? TrustedHostStore.scan(host: host, port: port ?? 22) {
                return .hostKeyChanged(oldFingerprint: oldFingerprint, newFingerprint: probe.fingerprint)
            }
            return .hostKeyChanged(oldFingerprint: oldFingerprint, newFingerprint: parsed)
        }
        if lowered.contains("host key verification failed") {
            if let host {
                let resolvedPort = port ?? 22
                let existing = TrustedHostStore.existingFingerprint(host: host, port: resolvedPort)
                if let existing {
                    let newFingerprint = extractedFingerprint(from: text)
                        ?? (try? TrustedHostStore.scan(
                            host: host,
                            port: resolvedPort,
                            preferredAlgorithm: TrustedHostStore.existingKeys(
                                host: host,
                                port: resolvedPort
                            ).first?.algorithm
                        ).fingerprint)
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

actor ConnectionLimiter {
    static let shared = ConnectionLimiter()

    private var globalCount = 0
    private var perServer: [UUID: Int] = [:]
    private let maxGlobal = 6
    private let maxPerServer = 2

    func acquire(serverID: UUID?) async throws {
        let started = Date()
        while !Task.isCancelled {
            let serverCount = serverID.flatMap { perServer[$0] } ?? 0
            if globalCount < maxGlobal, serverCount < maxPerServer {
                globalCount += 1
                if let serverID {
                    perServer[serverID, default: 0] += 1
                }
                return
            }
            if Date().timeIntervalSince(started) > 20 {
                throw ConnectionError.timeout
            }
            try await Task.sleep(for: .milliseconds(120))
        }
        throw ConnectionError.cancelled
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
    }
}

actor ConnectionProcessController {
    static let shared = ConnectionProcessController()

    private var processes: [UUID: Process] = [:]

    func run(_ request: ProcessRunRequest) async throws -> ProcessRunResult {
        try Task.checkCancellation()
        try await ConnectionLimiter.shared.acquire(serverID: request.serverID)
        defer {
            Task { await ConnectionLimiter.shared.release(serverID: request.serverID) }
        }

        let runID = UUID()
        let started = Date()
        DiagnosticLog.logger(for: request.module).debug(
            "启动 \(request.executable, privacy: .public) 参数 \(request.arguments.count, privacy: .public) 个"
        )

        return try await withTaskCancellationHandler {
            try await execute(request, runID: runID, started: started)
        } onCancel: {
            Task { await self.terminate(runID: runID, escalate: false) }
        }
    }

    func terminate(runID: UUID, escalate: Bool) {
        guard let process = processes[runID], process.isRunning else {
            processes[runID] = nil
            return
        }
        process.terminate()
        if escalate {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }
    }

    func terminateAll(for serverID: UUID? = nil) {
        for (id, process) in processes {
            if process.isRunning {
                process.terminate()
            }
            processes[id] = nil
        }
        _ = serverID
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
        processes[runID] = process

        if let stdin = request.stdin {
            try? inputPipe.fileHandleForWriting.write(contentsOf: stdin)
        }
        try? inputPipe.fileHandleForWriting.close()

        let outputTask = Task.detached(priority: .utility) {
            try Self.readCapped(
                outputPipe.fileHandleForReading,
                limit: request.maxOutputBytes
            )
        }
        let errorTask = Task.detached(priority: .utility) {
            try Self.readCapped(
                errorPipe.fileHandleForReading,
                limit: min(request.maxOutputBytes, 256_000)
            )
        }

        let timeoutTask = Task {
            try await Task.sleep(for: .seconds(request.totalTimeout))
            await self.terminate(runID: runID, escalate: true)
        }

        await waitForExit(process)
        timeoutTask.cancel()
        processes[runID] = nil

        let output: Data
        let errorData: Data
        do {
            output = try await outputTask.value
            errorData = try await errorTask.value
        } catch is CancellationError {
            throw ConnectionError.cancelled
        } catch {
            process.terminate()
            throw error
        }

        try? outputPipe.fileHandleForReading.close()
        try? errorPipe.fileHandleForReading.close()

        if Task.isCancelled {
            throw ConnectionError.cancelled
        }

        let outputText = String(decoding: output, as: UTF8.self)
        let errorText = String(decoding: errorData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let elapsed = Date().timeIntervalSince(started)

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

    private static func readCapped(_ handle: FileHandle, limit: Int) throws -> Data {
        let data = handle.readDataToEndOfFile()
        if data.count > limit {
            throw ConnectionError.outputLimitExceeded
        }
        return data
    }
}

enum SSHConnectionTester {
    static func test(_ config: ServerConnectionConfig) async throws -> TimeInterval {
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
