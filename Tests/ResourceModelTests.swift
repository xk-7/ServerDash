import SwiftData
import XCTest
@testable import ServerDash

final class ResourceModelTests: XCTestCase {
    func testLegacyServerUsesItsOwnCredentialNamespace() {
        let server = ServerRecord(
            name: "Legacy",
            host: "legacy.example.com",
            username: "root",
            authentication: .password
        )

        XCTAssertNil(server.identityID)
        XCTAssertEqual(server.connectionConfig.credentialID, server.id)
    }

    func testIdentityServerUsesIdentityCredentialNamespace() {
        let identityID = UUID()
        let server = ServerRecord(
            name: "Linked",
            host: "linked.example.com",
            username: "deploy",
            authentication: .password,
            identityID: identityID
        )

        XCTAssertNotEqual(server.id, identityID)
        XCTAssertEqual(server.connectionConfig.credentialID, identityID)
    }

    func testResolverUsesIdentityAndReferencedKey() {
        let key = SSHKeyRecord(
            name: "Production",
            filePath: "/tmp/id_ed25519",
            algorithm: "ED25519",
            fingerprint: "SHA256:test"
        )
        let identity = IdentityRecord(
            name: "Deploy",
            username: "deploy",
            authentication: .privateKey,
            sshKeyID: key.id
        )
        let server = ServerRecord(
            name: "Linked",
            host: "linked.example.com",
            username: "legacy",
            authentication: .password,
            identityID: identity.id
        )

        let config = ConnectionConfigResolver.resolve(
            server: server,
            identities: [identity],
            keys: [key]
        )

        XCTAssertEqual(config.credentialID, identity.id)
        XCTAssertEqual(config.username, "deploy")
        XCTAssertEqual(config.authentication, .privateKey)
        XCTAssertEqual(config.privateKeyPath, "/tmp/id_ed25519")
    }

    func testMissingIdentityReferenceDoesNotFallBackToLegacyConnectionFields() {
        let server = ServerRecord(
            name: "Linked",
            host: "linked.example.com",
            username: "stale-user",
            authentication: .privateKey,
            privateKeyPath: "/stale/private/key",
            identityID: UUID()
        )

        let config = ConnectionConfigResolver.resolve(
            server: server,
            identities: [],
            keys: []
        )

        XCTAssertTrue(config.identityReferenceMissing)
        XCTAssertTrue(config.username.isEmpty)
        XCTAssertTrue(config.privateKeyPath.isEmpty)
    }

    func testKeyThenPasswordWithoutResolvedKeyDisablesAgentFallback() {
        let config = ServerConnectionConfig(
            id: UUID(),
            credentialID: UUID(),
            name: "Test",
            host: "host.invalid",
            port: 22,
            username: "tester",
            authentication: .keyThenPassword,
            privateKeyPath: ""
        )
        let arguments = SSHSupport.arguments(
            for: config,
            strictHostChecking: "yes",
            batchMode: true
        )

        XCTAssertTrue(arguments.contains("PubkeyAuthentication=no"))
        XCTAssertFalse(arguments.contains("-i"))
    }

    func testIdentityDeletionIsBlockedWhileReferenced() {
        let identityID = UUID()
        let linked = ServerRecord(
            name: "Linked",
            host: "linked.example.com",
            username: "deploy",
            identityID: identityID
        )
        let unlinked = ServerRecord(
            name: "Custom",
            host: "custom.example.com",
            username: "root"
        )

        XCTAssertFalse(
            ResourceDeletionPolicy.canDeleteIdentity(
                identityID,
                servers: [linked, unlinked]
            )
        )
        XCTAssertTrue(
            ResourceDeletionPolicy.canDeleteIdentity(
                UUID(),
                servers: [linked, unlinked]
            )
        )
    }

    func testCompleteSchemaCreatesInMemoryContainer() throws {
        _ = try PersistenceController.makeInMemoryContainer()
    }

    func testServerBrowserCombinesSearchGroupAndExactTag() {
        let production = ServerRecord(name: "API-2", host: "192.0.2.2", username: "root",
                                      groupName: "生产", tagsText: "web, primary")
        let staging = ServerRecord(name: "API-10", host: "192.0.2.10", username: "root",
                                   groupName: "测试", tagsText: "web")
        let partialTag = ServerRecord(name: "API-3", host: "192.0.2.3", username: "root",
                                      groupName: "生产", tagsText: "websocket")
        let query = ServerBrowserQuery(search: "  api  ", group: "生产", tag: "web")
        XCTAssertEqual(query.apply(to: [staging, partialTag, production]).map(\.id), [production.id])
        XCTAssertEqual(production.tagsText, "web, primary")
        XCTAssertTrue(production.enableDashboardMonitor, "A display filter must not disable collection")
    }

    func testServerBrowserSearchesHostAndTreatsWhitespaceAsEmpty() {
        let server = ServerRecord(name: "", host: "host.example.com", username: "root")
        XCTAssertEqual(ServerBrowserQuery(search: "EXAMPLE").apply(to: [server]).map(\.id), [server.id])
        XCTAssertFalse(ServerBrowserQuery(search: " \n ").hasFilters)
        XCTAssertEqual(ServerBrowserQuery(search: " \n ").apply(to: [server]).count, 1)
        XCTAssertTrue(ServerBrowserQuery(tag: "missing").apply(to: [server]).isEmpty)
    }

    func testServerBrowserNaturalSortAndStableDuplicateNames() {
        let older = ServerRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                                 name: "node2", host: "192.0.2.2", username: "root",
                                 groupName: "B", createdAt: Date(timeIntervalSince1970: 10))
        let newer = ServerRecord(name: "node10", host: "192.0.2.10", username: "root",
                                 groupName: "A", createdAt: Date(timeIntervalSince1970: 20))
        let duplicate = ServerRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                                     name: "node2", host: "192.0.2.3", username: "root",
                                     groupName: "B", createdAt: Date(timeIntervalSince1970: 10))
        let servers = [duplicate, newer, older]
        XCTAssertEqual(ServerBrowserQuery().apply(to: servers).map(\.id), [older.id, duplicate.id, newer.id])
        XCTAssertEqual(ServerBrowserQuery(sort: .nameDescending).apply(to: servers).first?.id, newer.id)
        XCTAssertEqual(ServerBrowserQuery(sort: .group).apply(to: servers).first?.id, newer.id)
        XCTAssertEqual(ServerBrowserQuery(sort: .newest).apply(to: servers).first?.id, newer.id)
    }

    func testSnippetSingleLineInsertDoesNotAppendReturn() {
        let request = snippetRequest(command: "uptime", execute: false)
        XCTAssertFalse(request.requiresConfirmation)
        XCTAssertEqual(request.payload, "uptime")
    }

    func testSnippetExecutionAndControlCharactersRequireConfirmation() {
        for command in ["uptime\nwhoami", "uptime\r", "\u{1B}[A", "hello\tworld"] {
            XCTAssertTrue(snippetRequest(command: command, execute: false).requiresConfirmation)
        }
        let run = snippetRequest(command: "uptime", execute: true)
        XCTAssertTrue(run.requiresConfirmation)
        XCTAssertEqual(run.payload, "uptime\n")
    }

    func testSnippetCannotBeDeliveredToAnotherOrDisconnectedSession() {
        let request = snippetRequest(command: "uptime", execute: true)
        XCTAssertTrue(request.canDeliver(selectedSessionID: request.sessionID, status: .connected))
        XCTAssertFalse(request.canDeliver(selectedSessionID: UUID(), status: .connected))
        XCTAssertFalse(request.canDeliver(selectedSessionID: nil, status: .connected))
        for status: TerminalConnectionStatus in [.connecting, .disconnected, .failed] {
            XCTAssertFalse(request.canDeliver(selectedSessionID: request.sessionID, status: status))
        }
        XCTAssertFalse(request.canDeliver(selectedSessionID: request.sessionID, status: nil))
    }

    private func snippetRequest(command: String, execute: Bool) -> TerminalSnippetRequest {
        TerminalSnippetRequest(snippetID: UUID(), sessionID: UUID(), serverName: "Demo",
                               title: "Check", command: command, execute: execute)
    }
}
