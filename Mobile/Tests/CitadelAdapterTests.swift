import Foundation
import XCTest

@testable import ServerDashMobile

final class CitadelAdapterTests: XCTestCase {
    func testEd25519OpenSSHKeyCanBeInspectedWithoutPersistingAPath() throws {
        let key = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACAi19yxbgtZH0Y26GZGr2vyVErGFskeOY9HwHLxYbmkAwAAAKAPNV8QDzVf
        EAAAAAtzc2gtZWQyNTUxOQAAACAi19yxbgtZH0Y26GZGr2vyVErGFskeOY9HwHLxYbmkAw
        AAAED3UDHB29MB7vQDpb7PGFjEMAYT9FzpnadYWrCPSUma5SLX3LFuC1kfRjboZkava/JU
        SsYWyR45j0fAcvFhuaQDAAAAHGphYXBASmFhcHMtTWFjQm9vay1Qcm8ubG9jYWwB
        -----END OPENSSH PRIVATE KEY-----
        """

        let result = try MobileSSHKeyCodec.inspect(pem: key, passphrase: nil)
        XCTAssertEqual(result.algorithm, "ED25519")
        XCTAssertTrue(result.publicKey.hasPrefix("ssh-ed25519 "))
        XCTAssertTrue(result.fingerprint.hasPrefix("SHA256:"))
    }

    func testMalformedPrivateKeyIsRejected() {
        XCTAssertThrowsError(
            try MobileSSHKeyCodec.inspect(
                pem: "-----BEGIN OPENSSH PRIVATE KEY-----\ninvalid\n-----END OPENSSH PRIVATE KEY-----",
                passphrase: nil
            )
        ) { error in
            XCTAssertEqual(error as? RemoteConnectionFailure, .invalidPrivateKey)
        }
    }

    func testIndirectRouteFailsBeforeAuthenticationOrNetworkAccess() async {
        let id = UUID()
        var config = RemoteConnectionContractTests.makeConfig(id: id)
        config.route = ConnectionRoute(
            name: "Mobile unsupported route",
            hops: [
                ConnectionHop(
                    name: "Jump",
                    endpoint: ConnectionEndpoint(
                        host: "jump.example.test",
                        port: 22,
                        username: "jump"
                    ),
                    credential: .sshAgent
                )
            ]
        )

        do {
            _ = try await CitadelRemoteConnectionEngine().connect(config) { _ in
                XCTFail("A rejected route must not begin host-key negotiation")
                return .reject
            }
            XCTFail("Expected indirectRouteUnsupported")
        } catch {
            XCTAssertEqual(error as? RemoteConnectionFailure, .indirectRouteUnsupported)
        }
    }

    func testDiagnosticsRedactPasswordPrivateKeyAndSessionPayload() {
        let armor = "OPENSSH " + "PRIVATE KEY"
        let privateKey = "-----BEGIN \(armor)-----\nprivate-material\n-----END \(armor)-----"
        let value = "password=mobile-secret\n\(privateKey)\nsession token=terminal-secret"
        let redacted = DiagnosticRedactor.redact(value, hideIP: false)

        XCTAssertFalse(redacted.contains("mobile-secret"))
        XCTAssertFalse(redacted.contains("private-material"))
        XCTAssertFalse(redacted.contains("terminal-secret"))
        XCTAssertTrue(redacted.contains("[REDACTED]"))
    }
}
