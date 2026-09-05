import XCTest
@testable import ServerDashMobile

final class MobileFoundationTests: XCTestCase {
    func testMobileCapabilitiesFailClosedForDesktopOnlyFeatures() {
        let capabilities = PlatformCapabilities.mobile
        XCTAssertTrue(capabilities.interactiveShell)
        XCTAssertTrue(capabilities.remoteCommand)
        XCTAssertTrue(capabilities.fileTransfer)
        XCTAssertFalse(capabilities.jumpHosts)
        XCTAssertFalse(capabilities.localForward)
        XCTAssertFalse(capabilities.sshAgent)
        XCTAssertFalse(capabilities.externalPrivateKeyPath)
    }

    func testRemoteHostKeyFingerprintUsesOpenSSHBlob() {
        let key = RemoteHostKeyPresentation(
            host: "example.com",
            port: 2222,
            algorithm: "ssh-ed25519",
            keyBlob: Data([0, 1, 2, 3])
        )
        XCTAssertTrue(key.fingerprint.hasPrefix("SHA256:"))
        XCTAssertTrue(key.keyLine.hasPrefix("[example.com]:2222 ssh-ed25519 "))
    }

    func testShellDimensionsAreNormalized() {
        let value = RemoteShellDimensions(
            columns: 0,
            rows: -2,
            pixelWidth: -1,
            pixelHeight: 40
        ).normalized
        XCTAssertEqual(value.columns, 2)
        XCTAssertEqual(value.rows, 2)
        XCTAssertEqual(value.pixelWidth, 0)
        XCTAssertEqual(value.pixelHeight, 40)
    }
}
