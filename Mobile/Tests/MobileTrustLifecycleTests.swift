import Foundation
import XCTest

@testable import ServerDashMobile

@MainActor
final class MobileTrustLifecycleTests: XCTestCase {
    func testUnknownHostPausesUntilExplicitDecision() async throws {
        try await withTemporaryKnownHosts { _ in
            let broker = MobileHostTrustBroker()
            let presentation = Self.presentation(blob: "unknown-key")
            let decisionTask = Task { try await broker.evaluate(presentation) }

            await Task.yield()
            XCTAssertEqual(broker.pending?.presentation, presentation)
            XCTAssertFalse(broker.pending?.changed ?? true)
            broker.respond(.trustOnce)

            let decision = try await decisionTask.value
            XCTAssertEqual(decision, .trustOnce)
            XCTAssertNil(broker.pending)
            XCTAssertTrue(TrustedHostStore.existingKeys(host: presentation.host, port: presentation.port).isEmpty)
        }
    }

    func testChangedHostShowsOldFingerprintAndRejectsWithoutReplacing() async throws {
        try await withTemporaryKnownHosts { _ in
            let old = Self.presentation(blob: "old-key")
            try TrustedHostStore.trust(old.probe)
            let updated = Self.presentation(blob: "changed-key")
            let broker = MobileHostTrustBroker()
            let decisionTask = Task { try await broker.evaluate(updated) }

            await Task.yield()
            XCTAssertTrue(broker.pending?.changed == true)
            XCTAssertEqual(broker.pending?.oldFingerprint, old.fingerprint)
            broker.respond(.reject)

            let decision = try await decisionTask.value
            XCTAssertEqual(decision, .reject)
            XCTAssertEqual(
                TrustedHostStore.existingFingerprint(host: old.host, port: old.port),
                old.fingerprint
            )
        }
    }

    func testBackgroundInterruptsTerminalAndForegroundRequiresReconnect() async throws {
        let shell = LifecycleShell()
        let session = LifecycleSession(shell: shell)
        let engine = LifecycleEngine(session: session)
        let runtime = MobileRuntime(engine: engine, trustBroker: MobileHostTrustBroker())
        let controller = runtime.openTerminal(config: RemoteConnectionContractTests.makeConfig())

        await controller.connect()
        XCTAssertEqual(controller.status, .connected)

        runtime.suspendForBackground()
        for _ in 0..<100 where controller.status != .interrupted {
            await Task.yield()
        }

        XCTAssertTrue(runtime.isBackgrounded)
        XCTAssertEqual(controller.status, .interrupted)
        let shellClosed = await shell.isClosed()
        let sessionClosed = await session.isClosed()
        XCTAssertTrue(shellClosed)
        XCTAssertTrue(sessionClosed)

        runtime.resumeFromBackground()
        XCTAssertFalse(runtime.isBackgrounded)
        XCTAssertEqual(controller.status, .interrupted)
    }

    private func withTemporaryKnownHosts(
        _ operation: (URL) async throws -> Void
    ) async throws {
        let original = TrustedHostStore.knownHostsURL
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerDash-mobile-known-hosts-\(UUID().uuidString)")
        TrustedHostStore.knownHostsURL = temporary
        defer {
            try? FileManager.default.removeItem(at: temporary)
            TrustedHostStore.knownHostsURL = original
        }
        try await operation(temporary)
    }

    private static func presentation(blob: String) -> RemoteHostKeyPresentation {
        RemoteHostKeyPresentation(
            host: "trust.example.test",
            port: 2222,
            algorithm: "ssh-ed25519",
            keyBlob: Data(blob.utf8)
        )
    }
}

private struct LifecycleEngine: RemoteConnectionEngine {
    let capabilities = PlatformCapabilities.mobile
    let session: LifecycleSession

    func connect(
        _ config: ServerConnectionConfig,
        trustHandler: @escaping RemoteHostTrustHandler
    ) async throws -> any RemoteSession {
        _ = config
        _ = trustHandler
        return session
    }
}

private actor LifecycleSession: RemoteSession {
    let shell: LifecycleShell
    private var closed = false

    init(shell: LifecycleShell) { self.shell = shell }

    func execute(
        _ command: String,
        timeout: TimeInterval,
        maxOutputBytes: Int
    ) async throws -> RemoteCommandResult {
        RemoteCommandResult(stdout: Data(), stderr: Data(), exitCode: 0)
    }

    func openShell(dimensions: RemoteShellDimensions) async throws -> any RemoteShellSession {
        _ = dimensions
        return shell
    }

    func openSFTP() async throws -> any RemoteFileClient {
        throw RemoteConnectionFailure.unsupported("测试 SFTP")
    }

    func close() async { closed = true }
    func isClosed() -> Bool { closed }
}

private actor LifecycleShell: RemoteShellSession {
    nonisolated let events: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var closed = false

    init() {
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    func write(_ data: Data) async throws { _ = data }
    func resize(_ dimensions: RemoteShellDimensions) async throws { _ = dimensions }
    func close() async {
        closed = true
        continuation.finish()
    }
    func isClosed() -> Bool { closed }
}
