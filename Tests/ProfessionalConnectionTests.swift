import Darwin
import SwiftData
import XCTest
@testable import ServerDash

final class SSHConfigImporterTests: XCTestCase {
    func testFinalValuesShowFirstMatchSourceOrderAndEveryUnsupportedDirective() throws {
        let fixture = try TemporarySSHConfigFixture(files: [
            "config": """
            Host prod-* !prod-bad
                HostName 10.0.0.20
                User deploy
                Port 2222
                IdentityFile ~/.ssh/prod_ed25519
                ServerAliveInterval 30
                ForwardAgent yes
                CanonicalizeHostname yes
            Host *
                User fallback
                Port 22
            """
        ])

        let report = SSHConfigImporter().resolve(alias: "prod-api", from: fixture.root)

        XCTAssertEqual(report.value(.hostName), "10.0.0.20")
        XCTAssertEqual(report.value(.user), "deploy")
        XCTAssertEqual(report.value(.port), "2222")
        XCTAssertEqual(report.value(.identityFile), "~/.ssh/prod_ed25519")
        XCTAssertEqual(report.value(.serverAliveInterval), "30")
        XCTAssertEqual(report.resolved(.user)?.source.line, 3)
        XCTAssertEqual(report.matches.map(\.patterns), [["prod-*", "!prod-bad"], ["*"]])
        XCTAssertEqual(Set(report.unsupported.map { $0.name.lowercased() }), [
            "forwardagent", "canonicalizehostname"
        ])
    }

    func testNegatedHostPatternDoesNotApplyBlock() throws {
        let fixture = try TemporarySSHConfigFixture(files: [
            "config": """
            Host prod-* !prod-bad
                User deploy
            Host *
                User fallback
            """
        ])

        let report = SSHConfigImporter().resolve(alias: "prod-bad", from: fixture.root)

        XCTAssertEqual(report.value(.user), "fallback")
        XCTAssertEqual(report.matches.map(\.patterns), [["*"]])
    }

    func testIncludeExpansionAndLoopAreBoundedAndReported() throws {
        let fixture = try TemporarySSHConfigFixture(files: [
            "config": """
            Include conf.d/*.conf
            Host target
                HostName target.internal
            """,
            "conf.d/10-base.conf": """
            Include ../config
            Host target
                User included-user
                UnsupportedLocaleDirective yes
            """
        ])

        let report = SSHConfigImporter().resolve(alias: "target", from: fixture.root)

        XCTAssertEqual(report.value(.user), "included-user")
        XCTAssertEqual(report.value(.hostName), "target.internal")
        XCTAssertTrue(report.issues.contains { $0.kind == .includeLoop })
        XCTAssertTrue(report.unsupported.contains {
            $0.name.lowercased() == "unsupportedlocaledirective"
        })
    }

    func testThreeHopProxyJumpImportKeepsIndependentEndpointIdentityAndTimeout() throws {
        let fixture = try TemporarySSHConfigFixture(files: [
            "config": """
            Host target
                HostName target.internal
                User app
                ProxyJump jump-3
            Host jump-3
                HostName jump3.internal
                User jump3
                Port 2203
                IdentityFile /tmp/jump3
                ProxyJump jump-2
            Host jump-2
                HostName jump2.internal
                User jump2
                Port 2202
                IdentityFile /tmp/jump2
                ProxyJump jump-1
            Host jump-1
                HostName jump1.internal
                User jump1
                Port 2201
                IdentityFile /tmp/jump1
                ServerAliveInterval 9
            """
        ])

        let result = try SSHConfigImporter().importRoute(alias: "target", from: fixture.root)

        XCTAssertEqual(result.endpoint.host, "target.internal")
        XCTAssertEqual(result.route.hops.map(\.endpoint.host), [
            "jump1.internal", "jump2.internal", "jump3.internal"
        ])
        XCTAssertEqual(result.route.hops.map(\.endpoint.port), [2201, 2202, 2203])
        XCTAssertEqual(result.route.hops.map(\.endpoint.username), ["jump1", "jump2", "jump3"])
        XCTAssertEqual(result.route.hops.first?.connectTimeout, 9)
        XCTAssertEqual(result.reports.map(\.alias), ["jump-1", "jump-2", "jump-3", "target"])
    }

    func testResyncNeverOverwritesExplicitUserFields() throws {
        var draft = SSHImportedConnectionDraft(
            host: SSHDraftValue(value: "old", origin: .imported),
            port: SSHDraftValue(value: 22, origin: .imported),
            user: SSHDraftValue(value: "explicit-user", origin: .userOverride),
            identityFile: SSHDraftValue(value: "/explicit/key", origin: .userOverride),
            proxyJump: SSHDraftValue(value: "", origin: .imported),
            serverAliveInterval: SSHDraftValue(value: 0, origin: .imported)
        )
        let fixture = try TemporarySSHConfigFixture(files: [
            "config": """
            Host target
                HostName new.internal
                Port 2200
                User imported-user
                IdentityFile /imported/key
                ProxyJump jump
            """
        ])
        let report = SSHConfigImporter().resolve(alias: "target", from: fixture.root)

        try draft.synchronize(with: report)

        XCTAssertEqual(draft.host.value, "new.internal")
        XCTAssertEqual(draft.port.value, 2200)
        XCTAssertEqual(draft.proxyJump.value, "jump")
        XCTAssertEqual(draft.user.value, "explicit-user")
        XCTAssertEqual(draft.identityFile.value, "/explicit/key")
    }

    func testImportedProxyCommandIsBlockedUntilExplicitConfirmation() throws {
        let route = ConnectionRoute(
            name: "Imported",
            importedProxyCommand: "helper %h %p",
            importedProxyCommandConfirmed: false
        )
        let endpoint = ConnectionEndpoint(host: "target", port: 22, username: "user")

        XCTAssertThrowsError(try route.validated(finalEndpoint: endpoint)) { error in
            XCTAssertEqual(error as? ConnectionRouteError, .proxyCommandRequiresConfirmation)
        }
        var confirmed = route
        confirmed.importedProxyCommandConfirmed = true
        XCTAssertNoThrow(try confirmed.validated(finalEndpoint: endpoint))
    }
}

final class ConnectionRouteProviderTests: XCTestCase {
    func testRouteLoopIsRejectedBeforeAnyProcessLaunch() {
        let repeated = ConnectionEndpoint(host: "same.internal", port: 22, username: "jump")
        let route = ConnectionRoute(
            name: "Loop",
            hops: [ConnectionHop(name: "Jump", endpoint: repeated, credential: .sshAgent)]
        )

        XCTAssertThrowsError(try route.validated(finalEndpoint: repeated)) { error in
            guard case .routeLoop = error as? ConnectionRouteError else {
                return XCTFail("Expected routeLoop, got \(error)")
            }
        }
    }

    func testAllBusinessPurposesUseSameMaterializedRouteRevision() throws {
        let key = try TemporaryReadableKey()
        let revision = UUID()
        let route = ConnectionRoute(
            revision: revision,
            name: "Two hop",
            hops: [
                ConnectionHop(
                    name: "Jump 1",
                    endpoint: ConnectionEndpoint(host: "jump1.internal", port: 2201, username: "one"),
                    credential: .externalPrivateKey(path: key.url.path),
                    connectTimeout: 4
                ),
                ConnectionHop(
                    name: "Jump 2",
                    endpoint: ConnectionEndpoint(host: "jump2.internal", port: 2202, username: "two"),
                    credential: .externalPrivateKey(path: key.url.path),
                    connectTimeout: 7
                )
            ]
        )
        let config = makeConfig(keyURL: key.url, route: route)
        let provider = SystemOpenSSHConnectionProvider()

        let monitor = try provider.launchPlan(for: config, purpose: .remoteCommand("true"))
        let terminal = try provider.launchPlan(for: config, purpose: .interactiveShell)
        let sftp = try provider.launchPlan(for: config, purpose: .fileTransfer)

        XCTAssertEqual(monitor.routeRevision, revision)
        XCTAssertEqual(terminal.routeRevision, revision)
        XCTAssertEqual(sftp.routeRevision, revision)
        XCTAssertEqual(configurationPath(monitor), configurationPath(terminal))
        XCTAssertEqual(configurationPath(monitor), configurationPath(sftp))
        let configPath = try XCTUnwrap(configurationPath(monitor))
        let contents = try String(contentsOfFile: configPath, encoding: .utf8)
        XCTAssertTrue(contents.contains("HostName \"jump1.internal\""))
        XCTAssertTrue(contents.contains("HostName \"jump2.internal\""))
        XCTAssertTrue(contents.contains("ConnectTimeout 4"))
        XCTAssertTrue(contents.contains("ConnectTimeout 7"))
        XCTAssertTrue(contents.contains("IdentitiesOnly yes"))
        XCTAssertTrue(contents.contains("PreferredAuthentications publickey,password"))
        XCTAssertTrue(contents.contains("StrictHostKeyChecking yes"))
        XCTAssertTrue(contents.contains("ForwardAgent no"))
        XCTAssertTrue(contents.contains("ProxyJump serverdash-hop-1"))
        XCTAssertEqual(sftp.executable, "/usr/bin/sftp")
        XCTAssertEqual(monitor.executable, "/usr/bin/ssh")
    }

    func testUnreadableExplicitPrivateKeyNeverFallsBackToAgentOrDefaultIdentity() {
        let missing = "/tmp/serverdash-missing-\(UUID().uuidString)"
        let config = ServerConnectionConfig(
            id: UUID(),
            credentialID: UUID(),
            name: "Missing",
            host: "target.invalid",
            port: 22,
            username: "user",
            authentication: .privateKey,
            privateKeyPath: missing
        )

        XCTAssertThrowsError(
            try SystemOpenSSHConnectionProvider().launchPlan(
                for: config,
                purpose: .remoteCommand("true")
            )
        ) { error in
            guard case .credentialUnavailable = error as? ConnectionRouteError else {
                return XCTFail("Expected credentialUnavailable, got \(error)")
            }
        }
        let failClosed = SSHSupport.arguments(
            for: config,
            strictHostChecking: "yes",
            batchMode: true
        )
        XCTAssertTrue(failClosed.contains("IdentityAgent=none"))
        XCTAssertTrue(failClosed.contains("IdentitiesOnly=yes"))
        XCTAssertTrue(failClosed.contains("PubkeyAuthentication=no"))
        XCTAssertFalse(failClosed.contains("-i"))
    }

    func testGeneratedMultiHopConfigurationIsAcceptedBySystemOpenSSH() throws {
        let key = try TemporaryReadableKey()
        let route = ConnectionRoute(
            name: "Validated",
            hops: [
                ConnectionHop(
                    name: "Jump",
                    endpoint: ConnectionEndpoint(host: "jump.internal", port: 2222, username: "jump"),
                    credential: .externalPrivateKey(path: key.url.path)
                )
            ]
        )
        let plan = try SystemOpenSSHConnectionProvider().launchPlan(
            for: makeConfig(keyURL: key.url, route: route),
            purpose: .interactiveShell
        )
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G"] + plan.arguments
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let resolved = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).lowercased()
        let errorText = String(
            decoding: error.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )

        XCTAssertEqual(process.terminationStatus, 0, errorText)
        XCTAssertTrue(resolved.contains("hostname target.internal"))
        XCTAssertTrue(resolved.contains("port 2222"))
        XCTAssertTrue(resolved.contains("proxyjump serverdash-hop-1"))
        XCTAssertTrue(resolved.contains("stricthostkeychecking true"))
    }

    func testStructuredProxyUsesLocalBridgeAndBridgePassesPerlSyntaxCheck() throws {
        let key = try TemporaryReadableKey()
        let route = ConnectionRoute(
            name: "SOCKS",
            proxy: NetworkProxy(
                kind: .socks5,
                host: "127.0.0.1",
                port: 1080,
                username: nil,
                secretAccount: nil
            )
        )
        let plan = try SystemOpenSSHConnectionProvider().launchPlan(
            for: makeConfig(keyURL: key.url, route: route),
            purpose: .interactiveShell
        )
        let configPath = try XCTUnwrap(configurationPath(plan))
        let contents = try String(contentsOfFile: configPath, encoding: .utf8)
        XCTAssertTrue(contents.contains("ProxyCommand /usr/bin/perl"))
        XCTAssertTrue(contents.contains("'socks5'"))
        XCTAssertFalse(contents.localizedCaseInsensitiveContains("password="))

        let prefix = "/usr/bin/perl '"
        let start = try XCTUnwrap(contents.range(of: prefix)?.upperBound)
        let suffix = contents[start...]
        let end = try XCTUnwrap(suffix.firstIndex(of: "'"))
        let bridgePath = String(suffix[..<end])
        let process = Process()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-c", bridgePath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let errorText = String(
            decoding: error.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        XCTAssertEqual(process.terminationStatus, 0, errorText)
    }

    func testRouteFailureClassifierLocatesHopAndStageWithoutParsingLocalizedText() {
        let hop = ConnectionHop(
            name: "Edge",
            endpoint: ConnectionEndpoint(host: "edge.internal", port: 22, username: "jump"),
            credential: .sshAgent
        )
        let route = ConnectionRoute(name: "Route", hops: [hop])
        let failure = RouteFailureClassifier.classify(
            stderr: "edge.internal: Permission denied (publickey).",
            route: route,
            finalEndpoint: ConnectionEndpoint(host: "target.internal", port: 22, username: "app")
        )

        XCTAssertEqual(failure.hopIndex, 0)
        XCTAssertEqual(failure.hopID, hop.id)
        XCTAssertEqual(failure.stage, .authentication)
        XCTAssertEqual(failure.diagnosticCode, "SSH_ROUTE_AUTH")
    }

    func testPersistenceV3StoresRouteAndPortForwardRule() throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let context = ModelContext(container)
        let serverID = UUID()
        let route = ConnectionRoute(name: "Persisted")
        context.insert(try ConnectionRouteRecord(route: route, serverID: serverID))
        context.insert(
            PortForwardRuleRecord(
                rule: PortForwardRule(
                    name: "Local DB",
                    serverID: serverID,
                    direction: .local,
                    listenPort: 15_432,
                    targetHost: "127.0.0.1",
                    targetPort: 5_432
                )
            )
        )
        try context.save()

        XCTAssertEqual(try context.fetch(FetchDescriptor<ConnectionRouteRecord>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<PortForwardRuleRecord>()).count, 1)
        XCTAssertEqual(PersistenceController.currentSchemaVersion, 3)
    }

    func testV2FixtureMigratesToV3WithoutLosingServer() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerDash-S11-V2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("fixture.store")
        let v2Schema = Schema(versionedSchema: PersistenceSchemaV2.self)
        do {
            let configuration = ModelConfiguration(
                "S11V2Fixture",
                schema: v2Schema,
                url: storeURL,
                allowsSave: true,
                cloudKitDatabase: .none
            )
            let container = try ModelContainer(for: v2Schema, configurations: [configuration])
            let context = ModelContext(container)
            context.insert(
                ServerRecord(
                    name: "Preserved",
                    host: "fixture.invalid",
                    username: "tester"
                )
            )
            try context.save()
        }

        let v3Configuration = ModelConfiguration(
            "S11V2Fixture",
            schema: PersistenceController.schema,
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let migrated = try ModelContainer(
            for: PersistenceController.schema,
            migrationPlan: ServerDashMigrationPlan.self,
            configurations: [v3Configuration]
        )
        let context = ModelContext(migrated)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ServerRecord>()).map(\.name), ["Preserved"])
        context.insert(
            try ConnectionRouteRecord(
                route: ConnectionRoute(name: "After migration"),
                serverID: nil
            )
        )
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<ConnectionRouteRecord>()).count, 1)
    }

    private func makeConfig(keyURL: URL, route: ConnectionRoute) -> ServerConnectionConfig {
        ServerConnectionConfig(
            id: UUID(),
            credentialID: UUID(),
            name: "Target",
            host: "target.internal",
            port: 2222,
            username: "app",
            authentication: .keyThenPassword,
            privateKeyPath: keyURL.path,
            route: route
        )
    }

    private func configurationPath(_ plan: OpenSSHLaunchPlan) -> String? {
        guard let index = plan.arguments.firstIndex(of: "-F"),
              plan.arguments.indices.contains(index + 1) else { return nil }
        return plan.arguments[index + 1]
    }
}

final class PortForwardSupervisorTests: XCTestCase {
    func testDefaultRuleIsLoopbackAndWildcardRequiresExplicitConfirmation() {
        let rule = PortForwardRule(
            name: "Safe",
            serverID: UUID(),
            direction: .local,
            listenPort: 12_345,
            targetHost: "127.0.0.1",
            targetPort: 80
        )
        XCTAssertEqual(rule.bindAddress, "127.0.0.1")
        XCTAssertNoThrow(try rule.validate(exposureConfirmed: false))

        var wildcard = rule
        wildcard.bindAddress = "0.0.0.0"
        XCTAssertThrowsError(try wildcard.validate(exposureConfirmed: false)) { error in
            guard case .unsafeListenRequiresConfirmation = error as? ConnectionRouteError else {
                return XCTFail("Expected unsafe confirmation, got \(error)")
            }
        }
        XCTAssertNoThrow(try wildcard.validate(exposureConfirmed: true))

        var remote = rule
        remote.direction = .remote
        XCTAssertThrowsError(
            try remote.validate(
                exposureConfirmed: false,
                remoteForwardConfirmed: false
            )
        ) { error in
            XCTAssertEqual(error as? ConnectionRouteError, .remoteForwardRequiresConfirmation)
        }
        XCTAssertNoThrow(
            try remote.validate(
                exposureConfirmed: false,
                remoteForwardConfirmed: true
            )
        )
    }

    func testStopEscalatesUncooperativeProcessAndReleasesPortWithinOneSecond() async throws {
        let port = try availablePort()
        let launcher = TestTunnelLauncher(ignoreTerminate: true)
        let supervisor = PortForwardSupervisor(
            provider: TestConnectionProvider(),
            launcher: launcher,
            maxReconnectAttempts: 0,
            readinessTimeout: 1
        )
        let serverID = UUID()
        let rule = PortForwardRule(
            name: "Local",
            serverID: serverID,
            direction: .local,
            listenPort: port,
            targetHost: "127.0.0.1",
            targetPort: 80
        )
        let started = try await supervisor.start(
            rule: rule,
            config: directConfig(id: serverID)
        )
        XCTAssertEqual(started.state, .ready)
        XCTAssertFalse(LocalPortAvailability.isAvailable(address: "127.0.0.1", port: port))

        let stopStarted = Date()
        let stopped = try await supervisor.stop(ruleID: rule.id)
        let elapsed = Date().timeIntervalSince(stopStarted)

        XCTAssertEqual(stopped?.state, .stopped)
        XCTAssertLessThan(elapsed, 1.05)
        XCTAssertTrue(LocalPortAvailability.isAvailable(address: "127.0.0.1", port: port))
        XCTAssertGreaterThanOrEqual(launcher.lastHandle?.killCount ?? 0, 1)
    }

    func testNonEnglishLaunchFailureIsBoundedAndDoesNotBecomeReady() async throws {
        let port = try availablePort()
        let launcher = TestTunnelLauncher(
            ignoreTerminate: false,
            failImmediately: true,
            errorOutput: "权限被拒绝：代理不可用"
        )
        let supervisor = PortForwardSupervisor(
            provider: TestConnectionProvider(),
            launcher: launcher,
            maxReconnectAttempts: 0,
            readinessTimeout: 0.3
        )
        let serverID = UUID()
        let rule = PortForwardRule(
            name: "Failure",
            serverID: serverID,
            direction: .local,
            listenPort: port,
            targetHost: "127.0.0.1",
            targetPort: 80
        )

        do {
            _ = try await supervisor.start(rule: rule, config: directConfig(id: serverID))
            XCTFail("Expected launch failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("权限被拒绝"))
        }
        let snapshot = await supervisor.snapshot(ruleID: rule.id)
        XCTAssertEqual(snapshot?.state, .failed)
        XCTAssertTrue(LocalPortAvailability.isAvailable(address: "127.0.0.1", port: port))
    }

    func testReadinessTimeoutKillsProcessThatIgnoresTerminate() async throws {
        let port = try availablePort()
        let launcher = TestTunnelLauncher(ignoreTerminate: true, bindPort: false)
        let supervisor = PortForwardSupervisor(
            provider: TestConnectionProvider(),
            launcher: launcher,
            maxReconnectAttempts: 0,
            readinessTimeout: 0.2
        )
        let serverID = UUID()
        let rule = PortForwardRule(
            name: "Never Ready",
            serverID: serverID,
            direction: .dynamic,
            listenPort: port
        )

        do {
            _ = try await supervisor.start(rule: rule, config: self.directConfig(id: serverID))
            XCTFail("Expected readiness timeout")
        } catch {
            XCTAssertEqual(error as? ConnectionRouteError, .tunnelReadinessTimedOut)
        }
        XCTAssertFalse(launcher.lastHandle?.isRunning() ?? true)
        XCTAssertGreaterThanOrEqual(launcher.lastHandle?.killCount ?? 0, 1)
        XCTAssertTrue(LocalPortAvailability.isAvailable(address: "127.0.0.1", port: port))
    }

    func testStopAllCleansEveryAppScopedTunnel() async throws {
        let firstPort = try availablePort()
        let secondPort = try availablePort(excluding: [firstPort])
        let launcher = TestTunnelLauncher(ignoreTerminate: false)
        let supervisor = PortForwardSupervisor(
            provider: TestConnectionProvider(),
            launcher: launcher,
            maxReconnectAttempts: 0,
            readinessTimeout: 1
        )
        let serverID = UUID()
        for port in [firstPort, secondPort] {
            _ = try await supervisor.start(
                rule: PortForwardRule(
                    name: "Tunnel \(port)",
                    serverID: serverID,
                    direction: .dynamic,
                    listenPort: port
                ),
                config: directConfig(id: serverID)
            )
        }

        await supervisor.stopAll()

        let snapshots = await supervisor.snapshots()
        XCTAssertEqual(snapshots.filter { $0.state == .stopped }.count, 2)
        XCTAssertTrue(LocalPortAvailability.isAvailable(address: "127.0.0.1", port: firstPort))
        XCTAssertTrue(LocalPortAvailability.isAvailable(address: "127.0.0.1", port: secondPort))
    }

    private func directConfig(id: UUID) -> ServerConnectionConfig {
        ServerConnectionConfig(
            id: id,
            credentialID: id,
            name: "Fake",
            host: "fake.invalid",
            port: 22,
            username: "tester",
            authentication: .password,
            privateKeyPath: ""
        )
    }

    private func availablePort(excluding: Set<Int> = []) throws -> Int {
        for port in 30_000...45_000 where !excluding.contains(port) {
            if LocalPortAvailability.isAvailable(address: "127.0.0.1", port: port) {
                return port
            }
        }
        throw XCTSkip("No local test port available")
    }
}

private struct TestConnectionProvider: ConnectionProvider {
    let capabilities: Set<ConnectionCapability> = Set(ConnectionCapability.allCases)

    func launchPlan(
        for config: ServerConnectionConfig,
        purpose: ConnectionPurpose
    ) throws -> OpenSSHLaunchPlan {
        guard case .portForward(let rule) = purpose else {
            throw ConnectionRouteError.tunnelLaunchFailed("unexpected purpose")
        }
        return OpenSSHLaunchPlan(
            executable: "/usr/bin/true",
            arguments: rule.openSSHArguments,
            environment: [:],
            routeRevision: config.route.revision,
            diagnosticEndpoints: []
        )
    }
}

private final class TestTunnelLauncher: TunnelProcessLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private let ignoreTerminate: Bool
    private let failImmediately: Bool
    private let bindPort: Bool
    private let errorOutput: String
    private(set) var lastHandle: TestTunnelHandle?

    init(
        ignoreTerminate: Bool,
        failImmediately: Bool = false,
        bindPort: Bool = true,
        errorOutput: String = ""
    ) {
        self.ignoreTerminate = ignoreTerminate
        self.failImmediately = failImmediately
        self.bindPort = bindPort
        self.errorOutput = errorOutput
    }

    func launch(_ plan: OpenSSHLaunchPlan) throws -> any TunnelProcessHandle {
        let port = try Self.listenPort(from: plan.arguments)
        let handle = try TestTunnelHandle(
            port: port,
            ignoreTerminate: ignoreTerminate,
            failImmediately: failImmediately,
            bindPort: bindPort,
            errorOutput: errorOutput
        )
        lock.lock()
        lastHandle = handle
        lock.unlock()
        return handle
    }

    private static func listenPort(from arguments: [String]) throws -> Int {
        for flag in ["-L", "-D", "-R"] {
            guard let index = arguments.firstIndex(of: flag),
                  arguments.indices.contains(index + 1) else { continue }
            let spec = arguments[index + 1]
            let components = spec.split(separator: ":")
            if flag == "-D", let port = components.last.flatMap({ Int($0) }) {
                return port
            }
            if components.count >= 2, let port = Int(components[1]) {
                return port
            }
        }
        throw ConnectionRouteError.tunnelLaunchFailed("missing listen port")
    }
}

private final class TestTunnelHandle: TunnelProcessHandle, @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32
    private var running: Bool
    private let ignoreTerminate: Bool
    private let errorOutput: String
    private(set) var terminateCount = 0
    private(set) var killCount = 0

    init(
        port: Int,
        ignoreTerminate: Bool,
        failImmediately: Bool,
        bindPort: Bool,
        errorOutput: String
    ) throws {
        self.ignoreTerminate = ignoreTerminate
        self.errorOutput = errorOutput
        if failImmediately {
            descriptor = -1
            running = false
            return
        }
        if !bindPort {
            descriptor = -1
            running = true
            return
        }
        descriptor = socket(AF_INET, SOCK_STREAM, 0)
        running = false
        guard descriptor >= 0 else {
            throw ConnectionRouteError.tunnelLaunchFailed("socket")
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(descriptor, 1) == 0 else {
            Darwin.close(descriptor)
            descriptor = -1
            throw ConnectionRouteError.tunnelLaunchFailed("bind")
        }
        running = true
    }

    deinit { closeIfNeeded() }

    var processIdentifier: Int32 { getpid() }

    func isRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    func terminate() {
        lock.lock()
        terminateCount += 1
        let shouldClose = !ignoreTerminate
        lock.unlock()
        if shouldClose { closeIfNeeded() }
    }

    func kill() {
        lock.lock()
        killCount += 1
        lock.unlock()
        closeIfNeeded()
    }

    func waitForExit() async -> Int32 {
        while isRunning() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return 0
    }

    func boundedErrorOutput() -> String { errorOutput }

    private func closeIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard running else { return }
        running = false
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
    }
}

private final class TemporaryReadableKey {
    let directory: URL
    let url: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerDash-S11-Key-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("id_test")
        try Data("fixture-key".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

private final class TemporarySSHConfigFixture {
    let directory: URL
    let root: URL

    init(files: [String: String]) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerDash-S11-Config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (path, contents) in files {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url)
        }
        root = directory.appendingPathComponent("config")
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}
