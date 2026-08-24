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
    func testRedactsSecretsButKeepsIPUnlessRequested() {
        let text = "password=super-secret host=203.0.113.10"
        XCTAssertTrue(DiagnosticRedactor.redact(text).contains("[REDACTED]"))
        XCTAssertTrue(DiagnosticRedactor.redact(text).contains("203.0.113.10"))
        XCTAssertTrue(DiagnosticRedactor.redact(text, hideIP: true).contains("[IP]"))
        XCTAssertFalse(
            DiagnosticRedactor.redact(
                "-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----"
            ).contains("abc")
        )
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
}
