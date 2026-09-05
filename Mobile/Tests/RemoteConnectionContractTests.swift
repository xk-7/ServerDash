import Foundation
import XCTest

@testable import ServerDashMobile

final class RemoteConnectionContractTests: XCTestCase {
    func testSessionContractCarriesCommandShellAndFileOperations() async throws {
        let shell = ContractShell()
        let files = ContractFileClient()
        let session = ContractSession(shell: shell, files: files)
        let engine = ContractEngine(session: session)
        let config = Self.makeConfig()

        let connected = try await engine.connect(config) { presentation in
            XCTAssertEqual(presentation.host, config.host)
            return .trustOnce
        }
        let result = try await connected.execute(
            "printf contract",
            timeout: 2,
            maxOutputBytes: 1_024
        )
        XCTAssertEqual(result.output, "contract")
        XCTAssertEqual(result.exitCode, 0)

        let remoteShell = try await connected.openShell(
            dimensions: RemoteShellDimensions(columns: 100, rows: 40, pixelWidth: 800, pixelHeight: 600)
        )
        try await remoteShell.write(Data("whoami\n".utf8))
        try await remoteShell.resize(.standard)
        await remoteShell.close()

        let remoteFiles = try await connected.openSFTP()
        let listing = try await remoteFiles.list(path: "/srv")
        XCTAssertEqual(listing.path, "/srv")
        await remoteFiles.cancelCurrentOperation()
        await remoteFiles.close()
        await connected.close()

        let writtenData = await shell.writtenData()
        let lastDimensions = await shell.lastDimensions()
        let shellClosed = await shell.isClosed()
        let fileOperationCancelled = await files.wasCancelled()
        let filesClosed = await files.isClosed()
        let sessionClosed = await session.isClosed()
        XCTAssertEqual(writtenData, Data("whoami\n".utf8))
        XCTAssertEqual(lastDimensions, .standard)
        XCTAssertTrue(shellClosed)
        XCTAssertTrue(fileOperationCancelled)
        XCTAssertTrue(filesClosed)
        XCTAssertTrue(sessionClosed)
    }

    static func makeConfig(id: UUID = UUID()) -> ServerConnectionConfig {
        ServerConnectionConfig(
            id: id,
            credentialID: id,
            name: "Contract host",
            host: "contract.example.test",
            port: 22,
            username: "tester",
            authentication: .password,
            privateKeyPath: ""
        )
    }
}

private struct ContractEngine: RemoteConnectionEngine {
    let capabilities = PlatformCapabilities.mobile
    let session: ContractSession

    func connect(
        _ config: ServerConnectionConfig,
        trustHandler: @escaping RemoteHostTrustHandler
    ) async throws -> any RemoteSession {
        let decision = try await trustHandler(
            RemoteHostKeyPresentation(
                host: config.host,
                port: config.port,
                algorithm: "ssh-ed25519",
                keyBlob: Data("contract-host-key".utf8)
            )
        )
        guard decision != .reject else { throw RemoteConnectionFailure.hostKeyRejected }
        return session
    }
}

private actor ContractSession: RemoteSession {
    let shell: ContractShell
    let files: ContractFileClient
    private var closed = false

    init(shell: ContractShell, files: ContractFileClient) {
        self.shell = shell
        self.files = files
    }

    func execute(
        _ command: String,
        timeout: TimeInterval,
        maxOutputBytes: Int
    ) async throws -> RemoteCommandResult {
        XCTAssertEqual(command, "printf contract")
        XCTAssertEqual(timeout, 2)
        XCTAssertEqual(maxOutputBytes, 1_024)
        return RemoteCommandResult(stdout: Data("contract".utf8), stderr: Data(), exitCode: 0)
    }

    func openShell(dimensions: RemoteShellDimensions) async throws -> any RemoteShellSession {
        await shell.recordInitialDimensions(dimensions)
        return shell
    }

    func openSFTP() async throws -> any RemoteFileClient { files }
    func close() async { closed = true }
    func isClosed() -> Bool { closed }
}

private actor ContractShell: RemoteShellSession {
    nonisolated let events: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var data = Data()
    private var dimensions = RemoteShellDimensions.standard
    private var closed = false

    init() {
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    func recordInitialDimensions(_ value: RemoteShellDimensions) {
        dimensions = value
    }

    func write(_ value: Data) async throws { data.append(value) }
    func resize(_ value: RemoteShellDimensions) async throws { dimensions = value }
    func close() async {
        closed = true
        continuation.finish()
    }

    func writtenData() -> Data { data }
    func lastDimensions() -> RemoteShellDimensions { dimensions }
    func isClosed() -> Bool { closed }
}

private actor ContractFileClient: RemoteFileClient {
    private var cancelled = false
    private var closed = false

    func list(path: String) async throws -> SFTPDirectoryListing {
        SFTPDirectoryListing(path: path, items: [])
    }

    func createDirectory(named name: String, in path: String) async throws {}
    func createFile(named name: String, in path: String) async throws {}
    func rename(_ item: RemoteFileItem, to newName: String) async throws {}
    func move(_ item: RemoteFileItem, to directory: String) async throws {}
    func delete(_ item: RemoteFileItem, recursive: Bool) async throws {}
    func upload(
        localURL: URL,
        to remotePath: String,
        onProgress: (@Sendable (SFTPProgress) -> Void)?
    ) async throws {}
    func download(
        remotePath: String,
        size: Int64,
        to localURL: URL,
        onProgress: (@Sendable (SFTPProgress) -> Void)?
    ) async throws {}
    func cancelCurrentOperation() async { cancelled = true }
    func close() async { closed = true }
    func wasCancelled() -> Bool { cancelled }
    func isClosed() -> Bool { closed }
}
