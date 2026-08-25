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
}
