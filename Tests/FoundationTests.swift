import Combine
import SwiftData
import XCTest
@testable import ServerDash

final class ConnectionErrorClassificationTests: XCTestCase {
    func testClassifiesDNSTimeoutAuthAndHostKeyErrors() {
        XCTAssertEqual(
            ConnectionError.classify("ssh: Could not resolve hostname example.test"),
            .dnsFailed
        )
        XCTAssertEqual(
            ConnectionError.classify("Connection refused"),
            .connectionRefused
        )
        XCTAssertEqual(
            ConnectionError.classify("Operation timed out"),
            .timeout
        )
        XCTAssertEqual(
            ConnectionError.classify("Permission denied (publickey,password)"),
            .authenticationFailed
        )
        XCTAssertEqual(
            ConnectionError.classify("WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!"),
            .hostKeyChanged(oldFingerprint: nil, newFingerprint: nil)
        )
        XCTAssertEqual(
            ConnectionError.classify(
                """
                WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!
                The fingerprint for the ED25519 key sent by the remote host is
                SHA256:abc+DEF/123.
                Host key verification failed.
                """
            ),
            .hostKeyChanged(oldFingerprint: nil, newFingerprint: "SHA256:abc+DEF/123")
        )
        XCTAssertEqual(
            ConnectionError.classify("Host key verification failed."),
            .hostKeyUntrusted
        )
        XCTAssertEqual(
            ConnectionError.classify("Enter passphrase for key"),
            .privateKeyOrPassphraseFailed
        )
    }

    func testKnownHostsPathIsQuotedForOpenSSHConfigurationParser() {
        let config = ServerConnectionConfig(
            id: UUID(),
            credentialID: UUID(),
            name: "Test",
            host: "example.com",
            port: 22,
            username: "root",
            authentication: .privateKey,
            privateKeyPath: ""
        )
        let arguments = SSHSupport.arguments(
            for: config,
            strictHostChecking: "yes"
        )
        let option = arguments.first { $0.hasPrefix("UserKnownHostsFile=") }

        XCTAssertEqual(option, SSHSupport.userKnownHostsOption)
        XCTAssertTrue(option?.contains("\"/") == true)
        XCTAssertTrue(option?.contains("Application Support") == true)
        XCTAssertTrue(option?.hasSuffix("\"") == true)
    }
}

final class DiagnosticRedactorTests: XCTestCase {
    func testRedactsSecretsAndIPByDefault() {
        let text = "password=super-secret host=203.0.113.10"
        XCTAssertTrue(DiagnosticRedactor.redact(text).contains("[REDACTED]"))
        XCTAssertFalse(DiagnosticRedactor.redact(text).contains("203.0.113.10"))
        XCTAssertTrue(DiagnosticRedactor.redact(text, hideIP: true).contains("[IP]"))
        XCTAssertFalse(
            DiagnosticRedactor.redact(
                "-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----"
            ).contains("abc")
        )
    }

    func testSSHReportDoesNotRecordConnectionIdentifiersOrFingerprints() {
        let config = ServerConnectionConfig(
            id: UUID(),
            credentialID: UUID(),
            name: "Sensitive",
            host: "private.example.test",
            port: 2222,
            username: "private-user",
            authentication: .privateKey,
            privateKeyPath: "/private/key/path"
        )
        let report = SSHDiagnostics.report(
            config: config,
            error: ConnectionError.hostKeyChanged(
                oldFingerprint: "SHA256:old-sensitive",
                newFingerprint: "SHA256:new-sensitive"
            )
        )

        for sensitiveValue in [
            config.host,
            config.username,
            config.privateKeyPath,
            "SHA256:old-sensitive",
            "SHA256:new-sensitive"
        ] {
            XCTAssertFalse(report.contains(sensitiveValue))
        }
        XCTAssertTrue(report.contains(ConnectionError.hostKeyChanged(
            oldFingerprint: nil,
            newFingerprint: nil
        ).code))
    }
}

final class TrustedHostStoreTests: XCTestCase {
    private var originalURL: URL!
    private var temporaryURL: URL!

    override func setUp() {
        super.setUp()
        originalURL = TrustedHostStore.knownHostsURL
        temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerDash-known-hosts-\(UUID().uuidString)")
        TrustedHostStore.knownHostsURL = temporaryURL
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: temporaryURL)
        TrustedHostStore.knownHostsURL = originalURL
        super.tearDown()
    }

    func testTrustReplaceKeepsLatestFingerprint() throws {
        let old = SSHHostKeyProbe(
            host: "vps.example.com",
            port: 22,
            algorithm: "ED25519",
            fingerprint: "SHA256:old",
            keyLine: "vps.example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl old"
        )
        let new = SSHHostKeyProbe(
            host: "vps.example.com",
            port: 22,
            algorithm: "ED25519",
            fingerprint: "SHA256:new",
            keyLine: "vps.example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9NEW1 new"
        )

        try TrustedHostStore.trust(old)
        try TrustedHostStore.trust(new, replacing: true)
        let contents = try String(contentsOf: temporaryURL, encoding: .utf8)
        XCTAssertFalse(contents.contains("old"))
        XCTAssertTrue(contents.contains("NEW1"))
        XCTAssertNotNil(TrustedHostStore.fingerprint(for: old.keyLine))
        XCTAssertEqual(
            TrustedHostStore.existingFingerprint(host: "vps.example.com", port: 22),
            TrustedHostStore.fingerprint(for: new.keyLine)
        )
    }

    func testClassifyUsesStoredFingerprintAsOldValue() throws {
        let old = SSHHostKeyProbe(
            host: "changed.example.com",
            port: 22,
            algorithm: "ED25519",
            fingerprint: "SHA256:old",
            keyLine: "changed.example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
        )
        try TrustedHostStore.trust(old)
        let stored = TrustedHostStore.existingFingerprint(host: "changed.example.com", port: 22)
        XCTAssertEqual(
            ConnectionError.classify(
                """
                WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!
                The fingerprint for the ED25519 key sent by the remote host is
                SHA256:newFingerprintValue
                """,
                host: "changed.example.com",
                port: 22
            ),
            .hostKeyChanged(oldFingerprint: stored, newFingerprint: "SHA256:newFingerprintValue")
        )
        XCTAssertNotNil(stored)
    }

    func testTrustRewritesKeyLineToConnectionHost() throws {
        let probe = SSHHostKeyProbe(
            host: "10.0.0.8",
            port: 22,
            algorithm: "ED25519",
            fingerprint: "SHA256:test",
            keyLine: "other.example ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
        )
        try TrustedHostStore.trust(probe)
        XCTAssertNotNil(TrustedHostStore.existingFingerprint(host: "10.0.0.8", port: 22))
        let contents = try String(contentsOf: temporaryURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("10.0.0.8"))
    }

    func testTrustIsScopedToPortForSameHost() throws {
        let key = Data("port-scoped-host-key".utf8).base64EncodedString()
        let probe = SSHHostKeyProbe(
            host: "ports.example.test",
            port: 2222,
            algorithm: "ED25519",
            fingerprint: "unused-by-store",
            keyLine: "ports.example.test ssh-ed25519 \(key)"
        )

        try TrustedHostStore.trust(probe)

        XCTAssertTrue(TrustedHostStore.hasUsableHostName(host: probe.host, port: 2222))
        XCTAssertFalse(TrustedHostStore.hasUsableHostName(host: probe.host, port: 22))
        let contents = try String(contentsOf: temporaryURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("[ports.example.test]:2222"))
        XCTAssertFalse(contents.contains("[ports.example.test]:22,"))
    }

    func testTrustedInspectOneHundredTimesNeverInvokesKeyscanProvider() async throws {
        let key = Data("steady-state-host-key".utf8).base64EncodedString()
        let probe = SSHHostKeyProbe(
            host: "trusted.example.test",
            port: 22,
            algorithm: "ED25519",
            fingerprint: "unused-by-store",
            keyLine: "trusted.example.test ssh-ed25519 \(key)"
        )
        try TrustedHostStore.trust(probe)
        let config = makeConfig(host: probe.host, port: probe.port)

        for _ in 0..<100 {
            let decision = try await TrustedHostStore.inspect(
                config,
                forceScan: false
            ) { _, _, _ in
                throw UnexpectedScan.invoked
            }
            guard case .trusted(let storedProbe) = decision else {
                return XCTFail("Stored host must take the trusted fast path")
            }
            XCTAssertEqual(storedProbe.host, probe.host)
        }
    }

    func testForcedInspectScansAndBlocksChangedKey() async throws {
        let oldKey = Data("old-host-key".utf8).base64EncodedString()
        let newKey = Data("new-host-key".utf8).base64EncodedString()
        let oldProbe = SSHHostKeyProbe(
            host: "changed.example.test",
            port: 2222,
            algorithm: "ED25519",
            fingerprint: "unused-by-store",
            keyLine: "[changed.example.test]:2222 ssh-ed25519 \(oldKey)"
        )
        let newLine = "[changed.example.test]:2222 ssh-ed25519 \(newKey)"
        let newFingerprint = try XCTUnwrap(TrustedHostStore.fingerprint(for: newLine))
        try TrustedHostStore.trust(oldProbe)
        let config = makeConfig(host: oldProbe.host, port: oldProbe.port)

        let decision = try await TrustedHostStore.inspect(
            config,
            forceScan: true
        ) { host, port, _ in
            SSHHostKeyProbe(
                host: host,
                port: port,
                algorithm: "ED25519",
                fingerprint: newFingerprint,
                keyLine: newLine
            )
        }

        guard case .changed(let oldFingerprint, let scannedProbe) = decision else {
            return XCTFail("A forced scan must block a changed key")
        }
        XCTAssertNotEqual(oldFingerprint, scannedProbe.fingerprint)
        XCTAssertEqual(scannedProbe.fingerprint, newFingerprint)
    }

    func testSameFingerprintOnDifferentHostStillRequiresExplicitTrust() async throws {
        let key = Data("shared-host-key".utf8).base64EncodedString()
        try TrustedHostStore.trust(
            SSHHostKeyProbe(
                host: "first.example.test",
                port: 22,
                algorithm: "ED25519",
                fingerprint: "unused-by-store",
                keyLine: "first.example.test ssh-ed25519 \(key)"
            )
        )
        let second = makeConfig(host: "second.example.test", port: 22)
        let decision = try await TrustedHostStore.inspect(
            second,
            forceScan: true
        ) { host, port, _ in
            SSHHostKeyProbe(
                host: host,
                port: port,
                algorithm: "ED25519",
                fingerprint: TrustedHostStore.fingerprint(
                    for: "\(host) ssh-ed25519 \(key)"
                ) ?? "",
                keyLine: "\(host) ssh-ed25519 \(key)"
            )
        }

        guard case .unknown(let probe) = decision else {
            return XCTFail("Trust must remain scoped to host and port")
        }
        XCTAssertEqual(probe.host, "second.example.test")
        XCTAssertFalse(TrustedHostStore.hasUsableHostName(host: probe.host, port: probe.port))
    }

    private func makeConfig(host: String, port: Int) -> ServerConnectionConfig {
        ServerConnectionConfig(
            id: UUID(),
            credentialID: UUID(),
            name: "Test",
            host: host,
            port: port,
            username: "tester",
            authentication: .privateKey,
            privateKeyPath: ""
        )
    }

    private enum UnexpectedScan: Error {
        case invoked
    }
}

@MainActor
final class HostTrustCoordinatorTests: XCTestCase {
    func testConcurrentRequestsStayFIFOAndResumeTheirOwnOperations() async throws {
        let configs = ["first.test", "second.test", "third.test"].map(makeConfig)
        let coordinator = HostTrustCoordinator(
            inspector: { config, _ in
                .unknown(Self.probe(for: config))
            },
            truster: { _, _ in }
        )

        let first = Task { @MainActor in
            try await coordinator.authorize(configs[0], source: .monitoring)
            return configs[0].id
        }
        await waitForCurrent(configs[0].id, in: coordinator)
        let second = Task { @MainActor in
            try await coordinator.authorize(configs[1], source: .sftp)
            return configs[1].id
        }
        await waitForQueueCount(2, in: coordinator)
        let third = Task { @MainActor in
            try await coordinator.authorize(configs[2], source: .terminal)
            return configs[2].id
        }
        await waitForQueueCount(3, in: coordinator)

        XCTAssertEqual(coordinator.current?.serverID, configs[0].id)
        XCTAssertEqual(coordinator.current?.source, .monitoring)
        let firstRequestID = try XCTUnwrap(coordinator.current?.id)
        _ = try await coordinator.accept(firstRequestID)
        let firstServerID = try await first.value
        XCTAssertEqual(firstServerID, configs[0].id)

        XCTAssertEqual(coordinator.current?.serverID, configs[1].id)
        XCTAssertEqual(coordinator.current?.source, .sftp)
        let secondRequestID = try XCTUnwrap(coordinator.current?.id)
        coordinator.reject(secondRequestID)
        do {
            _ = try await second.value
            XCTFail("Rejected operation must not resume as successful")
        } catch {
            XCTAssertEqual(error as? ConnectionError, .cancelled)
        }

        XCTAssertEqual(coordinator.current?.serverID, configs[2].id)
        XCTAssertEqual(coordinator.current?.source, .terminal)
        let thirdRequestID = try XCTUnwrap(coordinator.current?.id)
        _ = try await coordinator.accept(thirdRequestID)
        let thirdServerID = try await third.value
        XCTAssertEqual(thirdServerID, configs[2].id)
        XCTAssertNil(coordinator.current)
        XCTAssertEqual(coordinator.queuedCount, 0)
    }

    func testChangedRequestKeepsOldAndNewFingerprintBoundToSource() async throws {
        let config = makeConfig("changed.test")
        let probe = Self.probe(for: config)
        let coordinator = HostTrustCoordinator(
            inspector: { _, _ in
                .changed(oldFingerprint: "SHA256:old", probe: probe)
            },
            truster: { _, _ in }
        )
        let operation = Task { @MainActor in
            try await coordinator.authorize(config, source: .sshTest)
        }
        await waitForCurrent(config.id, in: coordinator)

        XCTAssertTrue(coordinator.current?.replacing == true)
        XCTAssertEqual(coordinator.current?.oldFingerprint, "SHA256:old")
        XCTAssertEqual(coordinator.current?.probe.fingerprint, probe.fingerprint)
        XCTAssertEqual(coordinator.current?.source, .sshTest)

        let requestID = try XCTUnwrap(coordinator.current?.id)
        _ = try await coordinator.accept(requestID)
        try await operation.value
    }

    private func waitForCurrent(
        _ serverID: UUID,
        in coordinator: HostTrustCoordinator
    ) async {
        for _ in 0..<100 {
            if coordinator.current?.serverID == serverID { return }
            await Task.yield()
        }
        XCTFail("Trust request did not become current")
    }

    private func waitForQueueCount(
        _ count: Int,
        in coordinator: HostTrustCoordinator
    ) async {
        for _ in 0..<100 {
            if coordinator.queuedCount == count { return }
            await Task.yield()
        }
        XCTFail("Trust queue did not reach expected count")
    }

    private func makeConfig(_ host: String) -> ServerConnectionConfig {
        ServerConnectionConfig(
            id: UUID(),
            credentialID: UUID(),
            name: "Test",
            host: host,
            port: 22,
            username: "tester",
            authentication: .privateKey,
            privateKeyPath: ""
        )
    }

    nonisolated private static func probe(for config: ServerConnectionConfig) -> SSHHostKeyProbe {
        SSHHostKeyProbe(
            host: config.host,
            port: config.port,
            algorithm: "ED25519",
            fingerprint: "SHA256:\(config.id.uuidString)",
            keyLine: "\(config.host) ssh-ed25519 AAAA"
        )
    }
}

final class TerminalHostKeyFailureDetectorTests: XCTestCase {
    func testDetectsFragmentedChangedKeyWarningOncePerConnection() {
        var detector = TerminalHostKeyFailureDetector()
        let first = Array("WARNING: REMOTE HOST IDENTIFI".utf8)
        let second = Array("CATION HAS CHANGED!".utf8)

        XCTAssertFalse(detector.ingest(first[...]))
        XCTAssertTrue(detector.ingest(second[...]))
        XCTAssertFalse(detector.ingest(second[...]))

        detector.reset()
        XCTAssertTrue(detector.ingest(Array("Offending ED25519 key".utf8)[...]))
    }
}

final class MonitoringCoordinatorTests: XCTestCase {
    func testCompletingOneOperationImmediatelyRefillsBoundedQueue() async {
        let probe = MonitoringOperationProbe()
        let coordinator = MonitoringCoordinator(
            maximumConcurrency: 2,
            jitter: { _ in 0 },
            operation: { serverID in await probe.run(serverID) }
        )
        let serverIDs = (0..<4).map { _ in UUID() }
        await coordinator.configure(
            targets: serverIDs.map { MonitoringScheduleTarget(serverID: $0, enabled: true) },
            interval: 1_000
        )
        await waitUntil { await probe.startedCount() == 2 }
        let initiallyActive = await probe.pendingIDs()
        XCTAssertEqual(initiallyActive.count, 2)

        await probe.complete(initiallyActive[0], succeeded: true)
        await waitUntil { await probe.startedCount() == 3 }
        let afterRefill = await probe.pendingIDs()
        XCTAssertEqual(afterRefill.count, 2)
        XCTAssertTrue(afterRefill.contains(initiallyActive[1]))
        let maximumActiveAfterRefill = await probe.maximumActiveCount()
        XCTAssertEqual(maximumActiveAfterRefill, 2)

        await drain(serverIDs: serverIDs, coordinator: coordinator, probe: probe)
        await coordinator.stop()
    }

    func testManualRequestPromotesQueuedServerAndRunningServerIsDeduplicated() async throws {
        let probe = MonitoringOperationProbe()
        let coordinator = MonitoringCoordinator(
            maximumConcurrency: 1,
            jitter: { _ in 0 },
            operation: { serverID in await probe.run(serverID) }
        )
        let first = UUID()
        let background = UUID()
        let promoted = UUID()
        await coordinator.configure(
            targets: [first, background, promoted].map {
                MonitoringScheduleTarget(serverID: $0, enabled: true)
            },
            interval: 1_000
        )
        await waitUntil { await probe.startedIDs() == [first] }

        let promotedRequest = Task {
            await coordinator.refresh(serverIDs: [promoted], priority: .manual)
        }
        await waitUntil {
            await coordinator.queuedPriority(for: promoted) == .manual
        }
        let duplicateRequest = Task {
            await coordinator.refresh(serverIDs: [first], priority: .manual)
        }
        await waitUntil { await coordinator.waiterCount(for: first) == 1 }

        await probe.complete(first, succeeded: true)
        let duplicateResult = await duplicateRequest.value
        XCTAssertEqual(duplicateResult[first], true)
        await waitUntil { await probe.startedCount() == 2 }
        let startsAfterPromotion = await probe.startedIDs()
        let firstStartCount = await probe.startCount(for: first)
        XCTAssertEqual(startsAfterPromotion[1], promoted)
        XCTAssertEqual(firstStartCount, 1)

        await probe.complete(promoted, succeeded: true)
        let promotedResult = await promotedRequest.value
        XCTAssertEqual(promotedResult[promoted], true)
        await waitUntil { await probe.startedCount() == 3 }
        let finalStarts = await probe.startedIDs()
        XCTAssertEqual(finalStarts[2], background)
        await probe.complete(background, succeeded: true)
        await waitUntil { await coordinator.activeCount == 0 }
        await coordinator.stop()
    }

    func testLowPowerModeReducesNewMonitoringConcurrency() async {
        let probe = MonitoringOperationProbe()
        let coordinator = MonitoringCoordinator(
            maximumConcurrency: 5,
            jitter: { _ in 0 },
            operation: { serverID in await probe.run(serverID) }
        )
        await coordinator.setLowPowerMode(true)
        let serverIDs = (0..<5).map { _ in UUID() }
        await coordinator.configure(
            targets: serverIDs.map { MonitoringScheduleTarget(serverID: $0, enabled: true) },
            interval: 1_000
        )
        await waitUntil { await probe.startedCount() == 2 }
        let lowPowerActiveCount = await coordinator.activeCount
        XCTAssertEqual(lowPowerActiveCount, 2)

        await drain(serverIDs: serverIDs, coordinator: coordinator, probe: probe)
        let lowPowerMaximumActive = await probe.maximumActiveCount()
        XCTAssertEqual(lowPowerMaximumActive, 2)
        await coordinator.stop()
    }

    func testSleepCancelsMonitoringAndWakeRestartsIt() async {
        let probe = CancellableMonitoringProbe()
        let serverID = UUID()
        let coordinator = MonitoringCoordinator(
            maximumConcurrency: 1,
            jitter: { _ in 0 },
            operation: { id in await probe.run(id) }
        )
        await coordinator.configure(
            targets: [MonitoringScheduleTarget(serverID: serverID, enabled: true)],
            interval: 1_000
        )
        await waitUntil { await probe.startedCount() == 1 }

        await coordinator.setSleeping(true)
        await waitUntil { await probe.cancelledCount() == 1 }
        let sleepingQueueCount = await coordinator.queuedCount
        XCTAssertEqual(sleepingQueueCount, 0)

        await coordinator.setSleeping(false)
        await waitUntil { await probe.startedCount() == 2 }
        await coordinator.stop()
        await waitUntil { await probe.cancelledCount() == 2 }
    }

    func testNetworkAndSleepSuspensionsResumeOnlyAfterBothClear() async {
        let probe = CancellableMonitoringProbe()
        let serverID = UUID()
        let coordinator = MonitoringCoordinator(
            maximumConcurrency: 1,
            jitter: { _ in 0 },
            operation: { id in await probe.run(id) }
        )
        await coordinator.configure(
            targets: [MonitoringScheduleTarget(serverID: serverID, enabled: true)],
            interval: 1_000
        )
        await waitUntil { await probe.startedCount() == 1 }

        await coordinator.setNetworkAvailable(false)
        await waitUntil { await probe.cancelledCount() == 1 }
        await coordinator.setSleeping(true)
        await coordinator.setNetworkAvailable(true)
        try? await Task.sleep(for: .milliseconds(100))
        let startsWhileSleeping = await probe.startedCount()
        XCTAssertEqual(startsWhileSleeping, 1)

        await coordinator.setSleeping(false)
        await waitUntil { await probe.startedCount() == 2 }
        await coordinator.stop()
        await waitUntil { await probe.cancelledCount() == 2 }
    }

    func testFailureBackoffSequenceAndCap() {
        XCTAssertEqual(
            (1...7).map { MonitoringBackoff.delay(after: $0) },
            [5, 15, 30, 60, 300, 300, 300]
        )
        XCTAssertLessThanOrEqual(MonitoringCoordinator.maximumDispatchesPerSecond, 25)
    }

    private func drain(
        serverIDs: [UUID],
        coordinator: MonitoringCoordinator,
        probe: MonitoringOperationProbe
    ) async {
        let initialPending = Set(await probe.pendingIDs())
        var completed = Set(
            (await probe.startedIDs()).filter { !initialPending.contains($0) }
        )
        while completed.count < serverIDs.count {
            await waitUntil {
                !(await probe.pendingIDs()).filter { !completed.contains($0) }.isEmpty
            }
            guard let next = (await probe.pendingIDs()).first(where: { !completed.contains($0) }) else {
                return
            }
            completed.insert(next)
            await probe.complete(next, succeeded: true)
        }
        await waitUntil { await coordinator.activeCount == 0 }
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition was not met before timeout")
    }
}

private actor MonitoringOperationProbe {
    private var starts: [UUID] = []
    private var active = 0
    private var maximumActive = 0
    private var pending: [UUID: CheckedContinuation<Bool, Never>] = [:]

    func run(_ serverID: UUID) async -> Bool {
        starts.append(serverID)
        active += 1
        maximumActive = max(maximumActive, active)
        let succeeded = await withCheckedContinuation { continuation in
            pending[serverID] = continuation
        }
        active -= 1
        return succeeded
    }

    func complete(_ serverID: UUID, succeeded: Bool) {
        pending.removeValue(forKey: serverID)?.resume(returning: succeeded)
    }

    func startedIDs() -> [UUID] { starts }
    func startedCount() -> Int { starts.count }
    func pendingIDs() -> [UUID] { starts.filter { pending[$0] != nil } }
    func maximumActiveCount() -> Int { maximumActive }
    func startCount(for serverID: UUID) -> Int { starts.filter { $0 == serverID }.count }
}

private actor CancellableMonitoringProbe {
    private var started = 0
    private var cancelled = 0

    func run(_ serverID: UUID) async -> Bool {
        _ = serverID
        started += 1
        do {
            try await Task.sleep(for: .seconds(60))
            return true
        } catch {
            cancelled += 1
            return false
        }
    }

    func startedCount() -> Int { started }
    func cancelledCount() -> Int { cancelled }
}

final class SFTPPathTests: XCTestCase {
    func testQuotesSpecialCharactersAndNavigatesUnicodePaths() {
        XCTAssertEqual(
            SFTPService.quote(#"/var/www/发布 包/notes".txt"#),
            #""/var/www/发布 包/notes\".txt""#
        )
        XCTAssertEqual(
            RemotePath.child("日志 1.log", of: "/var/www"),
            "/var/www/日志 1.log"
        )
        XCTAssertEqual(
            RemotePath.uniquedName("index.html", existing: ["index.html", "index 2.html"]),
            "index 3.html"
        )
    }
}

final class MonitoringPrivacyTests: XCTestCase {
    func testParserOmitsGeoWhenPayloadMissing() throws {
        let output = """
        cpu=10
        cores=2
        load1=0.1
        load5=0.2
        load15=0.3
        mem_total_kb=1024
        mem_available_kb=512
        swap_total_kb=0
        swap_free_kb=0
        disk_used=1
        disk_total=2
        net_rx=0
        net_tx=0
        uptime=1 min
        distro=Debian
        kernel=Linux
        users=1
        processes=10
        """
        let snapshot = try MonitoringResponseParser.parse(output)
        XCTAssertNil(snapshot.geoLocation)
    }

    func testRemoteCommandHonorsDisableGeo() {
        XCTAssertTrue(SSHMonitoringService.remoteCommand.contains("SERVERDASH_DISABLE_GEO"))
        XCTAssertTrue(SSHMonitoringService.remoteCommand.contains("rm -f \"$geo_cache\""))
    }
}

final class PersistenceSchemaTests: XCTestCase {
    func testVersionedSchemaCreatesNewEntities() throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(
            TrustedHostKey(
                host: "a.example",
                port: 22,
                algorithm: "ED25519",
                fingerprint: "SHA256:test",
                keyLine: "a.example ssh-ed25519 AAAA"
            )
        )
        context.insert(
            TerminalSessionHistory(
                serverID: UUID(),
                serverName: "a.example",
                result: "closed"
            )
        )
        try context.save()

        XCTAssertEqual(try context.fetch(FetchDescriptor<TrustedHostKey>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<TerminalSessionHistory>()).count, 1)
        XCTAssertEqual(PersistenceController.currentSchemaVersion, 2)
    }
}

@MainActor
final class TerminalRegistryLifecycleTests: XCTestCase {
    func testSwitchingSelectionDoesNotTerminateExistingSession() {
        let server = ServerRecord(
            name: "Demo",
            host: "127.0.0.1",
            username: "root"
        )
        let registry = TerminalSessionRegistry()
        let controller = TerminalSessionController(server: server, attachProcess: false)
        registry.registerForTesting(controller)

        let reused = registry.open(for: server, forceNew: false)
        XCTAssertTrue(reused === controller)
        XCTAssertEqual(registry.controllers.count, 1)
        XCTAssertNotEqual(controller.status, .disconnected)
    }
}

final class MainContentRouteTests: XCTestCase {
    func testServerDetailReturnsToItsEntrySection() {
        let serverID = UUID()
        let origins: [SidebarDestination] = [.dashboard, .machines, .terminal]

        for origin in origins {
            let detail = MainContentRoute.server(
                id: serverID,
                origin: origin,
                mode: origin == .terminal ? .terminal : .monitor
            )

            XCTAssertEqual(detail.sidebarDestination, origin)
            XCTAssertEqual(detail.serverID, serverID)
            XCTAssertEqual(detail.returningToOrigin, .section(origin))
        }
    }

    func testServerRouteKeepsModeIndependentFromOrigin() {
        let serverID = UUID()

        XCTAssertEqual(
            MainContentRoute.server(
                id: serverID,
                origin: .dashboard,
                mode: .terminal
            ).detailMode,
            .terminal
        )
        XCTAssertEqual(
            MainContentRoute.server(
                id: serverID,
                origin: .machines,
                mode: .sftp
            ).detailMode,
            .sftp
        )
    }

    func testSidebarSwitchAndDeletionResolveToSectionRoutes() {
        let detail = MainContentRoute.server(
            id: UUID(),
            origin: .dashboard,
            mode: .monitor
        )
        let switched = MainContentRoute.section(SidebarDestination.sshKeys)
        let afterDeletion = detail.returningToOrigin

        XCTAssertEqual(switched, .section(.sshKeys))
        XCTAssertNil(switched.serverID)
        XCTAssertEqual(afterDeletion, .section(.dashboard))
    }
}

@MainActor
final class ServerRuntimeStateTests: XCTestCase {
    func testResultPublicationIsAtomic() {
        let runtime = ServerRuntimeState(serverID: UUID())
        var emissions: [ServerRenderState] = []
        let observation = runtime.$renderState
            .dropFirst()
            .sink { emissions.append($0) }
        var snapshot = ServerSnapshot.empty
        snapshot.capturedAt = Date(timeIntervalSince1970: 1_000)
        snapshot.cpuUsage = 42
        let point = MetricPoint(
            date: snapshot.capturedAt,
            cpu: snapshot.cpuUsage,
            memory: 25,
            download: 1,
            upload: 2
        )
        var result = runtime.renderState
        result.status = .online
        result.snapshot = snapshot
        result.history = [point]
        result.error = nil
        result.isRefreshing = false
        result.lastSuccessfulMonitorAt = snapshot.capturedAt

        runtime.publish(result)

        XCTAssertEqual(runtime.publicationCount, 1)
        XCTAssertEqual(emissions, [result])
        XCTAssertTrue(runtime.renderState.hasSnapshot)
        withExtendedLifetime(observation) {}
    }

    func testPublishingIdenticalStateDoesNotEmit() {
        let runtime = ServerRuntimeState(serverID: UUID())
        var emissionCount = 0
        let observation = runtime.$renderState
            .dropFirst()
            .sink { _ in emissionCount += 1 }

        runtime.publish(runtime.renderState)

        XCTAssertEqual(runtime.publicationCount, 0)
        XCTAssertEqual(emissionCount, 0)
        withExtendedLifetime(observation) {}
    }

    func testOneServerUpdateDoesNotPublishOtherRuntimeStates() {
        let runtimes = (0..<100).map { _ in ServerRuntimeState(serverID: UUID()) }
        var changed = runtimes[37].renderState
        changed.status = .connecting
        changed.isRefreshing = true

        runtimes[37].publish(changed)

        XCTAssertEqual(runtimes.map(\.publicationCount).filter { $0 > 0 }.count, 1)
        XCTAssertEqual(runtimes[37].publicationCount, 1)
        XCTAssertTrue(
            runtimes.enumerated().allSatisfy { index, runtime in
                index == 37 || runtime.publicationCount == 0
            }
        )
    }

    func testFleetSummaryUpdatesIncrementally() {
        let summary = FleetMonitoringSummaryState()
        var first = ServerRenderState()
        first.status = .online
        first.snapshot.cpuUsage = 40
        first.isRefreshing = true

        summary.replace(old: nil, with: first)

        XCTAssertEqual(summary.value.onlineCount, 1)
        XCTAssertEqual(summary.value.issueCount, 0)
        XCTAssertEqual(summary.value.refreshingCount, 1)
        XCTAssertEqual(summary.value.averageCPU, 40, accuracy: 0.001)

        var updated = first
        updated.snapshot.cpuUsage = 60
        updated.isRefreshing = false
        summary.replace(old: first, with: updated)

        XCTAssertEqual(summary.value.onlineCount, 1)
        XCTAssertEqual(summary.value.refreshingCount, 0)
        XCTAssertEqual(summary.value.averageCPU, 60, accuracy: 0.001)

        var failed = updated
        failed.status = .failed
        summary.replace(old: updated, with: failed)

        XCTAssertEqual(summary.value.onlineCount, 0)
        XCTAssertEqual(summary.value.issueCount, 1)
        XCTAssertEqual(summary.value.averageCPU, 0, accuracy: 0.001)

        let publicationsBeforeNoOp = summary.publicationCount
        summary.replace(old: failed, with: failed)
        XCTAssertEqual(summary.publicationCount, publicationsBeforeNoOp)

        summary.replace(old: failed, with: nil)
        XCTAssertEqual(summary.value.issueCount, 0)
    }

    func testFailureStateCanPreserveLastSuccessfulSnapshot() {
        let runtime = ServerRuntimeState(serverID: UUID())
        var successful = runtime.renderState
        successful.snapshot.capturedAt = Date(timeIntervalSince1970: 2_000)
        successful.snapshot.cpuUsage = 73
        successful.status = .online
        runtime.publish(successful)

        var failed = runtime.renderState
        failed.status = .failed
        failed.error = "连接失败"
        failed.isRefreshing = false
        runtime.publish(failed)

        XCTAssertEqual(runtime.renderState.snapshot, successful.snapshot)
        XCTAssertEqual(runtime.renderState.snapshot.cpuUsage, 73)
        XCTAssertTrue(runtime.renderState.hasSnapshot)
    }
}

final class MonitorPresentationTests: XCTestCase {
    func testSeverityThresholds() {
        XCTAssertEqual(MonitorSeverity.percentage(0), .normal)
        XCTAssertEqual(MonitorSeverity.percentage(74.9), .normal)
        XCTAssertEqual(MonitorSeverity.percentage(75), .warning)
        XCTAssertEqual(MonitorSeverity.percentage(89.9), .warning)
        XCTAssertEqual(MonitorSeverity.percentage(90), .critical)
    }

    func testMemoryBreakdownSeparatesCacheAndBuffers() {
        var snapshot = ServerSnapshot.empty
        snapshot.memoryUsedBytes = 4_000
        snapshot.memoryCachedBytes = 3_000
        snapshot.memoryBuffersBytes = 1_000
        snapshot.memoryFreeBytes = 2_000

        let breakdown = MonitorPresentation.memoryBreakdown(snapshot)

        XCTAssertEqual(breakdown.used, 4_000)
        XCTAssertEqual(breakdown.cached, 2_000)
        XCTAssertEqual(breakdown.buffers, 1_000)
        XCTAssertEqual(breakdown.free, 2_000)
    }

    func testPinnedFilesystemSortsBeforeRootAndOtherVolumes() {
        let root = FilesystemMetric(
            device: "/dev/vda1",
            mountPoint: "/",
            filesystemType: "ext4",
            usedBytes: 50,
            totalBytes: 100
        )
        let data = FilesystemMetric(
            device: "/dev/vdb1",
            mountPoint: "/data",
            filesystemType: "xfs",
            usedBytes: 20,
            totalBytes: 100
        )
        let backup = FilesystemMetric(
            device: "/dev/vdc1",
            mountPoint: "/backup",
            filesystemType: "ext4",
            usedBytes: 10,
            totalBytes: 100
        )

        let ordered = MonitorPresentation.orderedFilesystems(
            [backup, root, data],
            pinnedMountPoint: "/data"
        )

        XCTAssertEqual(ordered.map(\.mountPoint), ["/data", "/", "/backup"])
    }

    func testProcessSearchAndSorting() {
        let processes = [
            ProcessMetric(
                name: "nginx",
                pid: 20,
                cpu: 8,
                memory: 3,
                user: "www",
                arguments: "nginx worker",
                threadCount: 2
            ),
            ProcessMetric(
                name: "postgres",
                pid: 10,
                cpu: 2,
                memory: 12,
                user: "db",
                arguments: "postgres writer",
                threadCount: 4
            )
        ]

        let byCPU = MonitorPresentation.processes(
            processes,
            searchText: "",
            sortField: .cpu,
            descending: true
        )
        let search = MonitorPresentation.processes(
            processes,
            searchText: "writer",
            sortField: .pid,
            descending: false
        )

        XCTAssertEqual(byCPU.map(\.name), ["nginx", "postgres"])
        XCTAssertEqual(search.map(\.name), ["postgres"])
    }

    func testDockerSummaryAndFilter() {
        let containers = [
            DockerContainerMetric(
                id: "1",
                name: "web",
                image: "nginx:latest",
                state: "running",
                status: "Up"
            ),
            DockerContainerMetric(
                id: "2",
                name: "db",
                image: "postgres:16",
                state: "exited",
                status: "Exited"
            ),
            DockerContainerMetric(
                id: "3",
                name: "cache",
                image: "redis:7",
                state: "paused",
                status: "Paused"
            )
        ]

        XCTAssertEqual(
            MonitorPresentation.dockerSummary(containers),
            DockerStatusSummary(running: 1, stopped: 1, other: 1)
        )
        XCTAssertEqual(
            MonitorPresentation.dockerContainers(
                containers,
                searchText: "post",
                filter: .stopped
            ).map(\.name),
            ["db"]
        )
    }

    func testEmptyGPUSummary() {
        let summary = MonitorPresentation.gpuSummary(.empty)

        XCTAssertEqual(
            summary,
            GPUStatusSummary(
                deviceCount: 0,
                processCount: 0,
                peakUtilization: nil,
                peakTemperature: nil
            )
        )
    }

    func testSingleGPUWithoutTemperatureSummary() {
        var snapshot = ServerSnapshot.empty
        snapshot.gpus = [
            GPUMetric(
                index: 0,
                uuid: "gpu-0",
                name: "Test GPU",
                utilization: 42,
                memoryUsedBytes: 1_024,
                memoryTotalBytes: 4_096,
                fanPercent: nil,
                temperatureCelsius: nil,
                powerWatts: nil,
                powerLimitWatts: nil
            )
        ]

        let summary = MonitorPresentation.gpuSummary(snapshot)

        XCTAssertEqual(summary.deviceCount, 1)
        XCTAssertEqual(summary.peakUtilization, 42)
        XCTAssertNil(summary.peakTemperature)
    }

    func testMultipleGPUSummaryUsesPeakValuesAndProcessCount() {
        var snapshot = ServerSnapshot.empty
        snapshot.gpus = [
            GPUMetric(
                index: 0,
                uuid: "gpu-0",
                name: "GPU 0",
                utilization: 35,
                memoryUsedBytes: 1_024,
                memoryTotalBytes: 4_096,
                fanPercent: 30,
                temperatureCelsius: 62,
                powerWatts: 90,
                powerLimitWatts: 200
            ),
            GPUMetric(
                index: 1,
                uuid: "gpu-1",
                name: "GPU 1",
                utilization: 88,
                memoryUsedBytes: 2_048,
                memoryTotalBytes: 4_096,
                fanPercent: 60,
                temperatureCelsius: 79,
                powerWatts: 170,
                powerLimitWatts: 200
            )
        ]
        snapshot.gpuProcesses = [
            GPUProcessMetric(
                gpuID: "gpu-1",
                pid: 100,
                name: "worker",
                memoryBytes: 512
            ),
            GPUProcessMetric(
                gpuID: "gpu-1",
                pid: 101,
                name: "worker-2",
                memoryBytes: 256
            )
        ]

        let summary = MonitorPresentation.gpuSummary(snapshot)

        XCTAssertEqual(summary.deviceCount, 2)
        XCTAssertEqual(summary.processCount, 2)
        XCTAssertEqual(summary.peakUtilization, 88)
        XCTAssertEqual(summary.peakTemperature, 79)
    }
}

final class ConnectionProcessControllerTests: XCTestCase {
    func testReturnsOutputBelowConfiguredLimit() async throws {
        let controller = ConnectionProcessController(
            limiter: ConnectionLimiter(maxGlobal: 1, maxPerServer: 1)
        )
        let result = try await controller.run(
            ProcessRunRequest(
                executable: "/usr/bin/printf",
                arguments: ["streamed-output"],
                environment: ProcessInfo.processInfo.environment,
                totalTimeout: 2,
                maxOutputBytes: 1_024,
                module: .monitoring
            )
        )

        XCTAssertEqual(result.output, "streamed-output")
        XCTAssertEqual(result.status, 0)
        let recent = await controller.recentProcessSummaries()
        XCTAssertEqual(recent.last?.terminationReason, .exited)
    }

    func testCancelTerminatesLongRunningProcess() async {
        let task = Task {
            try await ConnectionProcessController.shared.run(
                ProcessRunRequest(
                    executable: "/bin/sleep",
                    arguments: ["30"],
                    environment: ProcessInfo.processInfo.environment,
                    totalTimeout: 60,
                    maxOutputBytes: 1_024,
                    module: .ssh
                )
            )
        }
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("取消后不应成功返回")
        } catch {
            XCTAssertTrue(
                error is CancellationError || (error as? ConnectionError) == .cancelled
            )
        }
    }

    func testStreamsOutputAndStopsAtLimitWithinOneSecond() async {
        let controller = ConnectionProcessController(
            limiter: ConnectionLimiter(maxGlobal: 1, maxPerServer: 1),
            terminationGrace: 0.2
        )
        let started = Date()

        do {
            _ = try await controller.run(
                ProcessRunRequest(
                    executable: "/usr/bin/yes",
                    arguments: [],
                    environment: ProcessInfo.processInfo.environment,
                    totalTimeout: 10,
                    maxOutputBytes: 65_536,
                    module: .monitoring
                )
            )
            XCTFail("无限输出应在达到上限时失败")
        } catch {
            XCTAssertEqual(error as? ConnectionError, .outputLimitExceeded)
        }

        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        let activeCount = await controller.activeProcessCount()
        XCTAssertEqual(activeCount, 0)
        let recent = await controller.recentProcessSummaries()
        XCTAssertEqual(recent.last?.terminationReason, .outputLimitExceeded)
    }

    func testStreamsStandardErrorAndStopsAtLimit() async {
        let controller = ConnectionProcessController(
            limiter: ConnectionLimiter(maxGlobal: 1, maxPerServer: 1),
            terminationGrace: 0.2
        )
        let started = Date()

        do {
            _ = try await controller.run(
                ProcessRunRequest(
                    executable: "/bin/sh",
                    arguments: ["-c", "while :; do printf x >&2; done"],
                    environment: ProcessInfo.processInfo.environment,
                    totalTimeout: 10,
                    maxOutputBytes: 65_536,
                    module: .monitoring
                )
            )
            XCTFail("无限错误输出应在达到上限时失败")
        } catch {
            XCTAssertEqual(error as? ConnectionError, .outputLimitExceeded)
        }

        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        let recent = await controller.recentProcessSummaries()
        XCTAssertEqual(recent.last?.terminationReason, .outputLimitExceeded)
    }

    func testTimeoutHasDistinctReasonAndStopsProcess() async {
        let controller = ConnectionProcessController(
            limiter: ConnectionLimiter(maxGlobal: 1, maxPerServer: 1),
            terminationGrace: 0.2
        )

        do {
            _ = try await controller.run(
                ProcessRunRequest(
                    executable: "/bin/sleep",
                    arguments: ["30"],
                    environment: ProcessInfo.processInfo.environment,
                    totalTimeout: 0.2,
                    maxOutputBytes: 1_024,
                    module: .ssh
                )
            )
            XCTFail("超时进程不应成功")
        } catch {
            XCTAssertEqual(error as? ConnectionError, .timeout)
        }

        let activeCount = await controller.activeProcessCount()
        XCTAssertEqual(activeCount, 0)
        let recent = await controller.recentProcessSummaries()
        XCTAssertEqual(recent.last?.terminationReason, .timeout)
    }

    func testServerScopedTerminationLeavesOtherServerRunning() async {
        let controller = ConnectionProcessController(
            limiter: ConnectionLimiter(maxGlobal: 2, maxPerServer: 1),
            terminationGrace: 0.2
        )
        let firstServerID = UUID()
        let secondServerID = UUID()
        let first = longRunningTask(controller: controller, serverID: firstServerID)
        let second = longRunningTask(controller: controller, serverID: secondServerID)

        let bothStarted = await waitUntil { await controller.activeProcessCount() == 2 }
        XCTAssertTrue(bothStarted)
        let summaries = await controller.activeProcessSummaries()
        XCTAssertEqual(Set(summaries.compactMap(\.serverID)), [firstServerID, secondServerID])
        XCTAssertTrue(summaries.allSatisfy { $0.processGroupIdentifier != nil })
        XCTAssertTrue(summaries.allSatisfy { $0.terminationReason == .running })
        XCTAssertTrue(summaries.allSatisfy { $0.module == .ssh })

        await controller.terminateAll(for: firstServerID)
        await assertCancelled(first)
        let firstStopped = await waitUntil {
            await controller.activeProcessCount(for: firstServerID) == 0
        }
        XCTAssertTrue(firstStopped)
        let secondActiveCount = await controller.activeProcessCount(for: secondServerID)
        XCTAssertEqual(secondActiveCount, 1)

        second.cancel()
        await assertCancelled(second)
        let allStopped = await waitUntil { await controller.activeProcessCount() == 0 }
        XCTAssertTrue(allStopped)
    }

    func testCancellationEscalatesAndLeavesNoChildProcess() async throws {
        let controller = ConnectionProcessController(
            limiter: ConnectionLimiter(maxGlobal: 1, maxPerServer: 1),
            terminationGrace: 0.2
        )
        let pidURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerDash-child-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidURL) }
        let script = "trap '' TERM; sleep 30 & child=$!; printf '%s' \"$child\" > \"$1\"; wait"
        let task = Task {
            try await controller.run(
                ProcessRunRequest(
                    executable: "/bin/sh",
                    arguments: ["-c", script, "serverdash-test", pidURL.path],
                    environment: ProcessInfo.processInfo.environment,
                    totalTimeout: 30,
                    maxOutputBytes: 1_024,
                    module: .ssh
                )
            )
        }

        let childPIDWasWritten = await waitUntil {
            FileManager.default.fileExists(atPath: pidURL.path)
        }
        XCTAssertTrue(childPIDWasWritten)
        let childPIDText = try String(contentsOf: pidURL, encoding: .utf8)
        let childPID = try XCTUnwrap(Int32(childPIDText))
        let cancelledAt = Date()
        task.cancel()
        await assertCancelled(task)
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 1)

        let childExited = await waitUntil(timeout: 2) {
            kill(childPID, 0) == -1 && errno == ESRCH
        }
        XCTAssertTrue(childExited)
        let activeCount = await controller.activeProcessCount()
        XCTAssertEqual(activeCount, 0)
        let recent = await controller.recentProcessSummaries()
        XCTAssertEqual(recent.last?.terminationReason, .cancelled)
    }

    private func longRunningTask(
        controller: ConnectionProcessController,
        serverID: UUID
    ) -> Task<ProcessRunResult, Error> {
        Task {
            try await controller.run(
                ProcessRunRequest(
                    executable: "/bin/sleep",
                    arguments: ["30"],
                    environment: ProcessInfo.processInfo.environment,
                    totalTimeout: 60,
                    maxOutputBytes: 1_024,
                    serverID: serverID,
                    module: .ssh
                )
            )
        }
    }

    private func assertCancelled(
        _ task: Task<ProcessRunResult, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("终止后的进程不应成功返回", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ConnectionError, .cancelled, file: file, line: line)
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }
}

final class ConnectionLimiterTests: XCTestCase {
    func testWaitersResumeInFIFOOrderWithoutPolling() async throws {
        let limiter = ConnectionLimiter(maxGlobal: 1, maxPerServer: 1, waitTimeout: 2)
        let recorder = IntegerRecorder()
        try await limiter.acquire(serverID: nil)

        let first = Task {
            try await limiter.acquire(serverID: nil)
            await recorder.append(1)
        }
        await waitForWaiterCount(1, limiter: limiter)
        let second = Task {
            try await limiter.acquire(serverID: nil)
            await recorder.append(2)
        }
        await waitForWaiterCount(2, limiter: limiter)

        await limiter.release(serverID: nil)
        try await first.value
        await limiter.release(serverID: nil)
        try await second.value
        await limiter.release(serverID: nil)

        let values = await recorder.values()
        let waitingCount = await limiter.waitingCount()
        XCTAssertEqual(values, [1, 2])
        XCTAssertEqual(waitingCount, 0)
    }

    func testCancelledWaiterIsRemoved() async throws {
        let limiter = ConnectionLimiter(maxGlobal: 1, maxPerServer: 1, waitTimeout: 2)
        try await limiter.acquire(serverID: nil)
        let waiter = Task { try await limiter.acquire(serverID: nil) }
        await waitForWaiterCount(1, limiter: limiter)

        waiter.cancel()
        do {
            try await waiter.value
            XCTFail("已取消的等待者不应获得名额")
        } catch {
            XCTAssertTrue(
                error is CancellationError || (error as? ConnectionError) == .cancelled
            )
        }

        await waitForWaiterCount(0, limiter: limiter)
        let waitingCount = await limiter.waitingCount()
        XCTAssertEqual(waitingCount, 0)
        await limiter.release(serverID: nil)
    }

    func testWaiterTimeoutIsDistinct() async throws {
        let limiter = ConnectionLimiter(maxGlobal: 1, maxPerServer: 1, waitTimeout: 0.1)
        try await limiter.acquire(serverID: nil)

        do {
            try await limiter.acquire(serverID: nil)
            XCTFail("等待名额超时后不应成功")
        } catch {
            XCTAssertEqual(error as? ConnectionError, .timeout)
        }

        let waitingCount = await limiter.waitingCount()
        XCTAssertEqual(waitingCount, 0)
        await limiter.release(serverID: nil)
    }

    private func waitForWaiterCount(_ count: Int, limiter: ConnectionLimiter) async {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline, await limiter.waitingCount() != count {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor IntegerRecorder {
    private var storage: [Int] = []

    func append(_ value: Int) {
        storage.append(value)
    }

    func values() -> [Int] {
        storage
    }
}

final class PerformanceInstrumentationTests: XCTestCase {
    func testPerformanceOperationNamesAreFixedAndPrivacySafe() {
        let expected: Set<String> = [
            "app.launch_to_first_frame",
            "app.launch_to_interactive",
            "database.open",
            "monitor.collect",
            "monitor.parse",
            "monitor.publish",
            "monitor.scheduler_dispatch",
            "monitor.scheduler_cancel",
            "hostkey.inspect",
            "hostkey.scan",
            "ssh.handshake",
            "ssh.remote_command",
            "process.queue_wait",
            "process.run",
            "process.cancel_to_exit",
            "dashboard.card_body_update",
            "terminal.open",
            "terminal.interactive",
            "terminal.tab_switch",
            "sftp.list",
            "sftp.transfer",
            "sftp.progress_publish"
        ]
        let actual = PerformanceOperation.allCases.map(\.rawValue)

        XCTAssertEqual(Set(actual), expected)
        XCTAssertEqual(actual.count, expected.count)
        XCTAssertTrue(actual.allSatisfy {
            $0.range(of: #"^[a-z0-9_.]+$"#, options: .regularExpression) != nil
        })
    }

    func testMonitoringParserPerformanceBaseline() {
        let cores = (0..<16)
            .map { "core=\($0)|20|10|1|2|3" }
            .joined(separator: "\n")
        let processes = (0..<100)
            .map { "proc=\($0)|user|process-\($0)|2.5|1.5|4|synthetic" }
            .joined(separator: "\n")
        let payload = """
        cpu=42.5
        cores=16
        load1=1.1
        load5=0.8
        load15=0.5
        mem_total_kb=16777216
        mem_available_kb=8388608
        swap_total_kb=2097152
        swap_free_kb=1048576
        disk_used=48318382080
        disk_total=493921239040
        net_rx=1200000
        net_tx=240000
        \(cores)
        \(processes)
        """

        XCTAssertNoThrow(try MonitoringResponseParser.parse(payload))
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()]) {
            for _ in 0..<100 {
                _ = try! MonitoringResponseParser.parse(payload)
            }
        }
    }
}
