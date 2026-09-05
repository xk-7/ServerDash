#if os(macOS)
import Foundation

struct OpenSSHRemoteConnectionEngine: RemoteConnectionEngine {
    let capabilities = PlatformCapabilities.macOS

    func connect(
        _ config: ServerConnectionConfig,
        trustHandler: @escaping RemoteHostTrustHandler
    ) async throws -> any RemoteSession {
        // Existing macOS entry points authorize every route hop through
        // HostTrustCoordinator before constructing this adapter. The generated
        // OpenSSH plans still enforce StrictHostKeyChecking=yes against the
        // app-owned known_hosts file, so this compatibility wrapper cannot
        // silently accept an unknown key.
        _ = trustHandler
        _ = try ConnectionEndpoint(
            host: config.host,
            port: config.port,
            username: config.username
        ).validated(label: "目标服务器")
        return OpenSSHRemoteSession(config: config)
    }
}

private struct OpenSSHRemoteSession: RemoteSession {
    let config: ServerConnectionConfig

    func execute(
        _ command: String,
        timeout: TimeInterval,
        maxOutputBytes: Int
    ) async throws -> RemoteCommandResult {
        let plan = try SystemOpenSSHConnectionProvider().launchPlan(
            for: config,
            purpose: .remoteCommand(command)
        )
        let result = try await ConnectionProcessController.shared.run(
            ProcessRunRequest(
                executable: plan.executable,
                arguments: plan.arguments,
                environment: plan.environment,
                connectTimeout: config.connectTimeout,
                totalTimeout: timeout,
                maxOutputBytes: maxOutputBytes,
                serverID: config.id,
                module: .ssh,
                host: config.host,
                port: config.port
            )
        )
        return RemoteCommandResult(
            stdout: Data(result.output.utf8),
            stderr: Data(result.error.utf8),
            exitCode: Int(result.status)
        )
    }

    func openShell(
        dimensions: RemoteShellDimensions
    ) async throws -> any RemoteShellSession {
        let plan = try SystemOpenSSHConnectionProvider().launchPlan(
            for: config,
            purpose: .interactiveShell
        )
        return try OpenSSHRemoteShellSession(plan: plan, dimensions: dimensions)
    }

    func openSFTP() async throws -> any RemoteFileClient {
        OpenSSHRemoteFileClient(config: config)
    }

    func close() async {}
}

private final class OpenSSHRemoteShellSession: RemoteShellSession, @unchecked Sendable {
    let events: AsyncThrowingStream<Data, Error>

    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let lock = NSLock()
    private var closed = false

    init(plan: OpenSSHLaunchPlan, dimensions: RemoteShellDimensions) throws {
        _ = dimensions
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        events = pair.stream
        continuation = pair.continuation

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: plan.executable)
        process.arguments = ["-tt"] + plan.arguments
        process.environment = plan.environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        self.process = process
        input = inputPipe.fileHandleForWriting
        output = outputPipe.fileHandleForReading

        output.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.continuation.yield(data)
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.output.readabilityHandler = nil
            if process.terminationStatus == 0 {
                self.continuation.finish()
            } else {
                self.continuation.finish(
                    throwing: RemoteConnectionFailure.transport(
                        "SSH 终端已退出（\(process.terminationStatus)）。"
                    )
                )
            }
        }
        do {
            try process.run()
        } catch {
            output.readabilityHandler = nil
            continuation.finish(throwing: error)
            throw error
        }
    }

    func write(_ data: Data) async throws {
        let isClosed = lock.withLock { closed }
        guard !isClosed else { throw RemoteConnectionFailure.sessionClosed }
        try input.write(contentsOf: data)
    }

    func resize(_ dimensions: RemoteShellDimensions) async throws {
        _ = dimensions
        // The existing SwiftTerm LocalProcess bridge owns PTY resizing on macOS.
    }

    func close() async {
        let shouldClose = lock.withLock {
            guard !closed else { return false }
            closed = true
            return true
        }
        guard shouldClose else { return }
        output.readabilityHandler = nil
        try? input.close()
        if process.isRunning { process.terminate() }
        continuation.finish()
    }
}

private struct OpenSSHRemoteFileClient: RemoteFileClient {
    let config: ServerConnectionConfig

    func list(path: String) async throws -> SFTPDirectoryListing {
        try await SFTPService.list(config: config, path: path)
    }

    func createDirectory(named name: String, in path: String) async throws {
        try await SFTPService.createDirectory(named: name, in: path, config: config)
    }

    func createFile(named name: String, in path: String) async throws {
        try await SFTPService.createFile(named: name, in: path, config: config)
    }

    func rename(_ item: RemoteFileItem, to newName: String) async throws {
        try await SFTPService.rename(item: item, to: newName, config: config)
    }

    func move(_ item: RemoteFileItem, to directory: String) async throws {
        try await SFTPService.move(item: item, to: directory, config: config)
    }

    func delete(_ item: RemoteFileItem, recursive: Bool) async throws {
        try await SFTPService.delete(item: item, config: config, recursive: recursive)
    }

    func upload(
        localURL: URL,
        to remotePath: String,
        onProgress: (@Sendable (SFTPProgress) -> Void)?
    ) async throws {
        try await SFTPService.upload(
            localURLs: [localURL],
            to: RemotePath.parent(of: remotePath),
            config: config,
            policy: .overwrite,
            existingNames: [],
            onProgress: onProgress
        )
    }

    func download(
        remotePath: String,
        size: Int64,
        to localURL: URL,
        onProgress: (@Sendable (SFTPProgress) -> Void)?
    ) async throws {
        let item = RemoteFileItem(
            path: remotePath,
            name: URL(fileURLWithPath: remotePath).lastPathComponent,
            kind: .file,
            size: size,
            permissions: "",
            owner: "",
            group: "",
            modifiedText: ""
        )
        try await SFTPService.download(
            item: item,
            to: localURL,
            config: config,
            policy: .overwrite,
            onProgress: onProgress
        )
    }

    func cancelCurrentOperation() async {
        // SFTPService operations inherit structured task cancellation and its
        // process controller performs TERM/KILL escalation for the owned process.
    }

    func close() async {}
}
#endif
