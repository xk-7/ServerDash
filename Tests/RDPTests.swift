import AppKit
import Darwin
import SwiftData
import SwiftUI
import XCTest
import Network
@testable import ServerDash

final class RDPConfigurationTests: XCTestCase {
    func testCertificateValidityAndSignatureBeforeTrust() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/RDP/self-signed.pem")
        let pem = try Data(contentsOf: url)
        let evidence = try RDPCertificateVerifier.inspect(pem: pem, host: "rdp-fixture.invalid", now: Date(timeIntervalSince1970: 2_000_000_000))
        XCTAssertFalse(evidence.systemTrusted)
        XCTAssertEqual(evidence.fingerprint.split(separator: ":").count, 32)
        XCTAssertThrowsError(try RDPCertificateVerifier.inspect(pem: pem, host: "rdp-fixture.invalid", now: Date(timeIntervalSince1970: 3_000_000_000)))
        XCTAssertThrowsError(try RDPCertificateVerifier.inspect(pem: Data("not a certificate".utf8), host: "invalid"))
        let base64 = String(decoding: pem, as: UTF8.self).split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        var der = try XCTUnwrap(Data(base64Encoded: base64)); der[der.count - 1] ^= 1
        let damaged = Data("-----BEGIN CERTIFICATE-----\n\(der.base64EncodedString())\n-----END CERTIFICATE-----\n".utf8)
        XCTAssertFalse(SDRDPCertificateIsSelfSigned(damaged))
        XCTAssertThrowsError(try RDPCertificateVerifier.inspect(pem: damaged, host: "rdp-fixture.invalid", now: Date(timeIntervalSince1970: 2_000_000_000)))
    }

    func testDefaultsArePrivateAndRDPOnly() throws {
        let record = try RDPConnectionRecord(name: "Windows", host: "192.0.2.1", username: "operator")
        let config = try record.configuration()
        XCTAssertEqual(config.port, 3389)
        XCTAssertEqual(config.settings.width, 1920)
        XCTAssertEqual(config.settings.height, 1080)
        XCTAssertFalse(config.settings.textClipboard)
        XCTAssertFalse(config.settings.fileClipboard)
        XCTAssertTrue(config.settings.shares.isEmpty)
        XCTAssertNil(record.credentialReference)
        XCTAssertEqual(record.machineReference.transport, .rdp)
        XCTAssertNotEqual(record.machineReference, MachineReference(id: record.id, transport: .ssh))
        XCTAssertFalse(String(decoding: record.settingsData, as: UTF8.self).lowercased().contains("password"))
    }
    func testInvalidPortsAddressesAndDomainsFailClosed() throws {
        let record = try RDPConnectionRecord(name: "Test", host: "example.test", username: "DOMAIN\\user", domain: "DOMAIN")
        XCTAssertEqual(try record.configuration().login.username, "user")
        XCTAssertEqual(try record.configuration().login.domain, "DOMAIN")
        for invalid in [0, -1, 65536] { record.port = invalid; XCTAssertThrowsError(try record.configuration()) }
        record.port = 58431
        XCTAssertEqual(try record.configuration().port, 58431)
        record.domain = "OTHER"; XCTAssertThrowsError(try record.configuration())
        record.domain = ""; record.username = "user@example.test"
        XCTAssertNoThrow(try record.configuration())
        for invalid in ["", "rdp://example.test", "example.test/path", "a\n.test", "user@host"] {
            record.host = invalid; XCTAssertThrowsError(try record.configuration())
        }
    }
    func testScreenBudgetAndMalformedSettings() throws {
        var settings = RDPSettings()
        settings.width = 8192; settings.height = 8192
        XCTAssertThrowsError(try settings.validate())
        settings.width = 1920; settings.height = 1080; settings.colorDepth = 15
        XCTAssertThrowsError(try settings.validate())
        settings.colorDepth = 32; settings.version = 2
        XCTAssertThrowsError(try settings.validate())
        let screens = [RDPMonitor(screenID: 1, x: 0, y: 0, width: 1920, height: 1080, primary: true),
                       RDPMonitor(screenID: 2, x: 1920, y: 0, width: 1920, height: 1080, primary: false)]
        XCTAssertNoThrow(try RDPDisplayLayout.validate(screens))
        var overlapping = screens; overlapping[1].x = 10
        XCTAssertThrowsError(try RDPDisplayLayout.validate(overlapping))
        var huge = screens; huge[1].x = 32767
        XCTAssertThrowsError(try RDPDisplayLayout.validate(huge))
    }
    func testLowBandwidthPresetPreservesPrivacy() {
        var settings = RDPSettings(); settings.applyLowBandwidthPreset()
        XCTAssertTrue(settings.bitmapCache && settings.disableWallpaper && settings.disableWindowDrag && settings.disableMenuAnimations && settings.disableThemes)
        XCTAssertFalse(settings.fileClipboard || settings.textClipboard)
    }
    func testClipboardGoldenUTF16AndLargeFiles() throws {
        let files = [RDPClipboardFile(name: "中文 👩🏽‍💻.txt", size: 3), RDPClipboardFile(name: "large.bin", size: 1 << 33)]
        let data = try RDPClipboardFile.encode(files)
        XCTAssertEqual(data.count, 4 + 2 * 592)
        XCTAssertEqual(try RDPClipboardFile.decode(data), files)
        XCTAssertThrowsError(try RDPClipboardFile.decode(data.dropLast()))
        XCTAssertThrowsError(try RDPClipboardFile.decode(Data([255,255,255,255])))
        for name in ["../secret", "..", "a/b", "\\outside", "C:file", "x\0y"] {
            XCTAssertThrowsError(try RDPClipboardFile.encode([.init(name: name, size: 1)]))
        }
        let duplicate = try RDPClipboardFile.encode([.init(name: "FILE", size: 1), .init(name: "file", size: 1)])
        XCTAssertThrowsError(try RDPClipboardFile.decode(duplicate))
    }
    func testAuthenticationAndSecurityErrorsNeverRetryAsTransport() {
        XCTAssertEqual(RDPFailure.native(0x20009).kind, .authentication)
        XCTAssertEqual(RDPFailure.native(0x20008).kind, .certificate)
        XCTAssertEqual(RDPFailure.native(0x2000D).kind, .transport)
        XCTAssertEqual(RDPFailure.native(0x1000C).kind, .loggedOff)
    }
    func testTrustGateCancellationReleasesWaiterAndCannotBeReaccepted() async {
        let gate = RDPTrustGate()
        let waiting = Task.detached { gate.wait() }
        gate.resolve(false); gate.resolve(true)
        let accepted = await waiting.value
        XCTAssertFalse(accepted)
    }
    func testPinsAreHostPortScoped() throws {
        let suite = "rdp-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pins = RDPCertificatePins(defaults: defaults)
        pins.save("fingerprint", host: "EXAMPLE.TEST", port: 3389)
        XCTAssertEqual(pins.fingerprint(host: "example.test", port: 3389), "fingerprint")
        XCTAssertNil(pins.fingerprint(host: "example.test", port: 3390))
        XCTAssertNil(pins.fingerprint(host: "other.test", port: 3389))
    }
}

@MainActor
final class RDPWorkspaceTests: XCTestCase {
    func testUnifiedMachineFiltersKeepProtocolIdentityAndOrdering() throws {
        let ssh = ServerRecord(name: "Zulu Linux", host: "linux.test", username: "operator")
        let rdp = try RDPConnectionRecord(id: ssh.id, name: "Alpha Windows", host: "windows.test", username: "operator", groupName: "Office", tagsText: "prod, win")
        let values = UnifiedMachineEntry.browse(ssh: [ssh], rdp: [rdp], query: .init(), protocolFilter: "all")
        XCTAssertEqual(values.map(\.id.transport), [.rdp, .ssh]); XCTAssertNotEqual(values[0].id, values[1].id)
        let matches = UnifiedMachineEntry.browse(ssh: [ssh], rdp: [rdp], query: .init(search: "Alpha windows.test", group: "Office", tag: "prod"), protocolFilter: "all")
        XCTAssertEqual(matches.count, 1); XCTAssertEqual(matches[0].id.transport, .rdp)
        XCTAssertTrue(UnifiedMachineEntry.browse(ssh: [], rdp: [rdp], query: .init(monitoring: .enabled), protocolFilter: "all").isEmpty)
        XCTAssertTrue(UnifiedMachineEntry.browse(ssh: [], rdp: [rdp], query: .init(tag: "pro"), protocolFilter: "all").isEmpty)
    }

    func testRetryBudgetAndAuthenticationFailureIsolation() async throws {
        let config = try RDPConnectionRecord(name: "Retry fixture", host: "example.invalid", username: "operator").configuration()
        var engines: [MockRDPEngine] = []
        let delays = RDPRetryDelays()
        let controller = RDPSessionController(configuration: config, password: "fixture-only", configurationProvider: { config }, factory: {
            let engine = MockRDPEngine(); engines.append(engine); return engine
        }, retrySleep: { await delays.append($0) })
        controller.connect(); engines[0].event?(.connected)
        for _ in 0..<20 { await Task.yield() }
        for index in 0...5 {
            XCTAssertEqual(engines.count, index + 1)
            engines[index].event?(.ended(.init(kind: .transport, message: "fixture network loss")))
            for _ in 0..<30 { await Task.yield() }
        }
        XCTAssertEqual(engines.count, 6); XCTAssertEqual(controller.state, .failed)
        let actual = await delays.values; XCTAssertEqual(actual, [1, 2, 4, 8, 16])
        controller.connect(); engines.last?.event?(.connected)
        for _ in 0..<20 { await Task.yield() }
        engines.last?.event?(.ended(.init(kind: .authentication, message: "fixture rejected")))
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(engines.count, 7); XCTAssertEqual(controller.state, .failed)
        controller.close()
    }

    func testEditorAndDisconnectedDesktopLightDarkFixtures() async throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("serverdash-rdp-ui-qa")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for scheme in [ColorScheme.light, .dark] {
            let root = NSHostingView(rootView: RDPEditorView(record: nil).modelContainer(container).environment(\.colorScheme, scheme))
            root.frame = NSRect(x: 0, y: 0, width: 620, height: 740)
            let window = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = root; window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.orderFront(nil); root.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(200))
            let rep = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds)); root.cacheDisplay(in: root.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(scheme == .dark ? "editor-dark.png" : "editor-light.png"))
            window.orderOut(nil); window.contentView = nil
        }
        let config = try RDPConnectionRecord(name: "Windows · 演示", host: "example.invalid", username: "operator").configuration()
        let controller = RDPSessionController(configuration: config, configurationProvider: { config }, factory: { MockRDPEngine() })
        controller.connect(); XCTAssertTrue(controller.needsPassword)
        let root = NSHostingView(rootView: RDPDesktopPane(controller: controller))
        root.frame = NSRect(x: 0, y: 0, width: 900, height: 620)
        let window = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = root; window.orderFront(nil); root.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        let rep = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds)); root.cacheDisplay(in: root.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("desktop-disconnected.png"))
        window.orderOut(nil); window.contentView = nil; controller.close()
        print("RDP UI fixtures: \(folder.path)")
    }

    func testNativeCancellationReleasesStalledNegotiation() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let ready = expectation(description: "loopback listener"), accepted = expectation(description: "negotiation accepted")
        let finished = expectation(description: "native worker exited")
        let connections = RDPTestConnections()
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.newConnectionHandler = { connection in
            connections.append(connection); connection.start(queue: .global()); accepted.fulfill()
        }
        listener.start(queue: .global())
        defer { listener.cancel(); connections.cancel() }
        await fulfillment(of: [ready], timeout: 5)
        let port = try XCTUnwrap(listener.port)
        let config = try RDPConnectionRecord(name: "Loopback fixture", host: "127.0.0.1", port: Int(port.rawValue), username: "fixture").configuration()
        let engine = NativeRDPConnectionEngine()
        engine.start(configuration: config, password: "non-secret-fixture", trust: { _ in false }, event: {
            if case .ended = $0 { finished.fulfill() }
        })
        await fulfillment(of: [accepted], timeout: 5)
        let start = ContinuousClock.now
        engine.cancel()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        XCTAssertNil(engine.copyFrame())
    }

    func testV3DiskMigrationPreservesSSHAndAddsRDP() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rdp-migration-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("v3.store"), id = UUID()
        try autoreleasepool {
            let schema = Schema(versionedSchema: PersistenceSchemaV3.self)
            let configuration = ModelConfiguration("ServerDash", schema: schema, url: store, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: configuration)
            let record = ServerRecord(name: "Existing SSH", host: "192.0.2.10", port: 58431, username: "operator")
            record.id = id; container.mainContext.insert(record); try container.mainContext.save()
        }
        XCTAssertTrue(PersistenceController.needsV4Backup(storeURL: store))
        let configuration = ModelConfiguration("ServerDash", schema: PersistenceController.schema, url: store, cloudKitDatabase: .none)
        let container = try ModelContainer(for: PersistenceController.schema, migrationPlan: ServerDashMigrationPlan.self, configurations: configuration)
        let old = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<ServerRecord>()).first)
        XCTAssertEqual(old.id, id); XCTAssertEqual(old.host, "192.0.2.10"); XCTAssertEqual(old.port, 58431)
        let rdp = try RDPConnectionRecord(name: "New RDP", host: "192.0.2.11", username: "operator")
        container.mainContext.insert(rdp); try container.mainContext.save()
        XCTAssertFalse(PersistenceController.needsV4Backup(storeURL: store))
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<ServerRecord>()), 1)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<RDPConnectionRecord>()), 1)
    }

    func testOldClipboardCallbacksCannotReadReplacementSession() {
        var settings = RDPSettings(); settings.fileClipboard = true; settings.textClipboard = true
        let clipboard = RDPClipboardSession(settings: settings)
        weak var released: SDRDPClient?
        autoreleasepool {
            let native = SDRDPClient(configuration: [:], password: "fixture-only"); released = native
            clipboard.attach(native)
            let oldData = native.clipboardRequested, oldFile = native.fileRequested, oldFormats = native.clipboardFormats
            clipboard.reset(settings: settings)
            oldFormats?(0xC001)
            XCTAssertNil(oldData?(13)); XCTAssertNil(oldFile?(0, 0, 1024, false))
        }
        XCTAssertNil(released, "Clipboard closures must not retain their old native client")
        XCTAssertFalse(clipboard.hasActiveTransfer)
    }

    func testMixedTabsRecentReuseNeverSplitsRDPOrAffectsSSH() {
        let workspace = TerminalWorkspace(), host = UUID(), first = UUID(), second = UUID(), ssh = UUID()
        workspace.add(sessionID: first, serverID: host, title: "Windows", kind: .rdp)
        workspace.add(sessionID: second, serverID: host, title: "Windows", kind: .rdp)
        workspace.add(sessionID: ssh, serverID: host, title: "Linux")
        workspace.select(pane: first)
        XCTAssertEqual(workspace.mostRecentRDP(for: host)?.activePane, first)
        XCTAssertEqual(workspace.mostRecentTerminal(for: host), ssh)
        XCTAssertFalse(workspace.canSplit(first))
        let selected = workspace.selectedTabID
        workspace.remove(pane: second)
        XCTAssertEqual(workspace.selectedTabID, selected)
        workspace.remove(pane: first)
        XCTAssertEqual(workspace.activePane, ssh)
        workspace.remove(pane: ssh)
        XCTAssertNil(workspace.selectedTab)
    }
    func testV4ContainsNewEntityWithoutChangingV3() throws {
        XCTAssertFalse(PersistenceSchemaV3.models.contains { $0 == RDPConnectionRecord.self })
        XCTAssertTrue(PersistenceSchemaV4.models.contains { $0 == RDPConnectionRecord.self })
        let container = try PersistenceController.makeInMemoryContainer()
        let ssh = ServerRecord(name: "Linux", host: "example.test", username: "user")
        let rdp = try RDPConnectionRecord(name: "Windows", host: "example.test", username: "user")
        container.mainContext.insert(ssh); container.mainContext.insert(rdp)
        try container.mainContext.save()
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<ServerRecord>()), 1)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<RDPConnectionRecord>()), 1)
        XCTAssertEqual(MainContentRoute.rdp(rdp.id).sidebarDestination, .machines)
        XCTAssertNil(MainContentRoute.rdp(rdp.id).serverID)
    }
    func testClosedControllerRejectsLateConnectionEvents() async throws {
        let record = try RDPConnectionRecord(name: "Windows", host: "example.test", username: "user")
        let config = try record.configuration(), mock = MockRDPEngine()
        let controller = RDPSessionController(configuration: config, password: "fixture-only", configurationProvider: { config }, factory: { mock })
        controller.connect(); XCTAssertEqual(mock.starts, 1)
        controller.close(); mock.event?(.connected)
        await Task.yield()
        XCTAssertEqual(controller.state, .disconnected)
        XCTAssertTrue(mock.cancelled)
        controller.connect(); XCTAssertEqual(mock.starts, 1)
    }
    func testReconnectReadsNewConfigurationAndOldEventsDoNotWin() async throws {
        let record = try RDPConnectionRecord(name: "Windows", host: "example.test", username: "user")
        let original = try record.configuration()
        var config = original
        let first = MockRDPEngine(), second = MockRDPEngine()
        var count = 0
        let controller = RDPSessionController(configuration: original, password: "fixture-only", configurationProvider: { config }, factory: { count += 1; return count == 1 ? first : second })
        controller.connect()
        config.settings.width = 1600
        controller.connect()
        first.event?(.ended(.init(kind: .authentication, message: "stale")))
        second.event?(.connected)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertTrue(first.cancelled)
        XCTAssertEqual(controller.configuration.settings.width, 1600)
        XCTAssertEqual(controller.state, .connected)
        controller.close()
    }
    func testDestinationChangeDoesNotReuseMemoryPassword() throws {
        var config = try RDPConnectionRecord(name: "Windows", host: "one.test", username: "user").configuration()
        let mock = MockRDPEngine()
        let controller = RDPSessionController(configuration: config, password: "fixture-only", configurationProvider: { config }, factory: { mock })
        controller.connect(); config.host = "two.test"; controller.connect()
        XCTAssertTrue(controller.needsPassword)
        XCTAssertEqual(mock.starts, 1)
        controller.close()
    }
}

private final class RDPTestConnections: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [NWConnection] = []
    func append(_ value: NWConnection) { lock.lock(); values.append(value); lock.unlock() }
    func cancel() { lock.lock(); values.forEach { $0.cancel() }; values = []; lock.unlock() }
}

private actor RDPRetryDelays {
    var values: [Int] = []
    func append(_ value: Int) { values.append(value) }
}

private final class MockRDPEngine: RDPConnectionEngine, @unchecked Sendable {
    var starts = 0
    var cancelled = false
    var event: (@Sendable (RDPConnectionEvent) -> Void)?
    func start(configuration: RDPConnectionConfiguration, password: String, trust: @escaping @Sendable (RDPCertificateEvidence) -> Bool, event: @escaping @Sendable (RDPConnectionEvent) -> Void) { starts += 1; self.event = event }
    func cancel() { cancelled = true }
    func copyFrame() -> RDPFrame? { nil }
    func key(_ code: UInt16, down: Bool) { }
    func unicode(_ code: UInt16, down: Bool) { }
    func pointer(flags: UInt16, x: UInt16, y: UInt16) { }
    func monitors(_ values: [RDPMonitor]) { }
}

final class RDPDirectorySecurityTests: XCTestCase {
    func testReadOnlyRejectsWritesAndTraversal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rdp-root-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("safe".utf8).write(to: root.appendingPathComponent("test.txt"))
        let broker = try XCTUnwrap(SDRDPDirectory(url: root, readOnly: true))
        let fd = broker.openPath("test.txt", create: false, directory: false, write: false)
        XCTAssertGreaterThanOrEqual(fd, 0); if fd >= 0 { close(fd) }
        for path in ["../outside", "a/../../outside", "\\\\host\\share", "C:\\secret", "x\0z"] {
            XCTAssertLessThan(broker.openPath(path, create: false, directory: false, write: false), 0)
        }
        XCTAssertLessThan(broker.openPath("new.txt", create: true, directory: false, write: true), 0)
        XCTAssertFalse(broker.removePath("test.txt", directory: false))
        XCTAssertFalse(broker.renamePath("test.txt", to: "other.txt"))
    }
    func testWritableBrokerRejectsLinksAndNeverOverwrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rdp-root-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let broker = try XCTUnwrap(SDRDPDirectory(url: root, readOnly: false))
        let fd = broker.openPath("new.txt", create: true, directory: false, write: true)
        XCTAssertGreaterThanOrEqual(fd, 0); if fd >= 0 { close(fd) }
        XCTAssertLessThan(broker.openPath("new.txt", create: true, directory: false, write: true), 0)
        XCTAssertLessThan(broker.openPath("new.txt", create: false, directory: false, write: true), 0)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: root.path)
        XCTAssertLessThan(broker.openPath("link/new.txt", create: false, directory: false, write: false), 0)
        XCTAssertFalse(broker.removePath("link", directory: false))
        XCTAssertTrue(broker.renamePath("new.txt", to: "renamed.txt"))
        XCTAssertTrue(broker.removePath("renamed.txt", directory: false))
    }
}
