import Foundation
import XCTest
@testable import ServerDashMobile

@MainActor
final class MobileMonitoringTests: XCTestCase {
    func testConcurrencyLimitDeduplicationAndQueueDrain() async throws {
        let engine = ControlledMonitorEngine()
        let runtime = MobileRuntime(engine: engine, trustBroker: MobileHostTrustBroker(), maxConcurrentMonitors: 2)
        let servers = makeServers(5)
        let first = refresh(servers[0], runtime)
        XCTAssertEqual(first, refresh(servers[0], runtime))
        for server in servers.dropFirst() { refresh(server, runtime) }
        await eventually { await engine.count == 2 }
        XCTAssertEqual(runtime.refreshingServerIDs.count, 5)
        let initial = await engine.sessions
        await initial[0].finish()
        await eventually { await engine.count == 3 }
        let firstClosed = await initial[0].closed
        XCTAssertTrue(firstClosed)
        for _ in 0..<5 {
            for session in await engine.sessions { await session.finish() }
            try await Task.sleep(for: .milliseconds(10))
        }
        await eventually { runtime.refreshingServerIDs.isEmpty }
        let count = await engine.count
        let maximumActive = await engine.maximumActive
        XCTAssertEqual(count, 5)
        XCTAssertLessThanOrEqual(maximumActive, 2)
        XCTAssertEqual(runtime.statuses.values.filter { $0 == .online }.count, 5)
    }

    func testBackgroundResultCannotOverwriteOrRemoveForegroundRequest() async throws {
        let engine = ControlledMonitorEngine()
        let runtime = MobileRuntime(engine: engine, trustBroker: MobileHostTrustBroker(), maxConcurrentMonitors: 1)
        let server = makeServers(1)[0]
        refresh(server, runtime)
        await eventually { await engine.count == 1 }
        let old = await engine.sessions[0]
        runtime.suspendForBackground()
        XCTAssertEqual(runtime.statuses[server.id], .unknown)
        XCTAssertTrue(runtime.refreshingServerIDs.isEmpty)
        runtime.resumeFromBackground()
        let replacement = refresh(server, runtime)
        // The old transport deliberately ignores cancellation until its result arrives.
        let countBeforeClose = await engine.count
        XCTAssertEqual(countBeforeClose, 1)
        await old.finish(fail: true)
        await eventually { await engine.count == 2 }
        XCTAssertTrue(runtime.refreshingServerIDs.contains(server.id))
        XCTAssertNil(runtime.errors[server.id])
        XCTAssertEqual(replacement, refresh(server, runtime))
        let current = await engine.sessions[1]
        await current.finish()
        await eventually { runtime.refreshingServerIDs.isEmpty }
        XCTAssertEqual(runtime.statuses[server.id], .online)
        XCTAssertNil(runtime.errors[server.id])
    }

    func testDeletingRunningAndQueuedServersDoesNotResurrectState() async throws {
        let engine = ControlledMonitorEngine()
        let runtime = MobileRuntime(engine: engine, trustBroker: MobileHostTrustBroker(), maxConcurrentMonitors: 1)
        let servers = makeServers(2)
        let batch = Task { await runtime.refreshAll(servers: servers, identities: [], keys: [], routes: []) }
        await eventually { await engine.count == 1 }
        for server in servers { runtime.removeServer(serverID: server.id) }
        await batch.value
        let old = await engine.sessions[0]
        await old.finish()
        await eventually { await old.closed }
        XCTAssertTrue(runtime.statuses.isEmpty)
        XCTAssertTrue(runtime.snapshots.isEmpty)
        XCTAssertTrue(runtime.errors.isEmpty)
        XCTAssertTrue(runtime.refreshingServerIDs.isEmpty)
        let count = await engine.count
        XCTAssertEqual(count, 1)
    }

    func testAutomaticFailureBackoffAllowsImmediateManualRetry() async throws {
        let engine = ControlledMonitorEngine()
        let runtime = MobileRuntime(engine: engine, trustBroker: MobileHostTrustBroker())
        let server = makeServers(1)[0]
        refresh(server, runtime)
        await eventually { await engine.count == 1 }
        await engine.sessions[0].finish(fail: true)
        await eventually { runtime.refreshingServerIDs.isEmpty }
        XCTAssertEqual(runtime.statuses[server.id], .failed)
        XCTAssertNil(runtime.refresh(server: server, identities: [], keys: [], routes: [], automatic: true))
        XCTAssertNotNil(refresh(server, runtime))
        await eventually { await engine.count == 2 }
        await engine.sessions[1].finish()
        await eventually { runtime.refreshingServerIDs.isEmpty }
        XCTAssertEqual(runtime.statuses[server.id], .online)
    }

    func testRefreshAllSkipsPausedServersAndWaitsForCompletion() async throws {
        let engine = ControlledMonitorEngine()
        let runtime = MobileRuntime(engine: engine, trustBroker: MobileHostTrustBroker())
        let servers = makeServers(2)
        servers[1].enableDashboardMonitor = false
        var completed = false
        let batch = Task {
            await runtime.refreshAll(servers: servers, identities: [], keys: [], routes: [])
            completed = true
        }
        await eventually { await engine.count == 1 }
        XCTAssertFalse(completed)
        XCTAssertNil(runtime.statuses[servers[1].id])
        await engine.sessions[0].finish()
        await batch.value
        XCTAssertTrue(completed)
        let count = await engine.count
        XCTAssertEqual(count, 1)
    }

    @discardableResult private func refresh(_ server: ServerRecord, _ runtime: MobileRuntime) -> UUID? {
        runtime.refresh(server: server, identities: [], keys: [], routes: [])
    }

    private func makeServers(_ count: Int) -> [ServerRecord] {
        (0..<count).map { ServerRecord(name: "Host \($0)", host: "monitor-\($0).example.test", username: "tester", authentication: .password) }
    }

    private func eventually(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Condition did not become true", file: file, line: line)
    }

}

private actor ControlledMonitorEngine: RemoteConnectionEngine {
    nonisolated let capabilities = PlatformCapabilities.mobile
    private(set) var sessions: [ControlledMonitorSession] = []
    private(set) var maximumActive = 0
    private var active = 0
    var count: Int { sessions.count }

    func connect(_ config: ServerConnectionConfig, trustHandler: @escaping RemoteHostTrustHandler) async throws -> any RemoteSession {
        let session = ControlledMonitorSession { await self.didClose() }
        sessions.append(session)
        active += 1
        maximumActive = max(maximumActive, active)
        return session
    }

    private func didClose() { active -= 1 }
}

private actor ControlledMonitorSession: RemoteSession {
    private(set) var closed = false
    private var result: Result<RemoteCommandResult, Error>?
    private var waiter: CheckedContinuation<RemoteCommandResult, Error>?
    private let onClose: @Sendable () async -> Void

    init(onClose: @escaping @Sendable () async -> Void) { self.onClose = onClose }

    func execute(_ command: String, timeout: TimeInterval, maxOutputBytes: Int) async throws -> RemoteCommandResult {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func finish(fail: Bool = false) {
        guard result == nil else { return }
        let value: Result<RemoteCommandResult, Error> = fail
            ? .failure(RemoteConnectionFailure.unsupported("Fixture failure"))
            : .success(RemoteCommandResult(stdout: Data("cpu=12\nmem_total_kb=1024\n".utf8), stderr: Data(), exitCode: 0))
        result = value
        waiter?.resume(with: value)
        waiter = nil
    }

    func openShell(dimensions: RemoteShellDimensions) async throws -> any RemoteShellSession {
        throw RemoteConnectionFailure.unsupported("Fixture shell")
    }
    func openSFTP() async throws -> any RemoteFileClient { throw RemoteConnectionFailure.unsupported("Fixture SFTP") }
    func close() async {
        guard !closed else { return }
        closed = true
        await onClose()
    }
}
