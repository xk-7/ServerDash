import Foundation
import SwiftUI
import SwiftData
import UIKit
import XCTest

@testable import ServerDashMobile

@MainActor
final class MobileTrustLifecycleTests: XCTestCase {
    func testOpenRequestReusesMostRecentlySelectedDisconnectedPaneWithoutHandshake() async throws {
        let engine = ControlledConnectionEngine()
        let runtime = MobileRuntime(engine: engine, trustBroker: MobileHostTrustBroker())
        let config = RemoteConnectionContractTests.makeConfig()
        let first = runtime.openTerminal(config: config)
        let second = runtime.openTerminal(config: config, forceNew: true)
        await first.close()
        await second.close()
        runtime.terminalWorkspace.select(pane: first.id)
        for _ in 0..<20 {
            let reused = runtime.openSession(SessionOpenRequest(serverID: config.id), config: config)
            XCTAssertTrue(reused === first)
        }
        XCTAssertEqual(runtime.destination, .sessions)
        XCTAssertEqual(first.status, .disconnected)
        let calls = await engine.count()
        XCTAssertEqual(calls, 0)
        runtime.closeTerminal(serverID: config.id)
    }

    func testCloseDuringHandshakeCannotRevivePaneOrStealNavigation() async throws {
        let engine = ControlledConnectionEngine()
        let config = RemoteConnectionContractTests.makeConfig()
        let owner = MobileRuntime(engine: engine, trustBroker: MobileHostTrustBroker())
        let controller = try XCTUnwrap(owner.openSession(SessionOpenRequest(serverID: config.id), config: config))
        await waitForCalls(1, engine: engine)
        owner.destination = .machines
        owner.closeTerminal(sessionID: controller.id)
        await Task.yield()
        let session = LifecycleSession(shell: LifecycleShell())
        await engine.complete(0, with: session)
        for _ in 0..<1000 { if await session.isClosed() { break }; await Task.yield() }
        XCTAssertTrue(owner.terminalWorkspace.tabs.isEmpty)
        XCTAssertEqual(owner.destination, .machines)
        let closed = await session.isClosed()
        XCTAssertTrue(closed)
    }

    func testOnlyLatestReconnectCanPublishAndUsesLatestConfiguration() async throws {
        let engine = ControlledConnectionEngine(), config = RemoteConnectionContractTests.makeConfig()
        let controller = MobileTerminalController(config: config, engine: engine, trustBroker: MobileHostTrustBroker())
        controller.reconnect(config: config)
        await waitForCalls(1, engine: engine)
        let changed = ServerConnectionConfig(id: config.id, credentialID: config.id, name: config.name, host: "changed.test",
            port: 2222, username: "updated", authentication: .password, privateKeyPath: "")
        controller.reconnect(config: changed)
        await waitForCalls(2, engine: engine)
        let old = LifecycleSession(shell: LifecycleShell()), latest = LifecycleSession(shell: LifecycleShell())
        await engine.complete(1, with: latest)
        for _ in 0..<1000 { if controller.status == .connected { break }; await Task.yield() }
        await engine.complete(0, with: old)
        for _ in 0..<1000 { if await old.isClosed() { break }; await Task.yield() }
        let oldClosed = await old.isClosed(), latestClosed = await latest.isClosed()
        XCTAssertTrue(oldClosed)
        XCTAssertFalse(latestClosed)
        XCTAssertEqual(controller.status, .connected)
        XCTAssertEqual(controller.config.host, "changed.test")
        XCTAssertEqual(controller.config.port, 2222)
        await controller.dispose()
    }

    func testSFTPFailureClosesSSHAndClosedHandshakeCannotRevive() async throws {
        let engine = ControlledConnectionEngine()
        let files = MobileSFTPController(config: RemoteConnectionContractTests.makeConfig(), engine: engine, broker: MobileHostTrustBroker())
        let failing = LifecycleSession(shell: LifecycleShell())
        let connect = Task { await files.connectAndLoad() }
        await waitForCalls(1, engine: engine)
        await engine.complete(0, with: failing)
        await connect.value
        XCTAssertNotNil(files.errorMessage)
        let closed = await failing.isClosed()
        XCTAssertTrue(closed)
        let retry = Task { await files.connectAndLoad() }
        await waitForCalls(2, engine: engine)
        await files.stop()
        let late = LifecycleSession(shell: LifecycleShell())
        await engine.complete(1, with: late)
        await retry.value
        let lateClosed = await late.isClosed()
        XCTAssertTrue(lateClosed)
        XCTAssertNil(files.client)
        XCTAssertFalse(files.loading)
    }

    func testSFTPTransferSurvivesForegroundNavigationAndWaitsForExport() async throws {
        let files = WorkspaceFileClient(), engine = ControlledConnectionEngine()
        let runtime = MobileRuntime(engine: engine, trustBroker: MobileHostTrustBroker())
        let config = RemoteConnectionContractTests.makeConfig()
        runtime.openSFTP(config: config)
        let controller = try XCTUnwrap(runtime.fileControllers.values.first)
        await waitForCalls(1, engine: engine)
        let session = WorkspaceFileSession(files: files)
        await engine.complete(0, with: session)
        for _ in 0..<1000 { if !controller.loading { break }; await Task.yield() }
        controller.startDownload(Self.downloadItem)
        for _ in 0..<1000 { if await files.downloading() { break }; await Task.yield() }
        let transfer = controller.transferTask
        runtime.destination = .machines
        XCTAssertTrue(controller.hasActiveTransfer)
        await files.finishDownload()
        await transfer?.value
        XCTAssertEqual(controller.exportDocument?.data, Data("download-fixture".utf8))
        XCTAssertFalse(controller.showingExporter)
        XCTAssertEqual(runtime.destination, .machines)
        let path = await files.downloadPath()
        if let path { XCTAssertFalse(FileManager.default.fileExists(atPath: path.path)) }
        runtime.destination = .sessions
        controller.beginIfNeeded()
        let connects = await engine.count()
        XCTAssertEqual(connects, 1)
        runtime.closeWorkspaceTabs(runtime.terminalWorkspace.tabs)
        for _ in 0..<1000 { if await session.isClosed() { break }; await Task.yield() }
        XCTAssertTrue(runtime.fileControllers.isEmpty)
        XCTAssertNil(controller.exportDocument)
    }

    func testSFTPDirectoryGenerationAndBackgroundCancellation() async throws {
        let files = WorkspaceFileClient(), engine = ControlledConnectionEngine()
        let controller = MobileSFTPController(config: RemoteConnectionContractTests.makeConfig(), engine: engine, broker: MobileHostTrustBroker())
        let connect = Task { await controller.connectAndLoad() }
        await waitForCalls(1, engine: engine)
        await engine.complete(0, with: WorkspaceFileSession(files: files))
        await connect.value
        let old = Task { await controller.open("/old") }
        let recent = Task { await controller.open("/recent") }
        for _ in 0..<1000 { if await files.pendingDirectories() == 2 { break }; await Task.yield() }
        await files.finishDirectory("/recent")
        await recent.value
        await files.finishDirectory("/old")
        await old.value
        XCTAssertEqual(controller.path, "/recent")
        controller.startDownload(Self.downloadItem)
        for _ in 0..<1000 { if await files.downloading() { break }; await Task.yield() }
        await controller.stop(background: true)
        XCTAssertTrue(controller.interrupted)
        XCTAssertFalse(controller.hasActiveTransfer)
        XCTAssertNil(controller.client)
        let path = await files.downloadPath()
        if let path { XCTAssertFalse(FileManager.default.fileExists(atPath: path.path)) }
        await controller.stop()
    }

    private static var downloadItem: RemoteFileItem {
        RemoteFileItem(path: "/fixture.txt", name: "fixture.txt", kind: .file, size: 16, permissions: "", owner: "", group: "", modifiedText: "")
    }
    private func waitForCalls(_ count: Int, engine: ControlledConnectionEngine) async {
        for _ in 0..<1000 { if await engine.count() >= count { return }; await Task.yield() }
        XCTFail("Connection did not start")
    }

    func testSameServerCanOwnIndependentTerminalBuffersAndCloseIndividually() async {
        let engine = LifecycleEngine(session: LifecycleSession(shell: LifecycleShell()))
        let runtime = MobileRuntime(engine: engine, trustBroker: MobileHostTrustBroker())
        let config = RemoteConnectionContractTests.makeConfig()
        let first = runtime.openTerminal(config: config)
        let second = runtime.openTerminal(config: config, forceNew: true)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(runtime.terminalControllers.count, 2)
        first.surface.terminal.frame = CGRect(x: 0, y: 0, width: 800, height: 400)
        second.surface.terminal.frame = CGRect(x: 0, y: 0, width: 800, height: 400)
        first.surface.terminal.layoutIfNeeded()
        second.surface.terminal.layoutIfNeeded()
        first.surface.terminal.feed(text: "first-buffer")
        second.surface.terminal.feed(text: "second-buffer")
        first.surface.terminal.frame = .zero
        first.surface.terminal.layoutIfNeeded()
        first.surface.terminal.frame = CGRect(x: 0, y: 0, width: 393, height: 700)
        first.surface.terminal.layoutIfNeeded()
        XCTAssertTrue(String(decoding: first.surface.terminal.getTerminal().getBufferAsData(), as: UTF8.self).contains("first-buffer"))
        XCTAssertFalse(String(decoding: second.surface.terminal.getTerminal().getBufferAsData(), as: UTF8.self).contains("first-buffer"))
        runtime.closeTerminal(sessionID: first.id)
        XCTAssertNil(runtime.terminalControllers[first.id])
        XCTAssertNotNil(runtime.terminalControllers[second.id])
        runtime.closeTerminal(serverID: config.id)
        XCTAssertTrue(runtime.terminalControllers.isEmpty)
        XCTAssertTrue(runtime.terminalWorkspace.tabs.isEmpty)
    }

    func testLateConnectionIsClosedAfterPanelHasBeenClosed() async throws {
        let session = LifecycleSession(shell: LifecycleShell())
        let engine = DeferredTerminalEngine()
        let controller = MobileTerminalController(config: RemoteConnectionContractTests.makeConfig(), engine: engine, trustBroker: MobileHostTrustBroker())
        let task = Task { await controller.connect() }
        for _ in 0..<1000 {
            if await engine.isWaiting() { break }
            await Task.yield()
        }
        let waiting = await engine.isWaiting()
        XCTAssertTrue(waiting)
        await controller.close()
        await engine.finish(session)
        await task.value
        XCTAssertEqual(controller.status, .disconnected)
        let closed = await session.isClosed()
        XCTAssertTrue(closed)
        await controller.dispose()
    }

    func testRemountDoesNotReconnectAndInitialResizeIsRetained() async {
        let session = LifecycleSession(shell: LifecycleShell())
        let controller = MobileTerminalController(config: RemoteConnectionContractTests.makeConfig(), engine: LifecycleEngine(session: session), trustBroker: MobileHostTrustBroker())
        let dimensions = RemoteShellDimensions(columns: 81, rows: 17, pixelWidth: 600, pixelHeight: 350)
        controller.resize(dimensions)
        await controller.startIfNeeded()
        await controller.startIfNeeded()
        let opens = await session.opens(), actual = await session.initialDimensions()
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(actual, dimensions)
        await controller.dispose()
    }

    func testCancellingViewTaskDoesNotCancelOwnedInitialHandshake() async {
        let engine = DeferredTerminalEngine(), session = LifecycleSession(shell: LifecycleShell())
        let controller = MobileTerminalController(config: RemoteConnectionContractTests.makeConfig(), engine: engine, trustBroker: MobileHostTrustBroker())
        let viewTask = Task { await controller.startIfNeeded() }
        for _ in 0..<1000 {
            if await engine.isWaiting() { break }
            await Task.yield()
        }
        viewTask.cancel()
        await engine.finish(session)
        await viewTask.value
        XCTAssertEqual(controller.status, .connected)
        await controller.dispose()
    }

    func testWorkspaceRendersPhoneAndTabletWithFixtureSessions() async throws {
        let runtime = MobileRuntime(engine: FixtureTerminalEngine(), trustBroker: MobileHostTrustBroker())
        let container = try PersistenceController.makeInMemoryContainer()
        let context = ModelContext(container)
        var first: UUID?
        for name in ["Web · 测试", "Database · 测试", "Worker · 测试", "Logs · 测试"] {
            let server = ServerRecord(name: name, host: "fixture.example.test", username: "tester")
            context.insert(server)
            let controller = runtime.openTerminal(config: server.connectionConfig, forceNew: true)
            await controller.connect()
            controller.surface.terminal.frame = CGRect(x: 0, y: 0, width: 800, height: 400)
            controller.surface.terminal.feed(text: "ServerDash / fixture session\r\n\(name) $ uptime\r\n23:40:00 up 14 days, load average: 0.02\r\nhttps://example.com 192.168.1.100\r\n/var/log/syslog : 8080\r\n")
            if let first { XCTAssertTrue(runtime.terminalWorkspace.split(first, inserting: controller.id, axis: .right)) }
            else { first = controller.id }
        }
        try context.save()
        runtime.terminalWorkspace.arrangeGrid()
        for (name, size) in [("ipad-workspace", CGSize(width: 1194, height: 834)), ("iphone-workspace", CGSize(width: 393, height: 852))] {
            if name.hasPrefix("iphone"), let first { runtime.terminalWorkspace.toggleZoom(pane: first) }
            let root = NavigationStack { MobileSessionsView() }.environmentObject(runtime).modelContainer(container).preferredColorScheme(.dark)
            let host = UIHostingController(rootView: AnyView(root))
            host.view.frame = CGRect(origin: .zero, size: size)
            let window = UIWindow(frame: host.view.frame)
            window.rootViewController = host
            window.isHidden = false
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            host.view.layoutIfNeeded()
            let screenshot = UIGraphicsImageRenderer(size: size).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: screenshot)
            attachment.name = name; attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertGreaterThan(screenshot.size.width, 0)
            window.isHidden = true
            host.rootView = AnyView(EmptyView())
            host.view.layoutIfNeeded()
            window.rootViewController = nil
            try await Task.sleep(for: .milliseconds(100))
        }
        for controller in runtime.terminalControllers.values { await controller.dispose() }
        try await Task.sleep(for: .milliseconds(100))
    }
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

    func testCancellingTrustRequestDismissesItAndAdvancesQueue() async throws {
        try await withTemporaryKnownHosts { _ in
            let broker = MobileHostTrustBroker()
            let first = Task { try await broker.evaluate(Self.presentation(blob: "first")) }
            for _ in 0..<100 where broker.pending == nil { await Task.yield() }
            let secondPresentation = Self.presentation(blob: "second")
            let second = Task { try await broker.evaluate(secondPresentation) }
            await Task.yield()
            first.cancel()
            do {
                _ = try await first.value
                XCTFail("A cancelled trust request must not continue connecting")
            } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
            for _ in 0..<100 where broker.pending?.presentation != secondPresentation { await Task.yield() }
            XCTAssertEqual(broker.pending?.presentation, secondPresentation)
            broker.respond(.reject)
            let decision = try await second.value
            XCTAssertEqual(decision, .reject)
            XCTAssertNil(broker.pending)
        }
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

private struct FixtureTerminalEngine: RemoteConnectionEngine {
    let capabilities = PlatformCapabilities.mobile
    func connect(_ config: ServerConnectionConfig, trustHandler: @escaping RemoteHostTrustHandler) async throws -> any RemoteSession {
        LifecycleSession(shell: LifecycleShell())
    }
}

private actor LifecycleSession: RemoteSession {
    let shell: LifecycleShell
    private var closed = false
    private var openCount = 0
    private var dimensions = RemoteShellDimensions.standard
    func opens() -> Int { openCount }
    func initialDimensions() -> RemoteShellDimensions { dimensions }

    init(shell: LifecycleShell) { self.shell = shell }

    func execute(
        _ command: String,
        timeout: TimeInterval,
        maxOutputBytes: Int
    ) async throws -> RemoteCommandResult {
        RemoteCommandResult(stdout: Data(), stderr: Data(), exitCode: 0)
    }

    func openShell(dimensions: RemoteShellDimensions) async throws -> any RemoteShellSession {
        self.dimensions = dimensions
        openCount += 1
        return shell
    }

    func openSFTP() async throws -> any RemoteFileClient {
        throw RemoteConnectionFailure.unsupported("测试 SFTP")
    }

    func close() async { closed = true }
    func isClosed() -> Bool { closed }
}

private actor DeferredTerminalEngine: RemoteConnectionEngine {
    nonisolated let capabilities = PlatformCapabilities.mobile
    private var continuation: CheckedContinuation<any RemoteSession, Error>?
    func connect(_ config: ServerConnectionConfig, trustHandler: @escaping RemoteHostTrustHandler) async throws -> any RemoteSession {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func isWaiting() -> Bool { continuation != nil }
    func finish(_ session: any RemoteSession) { continuation?.resume(returning: session); continuation = nil }
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

private actor ControlledConnectionEngine: RemoteConnectionEngine {
    nonisolated let capabilities = PlatformCapabilities.mobile
    private var continuations: [CheckedContinuation<any RemoteSession, Error>?] = []
    func connect(_ config: ServerConnectionConfig, trustHandler: @escaping RemoteHostTrustHandler) async throws -> any RemoteSession {
        try await withCheckedThrowingContinuation { continuations.append($0) }
    }
    func count() -> Int { continuations.count }
    func complete(_ index: Int, with session: any RemoteSession) {
        continuations[index]?.resume(returning: session)
        continuations[index] = nil
    }
}

private actor WorkspaceFileSession: RemoteSession {
    let files: WorkspaceFileClient
    private var closed = false
    init(files: WorkspaceFileClient) { self.files = files }
    func execute(_ command: String, timeout: TimeInterval, maxOutputBytes: Int) async throws -> RemoteCommandResult {
        RemoteCommandResult(stdout: Data(), stderr: Data(), exitCode: 0)
    }
    func openShell(dimensions: RemoteShellDimensions) async throws -> any RemoteShellSession { throw CancellationError() }
    func openSFTP() async throws -> any RemoteFileClient { files }
    func close() async { closed = true }
    func isClosed() -> Bool { closed }
}

private actor WorkspaceFileClient: RemoteFileClient {
    private var downloadContinuation: CheckedContinuation<Void, Error>?
    private var destination: URL?
    private var directories: [String: CheckedContinuation<SFTPDirectoryListing, Error>] = [:]
    func list(path: String) async throws -> SFTPDirectoryListing {
        if path == "." { return SFTPDirectoryListing(path: "/", items: []) }
        return try await withCheckedThrowingContinuation { directories[path] = $0 }
    }
    func pendingDirectories() -> Int { directories.count }
    func finishDirectory(_ path: String) { directories.removeValue(forKey: path)?.resume(returning: SFTPDirectoryListing(path: path, items: [])) }
    func createDirectory(named name: String, in path: String) async throws {}
    func createFile(named name: String, in path: String) async throws {}
    func rename(_ item: RemoteFileItem, to newName: String) async throws {}
    func move(_ item: RemoteFileItem, to directory: String) async throws {}
    func delete(_ item: RemoteFileItem, recursive: Bool) async throws {}
    func upload(localURL: URL, to remotePath: String, onProgress: (@Sendable (SFTPProgress) -> Void)?) async throws {}
    func download(remotePath: String, size: Int64, to localURL: URL, onProgress: (@Sendable (SFTPProgress) -> Void)?) async throws {
        destination = localURL
        try Data("partial-fixture".utf8).write(to: localURL)
        try await withCheckedThrowingContinuation { downloadContinuation = $0 }
        try Task.checkCancellation()
        try Data("download-fixture".utf8).write(to: localURL)
    }
    func downloading() -> Bool { downloadContinuation != nil }
    func downloadPath() -> URL? { destination }
    func finishDownload() { downloadContinuation?.resume(); downloadContinuation = nil }
    func cancelCurrentOperation() async { downloadContinuation?.resume(throwing: CancellationError()); downloadContinuation = nil }
    func close() async {
        await cancelCurrentOperation()
        for continuation in directories.values { continuation.resume(throwing: CancellationError()) }
        directories.removeAll()
    }
}
