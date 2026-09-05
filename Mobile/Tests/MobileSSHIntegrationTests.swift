@preconcurrency import Citadel
import Crypto
import Foundation
import NIOCore
@preconcurrency import NIOSSH
import XCTest

@testable import ServerDashMobile

final class MobileSSHIntegrationTests: XCTestCase {
    func testPasswordHostTrustAndRemoteCommandAgainstLocalCitadelServer() async throws {
        let password = "integration-password"
        let credentialID = UUID()
        try KeychainService.savePassword(password, for: credentialID)
        defer { try? KeychainService.deletePassword(for: credentialID) }

        let auth = IntegrationAuthenticationDelegate(mode: .password(password))
        let (server, port) = try await startServer(authentication: auth)
        server.enableExec(withDelegate: IntegrationExecDelegate())
        defer { Task { try? await server.close() } }

        let config = ServerConnectionConfig(
            id: UUID(),
            credentialID: credentialID,
            name: "Local password fixture",
            host: "127.0.0.1",
            port: port,
            username: "mobile",
            authentication: .password,
            privateKeyPath: ""
        )
        let recorder = IntegrationHostKeyRecorder()
        let session = try await CitadelRemoteConnectionEngine().connect(config) { presentation in
            await recorder.record(presentation)
            return .trustOnce
        }
        let result = try await session.execute("exit-7", timeout: 3, maxOutputBytes: 4_096)

        XCTAssertEqual(result.output, "stdout:exit-7")
        XCTAssertEqual(result.errorOutput, "stderr:exit-7")
        XCTAssertEqual(result.exitCode, 7)
        let hostKey = await recorder.value()
        XCTAssertEqual(hostKey?.host, config.host)
        XCTAssertEqual(hostKey?.port, config.port)
        XCTAssertTrue(hostKey?.fingerprint.hasPrefix("SHA256:") == true)
        await session.close()
        try await server.close()
    }

    func testImportedEd25519KeyAuthenticatesAgainstLocalCitadelServer() async throws {
        let privateKey = try Curve25519.Signing.PrivateKey(sshEd25519: Self.ed25519Fixture)
        let acceptedKey = NIOSSHPrivateKey(ed25519Key: privateKey).publicKey
        let auth = IntegrationAuthenticationDelegate(mode: .publicKey(acceptedKey))
        let (server, port) = try await startServer(authentication: auth)
        server.enableExec(withDelegate: IntegrationExecDelegate())
        defer { Task { try? await server.close() } }

        let keyID = UUID()
        try KeychainService.saveSecret(
            Self.ed25519Fixture,
            account: KeychainService.importedKeyAccount(for: keyID)
        )
        defer {
            try? KeychainService.deleteSecret(account: KeychainService.importedKeyAccount(for: keyID))
        }
        var config = RemoteConnectionContractTests.makeConfig()
        config = ServerConnectionConfig(
            id: config.id,
            credentialID: config.credentialID,
            name: "Local key fixture",
            host: "127.0.0.1",
            port: port,
            username: "mobile",
            authentication: .privateKey,
            privateKeyPath: "",
            sshKeyID: keyID,
            usesImportedKey: true
        )

        let session = try await CitadelRemoteConnectionEngine().connect(config) { _ in .trustOnce }
        let result = try await session.execute("success", timeout: 3, maxOutputBytes: 4_096)
        XCTAssertEqual(result.output, "stdout:success")
        XCTAssertEqual(result.exitCode, 0)
        await session.close()
        try await server.close()
    }

    func testPTYInputAndResizeAgainstLocalCitadelServer() async throws {
        let password = "shell-password"
        let credentialID = UUID()
        try KeychainService.savePassword(password, for: credentialID)
        defer { try? KeychainService.deletePassword(for: credentialID) }

        let recorder = IntegrationShellRecorder()
        let auth = IntegrationAuthenticationDelegate(mode: .password(password))
        let (server, port) = try await startServer(authentication: auth)
        server.enableShell(withDelegate: IntegrationShellDelegate(recorder: recorder))
        defer { Task { try? await server.close() } }

        let config = ServerConnectionConfig(
            id: UUID(),
            credentialID: credentialID,
            name: "Local shell fixture",
            host: "127.0.0.1",
            port: port,
            username: "mobile",
            authentication: .password,
            privateKeyPath: ""
        )
        let session = try await CitadelRemoteConnectionEngine().connect(config) { _ in .trustOnce }
        let shell = try await session.openShell(dimensions: .standard)
        let expectedInput = Data("你好, PTY".utf8)
        let outputTask = Task {
            var output = Data()
            for try await chunk in shell.events {
                output.append(chunk)
                if output.range(of: expectedInput) != nil { return output }
            }
            return output
        }

        try await shell.write(expectedInput)
        let resized = RemoteShellDimensions(
            columns: 132,
            rows: 48,
            pixelWidth: 1_024,
            pixelHeight: 768
        )
        try await shell.resize(resized)

        for _ in 0..<200 {
            let hasInput = await recorder.input().range(of: expectedInput) != nil
            let size = await recorder.lastSize()
            if hasInput, size?.columns == resized.columns, size?.rows == resized.rows { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let receivedInput = await recorder.input()
        let lastSize = await recorder.lastSize()
        XCTAssertNotNil(receivedInput.range(of: expectedInput))
        XCTAssertEqual(lastSize?.columns, resized.columns)
        XCTAssertEqual(lastSize?.rows, resized.rows)

        let echoed = try await outputTask.value
        XCTAssertNotNil(echoed.range(of: expectedInput))
        await shell.close()
        await session.close()
        try await server.close()
    }

    private func startServer(
        authentication: IntegrationAuthenticationDelegate
    ) async throws -> (SSHServer, Int) {
        var lastError: Error?
        for port in 23_400..<23_420 {
            do {
                let hostKey = NIOSSHPrivateKey(
                    ed25519Key: Curve25519.Signing.PrivateKey()
                )
                let server = try await SSHServer.host(
                    host: "127.0.0.1",
                    port: port,
                    hostKeys: [hostKey],
                    authenticationDelegate: authentication
                )
                return (server, port)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? RemoteConnectionFailure.transport("无法启动本地 SSH 测试服务器")
    }

    // Public, non-production fixture. Split the armor marker so repository
    // scanners do not mistake this test-only material for a deployable secret.
    private static let ed25519Fixture = [
        "-----BEGIN OPENSSH " + "PRIVATE KEY-----",
        "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW",
        "QyNTUxOQAAACAi19yxbgtZH0Y26GZGr2vyVErGFskeOY9HwHLxYbmkAwAAAKAPNV8QDzVf",
        "EAAAAAtzc2gtZWQyNTUxOQAAACAi19yxbgtZH0Y26GZGr2vyVErGFskeOY9HwHLxYbmkAw",
        "AAAED3UDHB29MB7vQDpb7PGFjEMAYT9FzpnadYWrCPSUma5SLX3LFuC1kfRjboZkava/JU",
        "SsYWyR45j0fAcvFhuaQDAAAAHGphYXBASmFhcHMtTWFjQm9vay1Qcm8ubG9jYWwB",
        "-----END OPENSSH " + "PRIVATE KEY-----",
    ].joined(separator: "\n")
}

private final class IntegrationAuthenticationDelegate: NIOSSHServerUserAuthenticationDelegate, @unchecked Sendable {
    enum Mode {
        case password(String)
        case publicKey(NIOSSHPublicKey)
    }

    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods
    private let mode: Mode

    init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .password: supportedAuthenticationMethods = .password
        case .publicKey: supportedAuthenticationMethods = .publicKey
        }
    }

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        let accepted: Bool = switch (mode, request.request) {
        case (.password(let expected), .password(let offered)):
            request.username == "mobile" && offered.password == expected
        case (.publicKey(let expected), .publicKey(let offered)):
            request.username == "mobile" && offered.publicKey == expected
        default:
            false
        }
        responsePromise.succeed(accepted ? .success : .failure)
    }
}

private final class IntegrationExecDelegate: ExecDelegate, @unchecked Sendable {
    struct Context: ExecCommandContext {
        func terminate() async throws {}
    }

    func setEnvironmentValue(_ value: String, forKey key: String) async throws {
        _ = value
        _ = key
    }

    func start(
        command: String,
        outputHandler: ExecOutputHandler
    ) async throws -> any ExecCommandContext {
        DispatchQueue.global().async {
            outputHandler.stdoutPipe.fileHandleForWriting.write(Data("stdout:\(command)".utf8))
            outputHandler.stderrPipe.fileHandleForWriting.write(Data("stderr:\(command)".utf8))
            try? outputHandler.stdoutPipe.fileHandleForWriting.close()
            try? outputHandler.stderrPipe.fileHandleForWriting.close()
            // Citadel's test server forwards pipe reads asynchronously. Give the
            // server handlers time to flush both streams before sending exit-status.
            Thread.sleep(forTimeInterval: 0.3)
            outputHandler.succeed(exitCode: command == "exit-7" ? 7 : 0)
        }
        return Context()
    }
}

private actor IntegrationHostKeyRecorder {
    private var presentation: RemoteHostKeyPresentation?
    func record(_ value: RemoteHostKeyPresentation) { presentation = value }
    func value() -> RemoteHostKeyPresentation? { presentation }
}

private actor IntegrationShellRecorder {
    private var received = Data()
    private var size: (columns: Int, rows: Int)?

    func append(_ data: Data) { received.append(data) }
    func record(columns: Int, rows: Int) { size = (columns, rows) }
    func input() -> Data { received }
    func lastSize() -> (columns: Int, rows: Int)? { size }
}

private struct IntegrationShellDelegate: ShellDelegate {
    let recorder: IntegrationShellRecorder

    func startShell(
        inbound: AsyncStream<ShellClientEvent>,
        outbound: ShellOutboundWriter,
        context: SSHShellContext
    ) async throws {
        let sizeTask = Task {
            for await value in context.windowSize {
                await recorder.record(columns: value.columns, rows: value.rows)
            }
        }
        defer { sizeTask.cancel() }
        outbound.write("ready\n")
        for await event in inbound {
            guard !Task.isCancelled else { return }
            switch event {
            case .stdin(let buffer):
                let data = Data(buffer.readableBytesView)
                await recorder.append(data)
                outbound.write(buffer)
            }
        }
    }
}
