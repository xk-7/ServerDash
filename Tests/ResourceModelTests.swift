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
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        _ = try ModelContainer(
            for: ServerRecord.self,
            IdentityRecord.self,
            SSHKeyRecord.self,
            CommandSnippetRecord.self,
            configurations: configuration
        )
    }
}
