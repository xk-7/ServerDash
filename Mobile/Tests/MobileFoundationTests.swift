import XCTest
import SwiftUI
@testable import ServerDashMobile

final class MobileFoundationTests: XCTestCase {
    @MainActor
    func testAdaptiveStatusCardRendersAtPhoneTabletAndAccessibilitySizes() throws {
        let server = ServerRecord(name: "东京生产节点 · API 服务", host: "192.0.2.10", username: "deploy", groupName: "生产环境")
        var snapshot = ServerSnapshot.empty
        snapshot.capturedAt = .now
        snapshot.cpuUsage = 28.4
        snapshot.memoryUsedBytes = 78
        snapshot.memoryTotalBytes = 100
        snapshot.diskUsedBytes = 92
        snapshot.diskTotalBytes = 100
        snapshot.downloadBytesPerSecond = 2_400_000
        snapshot.uploadBytesPerSecond = 512_000
        for (name, width, type, scheme) in [
            ("phone-light", 343.0, DynamicTypeSize.large, ColorScheme.light),
            ("tablet-dark", 420.0, DynamicTypeSize.large, ColorScheme.dark),
            ("phone-accessibility", 343.0, DynamicTypeSize.accessibility3, ColorScheme.light)
        ] {
            let renderer = ImageRenderer(content:
                MobileServerStatusCard(server: server, snapshot: snapshot, status: .online, error: nil)
                    .frame(width: width)
                    .padding(16)
                    .background(Color.appGround)
                    .environment(\.dynamicTypeSize, type)
                    .environment(\.colorScheme, scheme)
            )
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage)
            XCTAssertEqual(image.size.width, width + 32, accuracy: 1)
            XCTAssertGreaterThan(image.size.height, 200)
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testSummarySeparatesUnknownAndPausedFromConnectionIssues() {
        let servers = (0..<6).map { ServerRecord(name: "Host \($0)", host: "example.test", username: "tester") }
        servers[5].enableDashboardMonitor = false
        let summary = MobileFleetSummary(servers: servers, statuses: [
            servers[0].id: .online, servers[1].id: .failed, servers[2].id: .offline,
            servers[3].id: .connecting, servers[5].id: .failed
        ])
        XCTAssertEqual(summary.online, 1)
        XCTAssertEqual(summary.issues, 2)
        XCTAssertEqual(summary.pending, 2)
        XCTAssertEqual(summary.paused, 1)
    }

    func testMobileBrowserMatchesMetadataWordsAndPausedMonitoring() {
        let server = ServerRecord(name: "API 10", host: "example.test", username: "deploy",
                                  groupName: "生产", tagsText: "web", notes: "备份", enableDashboardMonitor: false)
        XCTAssertEqual(ServerBrowserQuery(search: "api  DEPLOY 备份", group: "生产", tag: "web", monitoring: .paused)
            .apply(to: [server]).map(\.id), [server.id])
        XCTAssertTrue(ServerBrowserQuery(monitoring: .enabled).apply(to: [server]).isEmpty)
    }

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
