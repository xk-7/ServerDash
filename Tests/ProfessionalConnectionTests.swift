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
        XCTAssertNil(result.identityFile)
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

    func testConfirmedProxyCommandStillRejectsControlCharacters() {
        let endpoint = ConnectionEndpoint(host: "target", port: 22, username: "user")
        for command in ["nc %h %p\ncurl evil", "nc %h %p\0more", "nc %h %p\u{0007}"] {
            let route = ConnectionRoute(
                name: "Imported",
                importedProxyCommand: command,
                importedProxyCommandConfirmed: true
            )
            XCTAssertThrowsError(try route.validated(finalEndpoint: endpoint), command) { error in
                XCTAssertEqual(error as? ConnectionRouteError, .invalidProxyCommand)
            }
        }
    }

    func testImportedRouteAppliesFinalEndpointAndIdentityFile() throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let context = ModelContext(container)
        let key = SSHKeyRecord(
            name: "Key",
            filePath: "/old/key",
            algorithm: "ed25519",
            fingerprint: "SHA256:old"
        )
        let identity = IdentityRecord(
            name: "ID",
            username: "old-user",
            authentication: .privateKey,
            sshKeyID: key.id
        )
        let server = ServerRecord(
            name: "S",
            host: "old.example",
            port: 22,
            username: "old-user",
            identityID: identity.id
        )
        context.insert(key)
        context.insert(identity)
        context.insert(server)
        let result = SSHConfigRouteImport(
            route: ConnectionRoute(name: "Imported"),
            endpoint: ConnectionEndpoint(host: "new.internal", port: 2200, username: "imported-user"),
            identityFile: "/imported/key",
            reports: []
        )

        SSHConfigRouteImportApplier.apply(
            result,
            to: server,
            identities: [identity],
            keys: [key]
        )

        XCTAssertEqual(server.host, "new.internal")
        XCTAssertEqual(server.port, 2200)
        XCTAssertEqual(server.username, "imported-user")
        XCTAssertEqual(server.privateKeyPath, "/imported/key")
        XCTAssertEqual(identity.username, "imported-user")
        XCTAssertEqual(key.filePath, "/imported/key")
    }

    func testDirectConfigImportExposesFinalIdentityFile() throws {
        let fixture = try TemporarySSHConfigFixture(files: [
            "config": """
            Host target
                HostName target.internal
                User app
                Port 2200
                IdentityFile /imported/final-key
            """
        ])

        let result = try SSHConfigImporter().importRoute(alias: "target", from: fixture.root)

        XCTAssertTrue(result.route.hops.isEmpty)
        XCTAssertEqual(result.endpoint.host, "target.internal")
        XCTAssertEqual(result.endpoint.port, 2200)
        XCTAssertEqual(result.endpoint.username, "app")
        XCTAssertEqual(result.identityFile, "/imported/final-key")
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

    func testMalformedPersistedRouteBlocksEveryBusinessPurpose() {
        let server = ServerRecord(
            name: "Target",
            host: "target.example.com",
            username: "deploy"
        )
        let damagedRoute = ConnectionRouteRecord(
            serverID: server.id,
            name: "Damaged route",
            routeJSON: "{"
        )
        let config = ConnectionConfigResolver.resolve(
            server: server,
            identities: [],
            keys: [],
            routes: [damagedRoute]
        )
        let forward = PortForwardRule(
            name: "Database",
            serverID: server.id,
            direction: .local,
            listenPort: 12_345,
            targetHost: "database.internal",
            targetPort: 5432
        )
        let purposes: [ConnectionPurpose] = [
            .interactiveShell,
            .remoteCommand("true"),
            .fileTransfer,
            .portForward(forward)
        ]
        let provider = SystemOpenSSHConnectionProvider()

        XCTAssertNil(config.route)
        for purpose in purposes {
            XCTAssertThrowsError(try provider.launchPlan(for: config, purpose: purpose)) { error in
                XCTAssertEqual(error as? ConnectionRouteError, .invalidPersistedRoute)
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

        let bridgePath = try proxyBridgePath(from: plan)
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

    func testSOCKSBridgeRefusesCredentialDowngradeToAnonymous() throws {
        let key = try TemporaryReadableKey()
        let account = "proxy-test.\(UUID().uuidString)"
        try KeychainService.saveSecret("proxy-secret", account: account)
        defer { try? KeychainService.deleteSecret(account: account) }

        let route = ConnectionRoute(
            name: "Authenticated SOCKS",
            proxy: NetworkProxy(
                kind: .socks5,
                host: "127.0.0.1",
                port: 1080,
                username: "proxy-user",
                secretAccount: account
            )
        )
        let plan = try SystemOpenSSHConnectionProvider().launchPlan(
            for: makeConfig(keyURL: key.url, route: route),
            purpose: .interactiveShell
        )
        let bridgePath = try proxyBridgePath(from: plan)
        let proxy = try LoopbackTCPProbe()

        let process = Process()
        let standardInput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [
            bridgePath,
            "socks5",
            "127.0.0.1",
            String(proxy.port),
            "target.internal",
            "22",
            "proxy-user",
            account
        ]
        process.standardInput = standardInput
        process.standardOutput = FileHandle.nullDevice
        process.standardError = standardError
        try process.run()
        try? standardInput.fileHandleForWriting.close()

        let client = try proxy.acceptClient()
        defer { Darwin.close(client) }
        let greeting = try LoopbackTCPProbe.readExactly(client, count: 3)
        XCTAssertEqual(greeting, Data([5, 1, 2]))
        try LoopbackTCPProbe.write(client, Data([5, 0]))
        Darwin.shutdown(client, SHUT_RDWR)

        process.waitUntilExit()
        let errorText = String(
            decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertTrue(errorText.contains("SOCKS5 authentication required"), errorText)
    }

    func testAnonymousSOCKSBridgeAdvertisesOnlyNoAuthentication() throws {
        let key = try TemporaryReadableKey()
        let route = ConnectionRoute(
            name: "Anonymous SOCKS",
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
        let bridgePath = try proxyBridgePath(from: plan)
        let proxy = try LoopbackTCPProbe()

        let process = Process()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [
            bridgePath,
            "socks5",
            "127.0.0.1",
            String(proxy.port),
            "target.internal",
            "22",
            "",
            ""
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = standardError
        try process.run()

        let client = try proxy.acceptClient()
        defer { Darwin.close(client) }
        let greeting = try LoopbackTCPProbe.readExactly(client, count: 3)
        XCTAssertEqual(greeting, Data([5, 1, 0]))
        try LoopbackTCPProbe.write(client, Data([5, 2]))
        Darwin.shutdown(client, SHUT_RDWR)

        process.waitUntilExit()
        let errorText = String(
            decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertTrue(errorText.contains("SOCKS5 negotiation failed"), errorText)
    }

    func testCredentialedProxyRequiresLiteralLoopbackHost() throws {
        let endpoint = ConnectionEndpoint(
            host: "target.internal",
            port: 22,
            username: "app"
        )
        let rejectedHosts = [
            "proxy.example.com",
            "192.0.2.10",
            "localhost",
            "127.0.0.2",
            "[::1]",
            "::ffff:127.0.0.1"
        ]

        for kind in NetworkProxyKind.allCases {
            for host in rejectedHosts {
                let route = ConnectionRoute(
                    name: "Remote authenticated proxy",
                    proxy: NetworkProxy(
                        kind: kind,
                        host: host,
                        port: 1080,
                        username: "proxy-user",
                        secretAccount: "missing-test-account"
                    )
                )

                XCTAssertThrowsError(
                    try route.validated(finalEndpoint: endpoint),
                    "\(kind.rawValue) unexpectedly allowed credentials for \(host)"
                ) { error in
                    XCTAssertEqual(
                        error as? ConnectionRouteError,
                        .proxyCredentialsRequireLoopback
                    )
                }
            }
        }
    }

    func testCredentialedProxyAllowsIPv4AndIPv6Loopback() throws {
        let endpoint = ConnectionEndpoint(
            host: "target.internal",
            port: 22,
            username: "app"
        )
        let account = "proxy-test.\(UUID().uuidString)"
        try KeychainService.saveSecret("proxy-secret", account: account)
        defer { try? KeychainService.deleteSecret(account: account) }

        for kind in NetworkProxyKind.allCases {
            for host in ["127.0.0.1", "::1"] {
                let route = ConnectionRoute(
                    name: "Loopback authenticated proxy",
                    proxy: NetworkProxy(
                        kind: kind,
                        host: host,
                        port: 1080,
                        username: "proxy-user",
                        secretAccount: account
                    )
                )

                XCTAssertNoThrow(
                    try route.validated(finalEndpoint: endpoint),
                    "\(kind.rawValue) rejected loopback host \(host)"
                )
            }
        }
    }

    func testAnonymousRemoteProxyRemainsAllowed() {
        let endpoint = ConnectionEndpoint(
            host: "target.internal",
            port: 22,
            username: "app"
        )

        for kind in NetworkProxyKind.allCases {
            let route = ConnectionRoute(
                name: "Remote anonymous proxy",
                proxy: NetworkProxy(
                    kind: kind,
                    host: "proxy.example.com",
                    port: 1080,
                    username: nil,
                    secretAccount: nil
                )
            )
            XCTAssertNoThrow(try route.validated(finalEndpoint: endpoint))
        }
    }

    func testIncompleteRemoteProxyCredentialStillReportsMissingPair() {
        let route = ConnectionRoute(
            name: "Incomplete proxy credential",
            proxy: NetworkProxy(
                kind: .socks5,
                host: "proxy.example.com",
                port: 1080,
                username: "proxy-user",
                secretAccount: nil
            )
        )
        let endpoint = ConnectionEndpoint(
            host: "target.internal",
            port: 22,
            username: "app"
        )

        XCTAssertThrowsError(try route.validated(finalEndpoint: endpoint)) { error in
            XCTAssertEqual(error as? ConnectionRouteError, .proxyCredentialMissing)
        }
    }

    func testRoutedAskPassTreatsShellMetacharactersAsLiteralSelectorData() throws {
        let dollarMarker = URL(
            fileURLWithPath: "/tmp/sd-ap-dollar-\(UUID().uuidString)"
        )
        let backtickMarker = URL(
            fileURLWithPath: "/tmp/sd-ap-backtick-\(UUID().uuidString)"
        )
        defer {
            try? FileManager.default.removeItem(at: dollarMarker)
            try? FileManager.default.removeItem(at: backtickMarker)
        }
        let dollarSelector = "/tmp/key$(/usr/bin/touch \(dollarMarker.path))"
        let backtickSelector = "/tmp/key`/usr/bin/touch \(backtickMarker.path)`"
        let quotedGlobSelector = "/tmp/\\\"quoted\\\"-'single'-*literal?-\\\\key"
        let firstHop = ConnectionHop(
            name: "Dollar",
            endpoint: ConnectionEndpoint(host: "dollar.internal", port: 22, username: "jump"),
            credential: .externalPrivateKey(path: dollarSelector)
        )
        let secondHop = ConnectionHop(
            name: "Backtick",
            endpoint: ConnectionEndpoint(host: "backtick.internal", port: 22, username: "jump"),
            credential: .externalPrivateKey(path: backtickSelector)
        )
        let thirdHop = ConnectionHop(
            name: "Quotes and globs",
            endpoint: ConnectionEndpoint(host: "quoted.internal", port: 22, username: "jump"),
            credential: .externalPrivateKey(path: quotedGlobSelector)
        )
        let route = ConnectionRoute(
            name: "Literal selectors",
            hops: [firstHop, secondHop, thirdHop]
        )
        let provider = SystemOpenSSHConnectionProvider(
            credentialProvider: AskPassFixtureCredentialProvider(
                passphrasePaths: [dollarSelector, backtickSelector, quotedGlobSelector]
            )
        )
        let config = ServerConnectionConfig(
            id: UUID(),
            credentialID: UUID(),
            name: "Target",
            host: "target.internal",
            port: 22,
            username: "app",
            authentication: .privateKey,
            privateKeyPath: "/tmp/serverdash-final-key",
            route: route
        )

        let plan = try provider.launchPlan(for: config, purpose: .interactiveShell)
        let helperPath = try XCTUnwrap(plan.environment["SSH_ASKPASS"])
        let helper = try String(contentsOfFile: helperPath, encoding: .utf8)
        let selectors = Set(plan.environment.compactMap { key, value in
            key.hasPrefix("SERVERDASH_ROUTE_ASKPASS_SELECTOR_") ? value : nil
        })

        XCTAssertEqual(
            selectors,
            Set([dollarSelector, backtickSelector, quotedGlobSelector].map {
                "Enter passphrase for key '\($0)': "
            })
        )
        XCTAssertFalse(helper.contains(dollarSelector))
        XCTAssertFalse(helper.contains(backtickSelector))
        XCTAssertFalse(helper.contains(quotedGlobSelector))
        XCTAssertFalse(helper.contains("$("))

        func runHelper(prompt: String) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: helperPath)
            process.arguments = [prompt]
            process.environment = plan.environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        for selector in [dollarSelector, backtickSelector, quotedGlobSelector] {
            XCTAssertNotEqual(
                try runHelper(prompt: "Enter passphrase for key '\(selector)': "),
                1
            )
        }
        let globNearMiss = quotedGlobSelector.replacingOccurrences(
            of: "*literal?",
            with: "XliteralY"
        )

        XCTAssertEqual(
            try runHelper(prompt: "Enter passphrase for key '\(globNearMiss)': "),
            1
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: dollarMarker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backtickMarker.path))
    }

    func testRoutedAskPassPrefixTreatsShellMetacharactersAsLiteralData() throws {
        let dollarMarker = URL(
            fileURLWithPath: "/tmp/sd-ap-prefix-dollar-\(UUID().uuidString)"
        )
        let backtickMarker = URL(
            fileURLWithPath: "/tmp/sd-ap-prefix-backtick-\(UUID().uuidString)"
        )
        defer {
            try? FileManager.default.removeItem(at: dollarMarker)
            try? FileManager.default.removeItem(at: backtickMarker)
        }
        let username = "jump*?[$(/usr/bin/touch${IFS}\(dollarMarker.path))]" +
            "`/usr/bin/touch${IFS}\(backtickMarker.path)`"
        let route = ConnectionRoute(
            name: "Literal prefix",
            hops: [
                ConnectionHop(
                    name: "Password",
                    endpoint: ConnectionEndpoint(
                        host: "prefix.internal",
                        port: 22,
                        username: username
                    ),
                    credential: .password(accountID: UUID())
                )
            ]
        )
        let provider = SystemOpenSSHConnectionProvider(
            credentialProvider: AskPassFixtureCredentialProvider(passphrasePaths: [])
        )
        let config = ServerConnectionConfig(
            id: UUID(),
            credentialID: UUID(),
            name: "Target",
            host: "target.internal",
            port: 22,
            username: "app",
            authentication: .privateKey,
            privateKeyPath: "/tmp/serverdash-final-key",
            route: route
        )

        let plan = try provider.launchPlan(for: config, purpose: .interactiveShell)
        let helperPath = try XCTUnwrap(plan.environment["SSH_ASKPASS"])
        let helper = try String(contentsOfFile: helperPath, encoding: .utf8)

        XCTAssertFalse(helper.contains(username))
        XCTAssertFalse(helper.contains("$("))
        XCTAssertFalse(helper.contains("`"))

        func runHelper(prompt: String) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: helperPath)
            process.arguments = [prompt]
            process.environment = plan.environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }

        XCTAssertNotEqual(
            try runHelper(prompt: "(\(username)@prefix.internal) Verification code: "),
            1
        )
        let nearMiss = username.replacingOccurrences(of: "*?[", with: "XYZ")
        XCTAssertEqual(
            try runHelper(prompt: "(\(nearMiss)@prefix.internal) Verification code: "),
            1
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: dollarMarker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backtickMarker.path))
    }

    func testRoutedAskPassMatchesOpenSSHPromptFormats() throws {
        let longKeyPath = "/tmp/" + String(repeating: "a", count: 120)
        let keyHop = ConnectionHop(
            name: "Long key",
            endpoint: ConnectionEndpoint(
                host: "key.internal",
                port: 22,
                username: "key-user"
            ),
            credential: .externalPrivateKey(path: longKeyPath)
        )
        let passwordHop = ConnectionHop(
            name: "Password",
            endpoint: ConnectionEndpoint(
                host: "İMiXeD.Internal",
                port: 2222,
                username: "jump"
            ),
            credential: .password(accountID: UUID())
        )
        let provider = SystemOpenSSHConnectionProvider(
            credentialProvider: AskPassFixtureCredentialProvider(
                passphrasePaths: [longKeyPath]
            )
        )
        let config = ServerConnectionConfig(
            id: UUID(),
            credentialID: UUID(),
            name: "Target",
            host: "target.internal",
            port: 22,
            username: "app",
            authentication: .privateKey,
            privateKeyPath: "/tmp/serverdash-final-key",
            route: ConnectionRoute(
                name: "OpenSSH prompts",
                hops: [keyHop, passwordHop]
            )
        )

        let plan = try provider.launchPlan(for: config, purpose: .interactiveShell)
        let helperPath = try XCTUnwrap(plan.environment["SSH_ASKPASS"])
        let displayedKeyPath = try XCTUnwrap(
            String(bytes: longKeyPath.utf8.prefix(100), encoding: .utf8)
        )

        func runHelper(
            prompt: String,
            environment: [String: String]? = nil
        ) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: helperPath)
            process.arguments = [prompt]
            process.environment = environment ?? plan.environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }

        XCTAssertNotEqual(
            try runHelper(
                prompt: "Enter passphrase for key '\(displayedKeyPath)': "
            ),
            1
        )
        XCTAssertEqual(
            try runHelper(prompt: "Enter passphrase for key '\(longKeyPath)': "),
            1
        )
        XCTAssertNotEqual(
            try runHelper(prompt: "jump@[İmixed.internal]:2222's password: "),
            1
        )
        XCTAssertNotEqual(
            try runHelper(
                prompt: "(jump@[İmixed.internal]:2222) Verification code: "
            ),
            1
        )
        XCTAssertEqual(
            try runHelper(
                prompt: "prefix (jump@[İmixed.internal]:2222) Verification code: "
            ),
            1
        )
        XCTAssertEqual(
            try runHelper(prompt: "jump@İMiXeD.Internal's password: "),
            1
        )
        XCTAssertEqual(
            try runHelper(prompt: "jump@[İmixed.internal]:2222-prod's password: "),
            1
        )
        XCTAssertEqual(
            try runHelper(
                prompt: "(jump@[İmixed.internal]:2222-prod) Verification code: "
            ),
            1
        )
        var missingSelectors = plan.environment
        for key in missingSelectors.keys.filter({
            $0.hasPrefix("SERVERDASH_ROUTE_ASKPASS_SELECTOR_")
        }) {
            missingSelectors.removeValue(forKey: key)
        }
        XCTAssertEqual(
            try runHelper(prompt: "", environment: missingSelectors),
            1
        )
    }

    func testRoutedAskPassRejectsSubstringPasswordIdentities() {
        let databaseAccount = UUID()
        let productionAccount = UUID()
        let route = ConnectionRoute(
            name: "Substring identities",
            hops: [
                ConnectionHop(
                    name: "Database",
                    endpoint: ConnectionEndpoint(
                        host: "db",
                        port: 22,
                        username: "alice"
                    ),
                    credential: .password(accountID: databaseAccount)
                ),
                ConnectionHop(
                    name: "Production database",
                    endpoint: ConnectionEndpoint(
                        host: "db-prod",
                        port: 22,
                        username: "alice"
                    ),
                    credential: .password(accountID: productionAccount)
                )
            ]
        )
        let provider = SystemOpenSSHConnectionProvider(
            credentialProvider: AskPassFixtureCredentialProvider(passphrasePaths: [])
        )
        let config = ServerConnectionConfig(
            id: UUID(),
            credentialID: UUID(),
            name: "Target",
            host: "target.internal",
            port: 22,
            username: "app",
            authentication: .privateKey,
            privateKeyPath: "/tmp/serverdash-final-key",
            route: route
        )

        XCTAssertThrowsError(
            try provider.launchPlan(for: config, purpose: .interactiveShell)
        ) { error in
            XCTAssertEqual(
                error as? ConnectionRouteError,
                .multipleInteractiveCredentialsUnsupported
            )
        }
    }

    func testRoutedAskPassRejectsControlCharactersInSelectors() {
        for controlCharacter in [
            "\0", "\t", "\n", "\r", "\u{7F}", "\u{85}", "\u{2028}", "\u{2029}"
        ] {
            let unsafeSelector = "/tmp/key\(controlCharacter)unsafe"
            let hop = ConnectionHop(
                name: "Unsafe",
                endpoint: ConnectionEndpoint(
                    host: "jump.internal",
                    port: 22,
                    username: "jump"
                ),
                credential: .externalPrivateKey(path: unsafeSelector)
            )
            let route = ConnectionRoute(name: "Unsafe selector", hops: [hop])
            let provider = SystemOpenSSHConnectionProvider(
                credentialProvider: AskPassFixtureCredentialProvider(
                    passphrasePaths: [unsafeSelector]
                )
            )
            let config = ServerConnectionConfig(
                id: UUID(),
                credentialID: UUID(),
                name: "Target",
                host: "target.internal",
                port: 22,
                username: "app",
                authentication: .privateKey,
                privateKeyPath: "/tmp/serverdash-final-key",
                route: route
            )

            XCTAssertThrowsError(
                try provider.launchPlan(for: config, purpose: .interactiveShell)
            ) { error in
                XCTAssertEqual(
                    error as? ConnectionRouteError,
                    .invalidInteractiveCredentialSelector
                )
            }
        }
    }

    func testRoutedAskPassRejectsKeyPromptCollisionsAfterTruncation() {
        let sharedPrefix = "/tmp/" + String(repeating: "a", count: 110)
        let firstPath = sharedPrefix + "-first"
        let secondPath = sharedPrefix + "-second"
        let route = ConnectionRoute(
            name: "Colliding key prompts",
            hops: [
                ConnectionHop(
                    name: "First",
                    endpoint: ConnectionEndpoint(
                        host: "first.internal",
                        port: 22,
                        username: "jump"
                    ),
                    credential: .externalPrivateKey(path: firstPath)
                ),
                ConnectionHop(
                    name: "Second",
                    endpoint: ConnectionEndpoint(
                        host: "second.internal",
                        port: 22,
                        username: "jump"
                    ),
                    credential: .externalPrivateKey(path: secondPath)
                )
            ]
        )
        let provider = SystemOpenSSHConnectionProvider(
            credentialProvider: AskPassFixtureCredentialProvider(
                passphrasePaths: [firstPath, secondPath]
            )
        )
        let config = ServerConnectionConfig(
            id: UUID(),
            credentialID: UUID(),
            name: "Target",
            host: "target.internal",
            port: 22,
            username: "app",
            authentication: .privateKey,
            privateKeyPath: "/tmp/serverdash-final-key",
            route: route
        )

        XCTAssertThrowsError(
            try provider.launchPlan(for: config, purpose: .interactiveShell)
        ) { error in
            XCTAssertEqual(
                error as? ConnectionRouteError,
                .multipleInteractiveCredentialsUnsupported
            )
        }
    }

    func testRoutedAskPassRejectsKeyPromptWithSplitUTF8Scalar() {
        let keyPath = "/tmp/" + String(repeating: "a", count: 94) + "é"
        XCTAssertEqual(keyPath.utf8.count, 101)
        let route = ConnectionRoute(
            name: "Split UTF-8 prompt",
            hops: [
                ConnectionHop(
                    name: "Key",
                    endpoint: ConnectionEndpoint(
                        host: "key.internal",
                        port: 22,
                        username: "jump"
                    ),
                    credential: .externalPrivateKey(path: keyPath)
                )
            ]
        )
        let provider = SystemOpenSSHConnectionProvider(
            credentialProvider: AskPassFixtureCredentialProvider(
                passphrasePaths: [keyPath]
            )
        )
        let config = ServerConnectionConfig(
            id: UUID(),
            credentialID: UUID(),
            name: "Target",
            host: "target.internal",
            port: 22,
            username: "app",
            authentication: .privateKey,
            privateKeyPath: "/tmp/serverdash-final-key",
            route: route
        )

        XCTAssertThrowsError(
            try provider.launchPlan(for: config, purpose: .interactiveShell)
        ) { error in
            XCTAssertEqual(
                error as? ConnectionRouteError,
                .invalidInteractiveCredentialSelector
            )
        }
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
        XCTAssertEqual(PersistenceController.currentSchemaVersion, 5)
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

    private func proxyBridgePath(from plan: OpenSSHLaunchPlan) throws -> String {
        let configPath = try XCTUnwrap(configurationPath(plan))
        let contents = try String(contentsOfFile: configPath, encoding: .utf8)
        let prefix = "/usr/bin/perl '"
        let start = try XCTUnwrap(contents.range(of: prefix)?.upperBound)
        let suffix = contents[start...]
        let end = try XCTUnwrap(suffix.firstIndex(of: "'"))
        return String(suffix[..<end])
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

    func testStopAllUsesOneAbsoluteDeadlineAndEscalatesAllHandles() async throws {
        let firstPort = try availablePort()
        let secondPort = try availablePort(excluding: [firstPort])
        let launcher = TestTunnelLauncher(ignoreTerminate: true)
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
                    name: "Deadline tunnel \(port)",
                    serverID: serverID,
                    direction: .dynamic,
                    listenPort: port
                ),
                config: directConfig(id: serverID)
            )
        }

        let clock = ContinuousClock()
        let started = clock.now
        let stopped = await supervisor.stopAll(
            until: started.advanced(by: .milliseconds(700))
        )

        XCTAssertTrue(stopped)
        XCTAssertLessThan(started.duration(to: clock.now), .milliseconds(800))
        let snapshots = await supervisor.snapshots()
        XCTAssertEqual(snapshots.filter { $0.state == .stopped }.count, 2)
        XCTAssertTrue(LocalPortAvailability.isAvailable(address: "127.0.0.1", port: firstPort))
        XCTAssertTrue(LocalPortAvailability.isAvailable(address: "127.0.0.1", port: secondPort))
    }

    func testStopDuringReconnectReadyWaitLeavesTunnelStoppedAndDoesNotRelaunch() async throws {
        let port = try availablePort()
        let launcher = StallOnReconnectLauncher()
        let supervisor = PortForwardSupervisor(
            provider: TestConnectionProvider(),
            launcher: launcher,
            maxReconnectAttempts: 3,
            readinessTimeout: 2
        )
        let serverID = UUID()
        let rule = PortForwardRule(
            name: "Reconnect stop",
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
        XCTAssertEqual(launcher.launchCount, 1)

        launcher.handles[0].simulateUnexpectedExit()
        let waitDeadline = Date().addingTimeInterval(2)
        while Date() < waitDeadline, launcher.launchCount < 2 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(launcher.launchCount, 2)

        let stopped = try await supervisor.stop(ruleID: rule.id)
        XCTAssertEqual(stopped?.state, .stopped)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(launcher.launchCount, 2)
        let snapshot = await supervisor.snapshot(ruleID: rule.id)
        XCTAssertEqual(snapshot?.state, .stopped)
    }

    func testRemoteForwardBecomesReadyAfterHandshakeMarker() async throws {
        let port = try availablePort()
        let launcher = TestTunnelLauncher(ignoreTerminate: false, bindPort: false)
        let supervisor = PortForwardSupervisor(
            provider: TestConnectionProvider(),
            launcher: launcher,
            maxReconnectAttempts: 0,
            readinessTimeout: 1
        )
        let serverID = UUID()
        let rule = PortForwardRule(
            name: "Remote",
            serverID: serverID,
            direction: .remote,
            listenPort: port,
            targetHost: "127.0.0.1",
            targetPort: 80
        )
        let started = try await supervisor.start(
            rule: rule,
            config: directConfig(id: serverID),
            remoteForwardConfirmed: true
        )
        XCTAssertEqual(started.state, .ready)
        let stopped = try await supervisor.stop(ruleID: rule.id)
        XCTAssertEqual(stopped?.state, .stopped)
    }

    func testImportedKeyMaterialUsesUniquePathsAndCleansUpIndependently() throws {
        let keyID = UUID()
        let pem = "-----BEGIN OPENSSH PRIVATE KEY-----\nfixture\n-----END OPENSSH PRIVATE KEY-----"
        try KeychainService.saveSecret(
            pem,
            account: KeychainService.importedKeyAccount(for: keyID)
        )
        defer {
            try? KeychainService.deleteSecret(
                account: KeychainService.importedKeyAccount(for: keyID)
            )
            KeyMaterialStore.cleanupAll()
            RouteKeyMaterialStore.cleanupAll()
        }

        let first = try RouteKeyMaterialStore.materializeImportedKey(keyID: keyID)
        let second = try RouteKeyMaterialStore.materializeImportedKey(keyID: keyID)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.contains(keyID.uuidString))
        XCTAssertTrue(second.contains(keyID.uuidString))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second))

        TemporaryKeyMaterial.cleanup([first])
        XCTAssertFalse(FileManager.default.fileExists(atPath: first))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second))
    }

    func testHopKeyscanMissingIsFailClosed() {
        XCTAssertEqual(
            HopHostKeyScanner.unavailableMessage(
                output: "",
                error: "SERVERDASH_KEYSCAN_MISSING"
            ),
            HopHostKeyScanner.missingKeyscanMessage
        )
        XCTAssertEqual(
            HopHostKeyScanner.unavailableMessage(
                output: "",
                error: "bash: ssh-keyscan: not found"
            ),
            HopHostKeyScanner.missingKeyscanMessage
        )
        XCTAssertNil(
            HopHostKeyScanner.unavailableMessage(
                output: "10.0.0.5 ssh-ed25519 AAAA",
                error: ""
            )
        )
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

private struct AskPassFixtureCredentialProvider: CredentialProvider {
    let passphrasePaths: Set<String>

    func resolve(
        _ reference: CredentialReference,
        hopID: UUID
    ) throws -> ResolvedCredential {
        switch reference {
        case .sshAgent:
            .sshAgent
        case .externalPrivateKey(let path):
            .privateKey(
                path: path,
                passphraseAccount: passphrasePaths.contains(path)
                    ? "passphrase.\(hopID.uuidString)"
                    : nil
            )
        case .importedPrivateKey(let keyID, let hasPassphrase):
            .privateKey(
                path: "/tmp/\(keyID.uuidString)",
                passphraseAccount: hasPassphrase
                    ? "passphrase.\(keyID.uuidString)"
                    : nil
            )
        case .password(let accountID):
            .password(account: accountID.uuidString)
        }
    }
}

private struct TestConnectionProvider: ConnectionProvider {
    let capabilities: Set<ConnectionCapability> = Set(ConnectionCapability.allCases)

    func launchPlan(
        for config: ServerConnectionConfig,
        purpose: ConnectionPurpose
    ) throws -> OpenSSHLaunchPlan {
        guard let route = config.route else {
            throw ConnectionRouteError.invalidPersistedRoute
        }
        guard case .portForward(let rule) = purpose else {
            throw ConnectionRouteError.tunnelLaunchFailed("unexpected purpose")
        }
        return OpenSSHLaunchPlan(
            executable: "/usr/bin/true",
            arguments: rule.openSSHArguments,
            environment: [:],
            routeRevision: route.revision,
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
        if let marker = Self.handshakeMarkerPath(from: plan.arguments) {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: marker).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: marker, contents: Data())
        }
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

    fileprivate static func listenPort(from arguments: [String]) throws -> Int {
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

    fileprivate static func handshakeMarkerPath(from arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            guard argument == "-o", arguments.indices.contains(index + 1) else { continue }
            let option = arguments[index + 1]
            let prefix = "LocalCommand=/usr/bin/touch '"
            guard option.hasPrefix(prefix), option.hasSuffix("'") else { continue }
            let start = option.index(option.startIndex, offsetBy: prefix.count)
            let end = option.index(before: option.endIndex)
            return String(option[start..<end]).replacingOccurrences(of: "'\\''", with: "'")
        }
        return nil
    }
}

private final class StallOnReconnectLauncher: TunnelProcessLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var launchCount = 0
    private(set) var handles: [TestTunnelHandle] = []

    func launch(_ plan: OpenSSHLaunchPlan) throws -> any TunnelProcessHandle {
        lock.lock()
        launchCount += 1
        let count = launchCount
        lock.unlock()
        let port = try TestTunnelLauncher.listenPort(from: plan.arguments)
        let handle = try TestTunnelHandle(
            port: port,
            ignoreTerminate: false,
            failImmediately: false,
            bindPort: count == 1,
            errorOutput: ""
        )
        lock.lock()
        handles.append(handle)
        lock.unlock()
        return handle
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

    func simulateUnexpectedExit() {
        closeIfNeeded()
    }

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

private final class LoopbackTCPProbe {
    let port: Int
    private var listener: Int32

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var reuse: Int32 = 1
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuse,
            socklen_t(MemoryLayout<Int32>.size)
        )
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bindResult == 0, Darwin.listen(descriptor, 1) == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.EIO)
        }
        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &address, { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &addressLength)
            }
        }) == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.EIO)
        }
        listener = descriptor
        port = Int(UInt16(bigEndian: address.sin_port))
    }

    deinit {
        if listener >= 0 { Darwin.close(listener) }
    }

    func acceptClient() throws -> Int32 {
        var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard Darwin.poll(&descriptor, 1, 5_000) > 0 else {
            throw POSIXError(.ETIMEDOUT)
        }
        let client = Darwin.accept(listener, nil, nil)
        guard client >= 0 else { throw POSIXError(.EIO) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        var noSignal: Int32 = 1
        _ = setsockopt(
            client,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        _ = setsockopt(
            client,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        _ = setsockopt(
            client,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)
        )
        return client
    }

    static func readExactly(_ descriptor: Int32, count: Int) throws -> Data {
        var result = Data()
        while result.count < count {
            var bytes = [UInt8](repeating: 0, count: count - result.count)
            let readCount = Darwin.read(descriptor, &bytes, bytes.count)
            guard readCount > 0 else { throw POSIXError(.EIO) }
            result.append(contentsOf: bytes.prefix(readCount))
        }
        return result
    }

    static func write(_ descriptor: Int32, _ data: Data) throws {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { bytes in
                Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
            }
            guard written > 0 else { throw POSIXError(.EIO) }
            offset += written
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
