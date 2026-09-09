import AppKit
import Darwin
import SwiftData
import SwiftTerm
import XCTest
@testable import ServerDash

final class WorkbenchConnectionTests: XCTestCase {
    func testVNCURLNeverContainsCredentialsAndSupportsIPv6() throws {
        XCTAssertEqual(try VNCAddress.url(host: "example.test", port: 5901).absoluteString, "vnc://example.test:5901")
        XCTAssertEqual(try VNCAddress.url(host: "2001:db8::1", port: 5900).absoluteString, "vnc://[2001:db8::1]:5900")
        for host in ["user:secret@example.test", "vnc://example.test", "example.test/path", "host\nexample", "x:password", ""] {
            XCTAssertThrowsError(try VNCAddress.url(host: host, port: 5900), host)
        }
        XCTAssertThrowsError(try VNCAddress.url(host: "example.test", port: 0))
    }

    func testSSHOptionsPreserveLegacyAndApplyAdvancedValues() throws {
        var config = fixtureConfig()
        let old = try SSHSupport.directArguments(for: config, strictHostChecking: "yes")
        XCTAssertTrue(old.contains("ServerAliveInterval=15")); XCTAssertTrue(old.contains("ServerAliveCountMax=3"))
        var advanced = SSHAdvancedSettingsDraft()
        advanced.keepAliveInterval = 47; advanced.keepAliveCountMax = 6; advanced.connectTimeout = 120
        config.advancedSettings = advanced
        let args = try SSHSupport.directArguments(for: config, strictHostChecking: "yes")
        XCTAssertTrue(args.contains("ConnectTimeout=120")); XCTAssertTrue(args.contains("ServerAliveInterval=47"))
        XCTAssertTrue(args.contains("ServerAliveCountMax=6")); XCTAssertFalse(args.contains("ServerAliveInterval=15"))
        advanced.keepAliveEnabled = false; config.advancedSettings = advanced
        XCTAssertTrue(try SSHSupport.directArgumentsForSFTP(config: config).contains("ServerAliveInterval=0"))
        XCTAssertFalse(advanced.commandsEnabled)
        XCTAssertNoThrow(try advanced.validate())
    }

    func testRoutedSSHOptionsUseTheSameAdvancedValues() throws {
        var config = fixtureConfig()
        config.route = ConnectionRoute(name: "Test", hops: [.init(name: "Jump", endpoint: .init(host: "jump.invalid", port: 22, username: "test"), credential: .sshAgent)])
        var options = SSHAdvancedSettingsDraft(); options.connectTimeout = 65; options.keepAliveInterval = 42
        config.advancedSettings = options
        let plan = try SystemOpenSSHConnectionProvider(credentialProvider: FixtureCredentialProvider()).launchPlan(for: config, purpose: .interactiveShell)
        let index = try XCTUnwrap(plan.arguments.firstIndex(of: "-F"))
        let text = try String(contentsOfFile: plan.arguments[index + 1], encoding: .utf8)
        XCTAssertTrue(text.contains("ConnectTimeout 65")); XCTAssertTrue(text.contains("ServerAliveInterval 42"))
        XCTAssertFalse(text.contains("LocalCommand"))
    }

    func testHandshakeMarkerOptionsAreAcceptedWithoutMakingAConnection() throws {
        let marker = try SSHSessionBootstrap.handshakeMarker(); defer { SSHSessionBootstrap.removeMarker(marker) }
        let process = Process(); let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G"] + SSHSessionBootstrap.markerArguments(marker) + ["example.invalid"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = error
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testAuthenticationWaitRequiresMarkerAndHonorsTimeoutAndCancellation() async throws {
        let marker = try SSHSessionBootstrap.handshakeMarker(); defer { SSHSessionBootstrap.removeMarker(marker) }
        do { try await SSHSessionBootstrap.waitForAuthentication(marker: marker, timeout: 0.05); XCTFail("Missing marker must time out") }
        catch { XCTAssertTrue(error.localizedDescription.contains("超时")) }
        let waiter = Task { try await SSHSessionBootstrap.waitForAuthentication(marker: marker, timeout: 2) }
        try await Task.sleep(for: .milliseconds(60))
        try Data().write(to: marker); try await waiter.value
        try FileManager.default.removeItem(at: marker)
        let cancelled = Task { try await SSHSessionBootstrap.waitForAuthentication(marker: marker, timeout: 60) }
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("Cancelled authentication must stop") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testLocalHookRunsInAnIsolatedShellWithoutChangingSSHEnvironment() async throws {
        let marker = "SERVERDASH_HOOK_FIXTURE_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let output = try await SSHSessionBootstrap.runLocalCommand("export \(marker)=fixture; printf \"$\(marker)\"", serverID: UUID())
        XCTAssertEqual(output, "fixture")
        XCTAssertNil(ProcessInfo.processInfo.environment[marker])
        XCTAssertNil(SSHSupport.environment(for: fixtureConfig())[marker])
    }

    @MainActor func testNewMetadataAndAdvancedSettingsPersistSeparately() throws {
        let container = try PersistenceController.makeInMemoryContainer(); let context = ModelContext(container)
        let id = UUID(); let vnc = VNCConnectionRecord(name: "Desktop", host: "desktop.invalid")
        let serial = SerialConnectionRecord(name: "Board", devicePath: "/dev/cu.fixture")
        context.insert(vnc); context.insert(serial)
        var draft = SSHAdvancedSettingsDraft(); draft.connectTimeout = 120; draft.commandsEnabled = true
        try SSHAdvancedSettingsRecord.upsert(serverID: id, settings: draft, in: context); try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<VNCConnectionRecord>()).first?.id, vnc.id)
        XCTAssertEqual(try context.fetch(FetchDescriptor<SerialConnectionRecord>()).first?.baudRate, 115200)
        XCTAssertEqual(SSHAdvancedSettingsRecord.load(serverID: id, in: context), draft)
        XCTAssertEqual(SSHAdvancedSettingsRecord.load(serverID: UUID(), in: context).keepAliveInterval, 15)
    }

    @MainActor func testRuntimeCacheLoadsAndRetainsAdvancedConnectionOptions() throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let context = container.mainContext
        let server = ServerRecord(name: "Fixture", host: "192.0.2.18", username: "test", enableDashboardMonitor: false)
        context.insert(server)
        var advanced = SSHAdvancedSettingsDraft(); advanced.connectTimeout = 75; advanced.keepAliveInterval = 43
        try SSHAdvancedSettingsRecord.upsert(serverID: server.id, settings: advanced, in: context)
        try context.save()
        let app = AppState(trustCoordinator: HostTrustCoordinator(), fileServicesEnabled: false)
        app.initializeRuntime(for: server, synchronizeMonitoring: false)
        XCTAssertEqual(app.configs[server.id]?.advancedSettings, advanced)
        XCTAssertEqual(app.configs[server.id]?.connectTimeout, 75)
        app.applyResolvedConfigs([server.id: server.connectionConfig])
        XCTAssertEqual(app.configs[server.id]?.advancedSettings, advanced, "Refreshing credentials/routes must preserve advanced options")
        XCTAssertEqual(app.configs[server.id]?.connectTimeout, 75)
        XCTAssertTrue(app.terminalRegistry.controllers.isEmpty)
    }

    @MainActor func testLocalShellRendersOutputAndEnds() async throws {
        let config = LocalShellConfiguration(executable: "/bin/sh", arguments: ["-c", "printf local-shell-fixture"], environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"], workingDirectory: NSTemporaryDirectory())
        let controller = WorkbenchSessionController(local: config); controller.hostView.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        controller.reconnect(); defer { controller.close() }
        let deadline = Date().addingTimeInterval(3)
        while controller.status == .connected, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(controller.status, .disconnected)
        let terminal = try XCTUnwrap(controller.hostView as? SwiftTerm.TerminalView)
        let rendered = terminal.getTerminal().displaySnapshot(followOutput: true).lines.map { $0.cells.filter { $0.width != 0 }.map(\.text).joined() }.joined(separator: "\n")
        XCTAssertTrue(rendered.contains("local-shell-fixture"), rendered)
    }

    func testLocalShellEmptyPathFallsBackAndCleanEnvironmentSkipsUserStartup() throws {
        let suite = "local-shell-\(UUID())"; let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("", forKey: "workbench.localShellPath")
        XCTAssertFalse(LocalShellConfiguration.current(defaults: defaults).executable.isEmpty)
        defaults.set("/bin/zsh", forKey: "workbench.localShellPath")
        defaults.set("clean", forKey: "workbench.localShellEnvironment")
        let config = LocalShellConfiguration.current(defaults: defaults)
        XCTAssertEqual(config.arguments, ["-f"]); XCTAssertEqual(config.environment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertNil(config.environment["SSH_AUTH_SOCK"])
    }

    func testSerialTransportExchangesBytesThroughPTYAndCloses() async throws {
        var master: Int32 = -1; var slave: Int32 = -1
        var path = [CChar](repeating: 0, count: 1024)
        XCTAssertEqual(openpty(&master, &slave, &path, nil, nil), 0)
        guard master >= 0, slave >= 0 else { return }
        Darwin.close(slave); defer { Darwin.close(master) }
        let transport = SerialPortTransport(); defer { transport.close() }
        let received = expectation(description: "Serial receives PTY bytes")
        let data = ConnectionTestBytes()
        try transport.open(.init(devicePath: String(cString: path)), output: { bytes in
            if data.append(bytes).contains("device-output") { received.fulfill() }
        }, ended: { _ in })
        let outgoing = Data("device-output".utf8)
        XCTAssertEqual(outgoing.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }, outgoing.count)
        await fulfillment(of: [received], timeout: 2)
        transport.write(Data("user-input".utf8))
        var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&descriptor, 1, 2000), 1)
        var buffer = [UInt8](repeating: 0, count: 128)
        let count = Darwin.read(master, &buffer, buffer.count)
        XCTAssertGreaterThan(count, 0)
        if count > 0 { XCTAssertTrue(String(decoding: buffer.prefix(count), as: UTF8.self).contains("user-input")) }
        transport.close(); transport.write(Data("ignored-after-close".utf8))
    }

    func testSerialCloseDrainsSourceCancellationBeforeImmediateReopen() throws {
        var master: Int32 = -1; var slave: Int32 = -1
        var path = [CChar](repeating: 0, count: 1024)
        XCTAssertEqual(openpty(&master, &slave, &path, nil, nil), 0)
        guard master >= 0, slave >= 0 else { return }
        Darwin.close(slave); defer { Darwin.close(master) }
        let transport = SerialPortTransport(); defer { transport.close() }
        for _ in 0..<25 {
            try transport.open(.init(devicePath: String(cString: path)), output: { _ in }, ended: { _ in })
            // Saturate the PTY so close must retire both read and write dispatch sources.
            transport.write(Data(repeating: 0x61, count: 1024 * 1024))
            transport.close()
        }
    }

    @MainActor func testSerialExplicitReconnectLoadsEditedDeviceAndRejectsDeletedRecord() async throws {
        var firstMaster: Int32 = -1, firstSlave: Int32 = -1
        var secondMaster: Int32 = -1, secondSlave: Int32 = -1
        var firstPath = [CChar](repeating: 0, count: 1024), secondPath = [CChar](repeating: 0, count: 1024)
        guard openpty(&firstMaster, &firstSlave, &firstPath, nil, nil) == 0 else { return XCTFail("Could not create first PTY") }
        defer { Darwin.close(firstMaster); Darwin.close(firstSlave) }
        guard openpty(&secondMaster, &secondSlave, &secondPath, nil, nil) == 0 else { return XCTFail("Could not create second PTY") }
        defer { Darwin.close(secondMaster); Darwin.close(secondSlave) }
        let container = try PersistenceController.makeInMemoryContainer()
        let record = SerialConnectionRecord(name: "PTY fixture", devicePath: String(cString: firstPath))
        container.mainContext.insert(record); try container.mainContext.save()
        let controller = WorkbenchSessionController(record: record)
        controller.hostView.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        controller.reconnect(); defer { controller.close() }
        XCTAssertEqual(controller.status, .connected)
        let writer = ModelContext(container)
        let edited = try XCTUnwrap(writer.fetch(FetchDescriptor<SerialConnectionRecord>()).first)
        edited.devicePath = String(cString: secondPath); edited.baudRate = 9600; try writer.save()
        let terminal = try XCTUnwrap(controller.hostView as? SwiftTerm.TerminalView)
        func rendered() -> String {
            terminal.getTerminal().displaySnapshot(followOutput: true).lines.map { $0.cells.filter { $0.width != 0 }.map(\.text).joined() }.joined(separator: "\n")
        }
        let before = Data("old-port-still-active\r\n".utf8)
        XCTAssertEqual(before.withUnsafeBytes { Darwin.write(firstMaster, $0.baseAddress, $0.count) }, before.count)
        var deadline = Date().addingTimeInterval(2)
        while !rendered().contains("old-port-still-active"), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(rendered().contains("old-port-still-active"), "Editing must not move the active connection")
        controller.reconnect()
        XCTAssertEqual(controller.status, .connected)
        var parameters = termios()
        XCTAssertEqual(tcgetattr(secondSlave, &parameters), 0)
        XCTAssertEqual(cfgetospeed(&parameters), speed_t(9600))
        let after = Data("new-port-after-reconnect\r\n".utf8)
        XCTAssertEqual(after.withUnsafeBytes { Darwin.write(secondMaster, $0.baseAddress, $0.count) }, after.count)
        deadline = Date().addingTimeInterval(2)
        while !rendered().contains("new-port-after-reconnect"), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(rendered().contains("new-port-after-reconnect"))
        writer.delete(edited); try writer.save()
        controller.reconnect()
        XCTAssertEqual(controller.status, .failed)
        XCTAssertTrue(controller.lastError?.contains("已删除") == true)
    }

    func testHTTPProxyRequestRewritesAbsoluteURLAndStripsProxyCredentials() throws {
        let request = try HTTPProxyRequest.parse(Data("GET http://example.test:8080/a%20b?q=1 HTTP/1.1\r\nHost: example.test:8080\r\nProxy-Authorization: Basic secret\r\nProxy-Connection: keep-alive\r\n\r\n".utf8))
        XCTAssertEqual(request.host, "example.test"); XCTAssertEqual(request.port, 8080); XCTAssertFalse(request.tunnel)
        let header = String(decoding: request.forwardedHeader, as: UTF8.self)
        XCTAssertTrue(header.hasPrefix("GET /a%20b?q=1 HTTP/1.1")); XCTAssertTrue(header.contains("Connection: close"))
        XCTAssertFalse(header.contains("secret")); XCTAssertFalse(header.contains("Proxy-Connection"))
        let mismatched = try HTTPProxyRequest.parse(Data("GET http://target.invalid/path HTTP/1.1\r\nHost: wrong.invalid\r\n\r\n".utf8))
        XCTAssertTrue(String(decoding: mismatched.forwardedHeader, as: UTF8.self).contains("Host: target.invalid"))
        XCTAssertFalse(String(decoding: mismatched.forwardedHeader, as: UTF8.self).contains("wrong.invalid"))
        XCTAssertThrowsError(try HTTPProxyRequest.parse(Data("GET http://target.invalid/ HTTP/1.1\r\nHost: target.invalid\nInjected: header\r\n\r\n".utf8)))
        let connect = try HTTPProxyRequest.parse(Data("CONNECT [2001:db8::1]:443 HTTP/1.1\r\nHost: [2001:db8::1]:443\r\n\r\n".utf8))
        XCTAssertTrue(connect.tunnel); XCTAssertEqual(connect.host, "2001:db8::1"); XCTAssertEqual(connect.port, 443)
        XCTAssertThrowsError(try HTTPProxyRequest.parse(Data("CONNECT user:secret@example.test:443 HTTP/1.1\r\n\r\n".utf8)))
    }

    func testHTTPConnectRelaysThroughSOCKSAndStopReleasesListener() async throws {
        let fixture = try SOCKSLoopbackFixture()
        let negotiated = expectation(description: "SOCKS backend negotiated and echoed")
        fixture.run { host, payload in
            XCTAssertEqual(host, "example.invalid"); XCTAssertEqual(payload, "hello-through-tunnel"); negotiated.fulfill()
        }
        let port = try HTTPToSOCKSProxy.availableLoopbackPort()
        let proxy = HTTPToSOCKSProxy(socksPort: fixture.port)
        try proxy.start(bindAddress: "127.0.0.1", port: port); defer { proxy.stop(); fixture.close() }
        let client = try SOCKSLoopbackFixture.connect(port: port); defer { Darwin.close(client) }
        try SOCKSLoopbackFixture.write(client, Data("CONNECT example.invalid:443 HTTP/1.1\r\nHost: example.invalid:443\r\n\r\nhello-through-tunnel".utf8))
        var response = Data()
        while !String(decoding: response, as: UTF8.self).contains("hello-through-tunnel") {
            let chunk = try SOCKSLoopbackFixture.read(client, maximum: 1024)
            if chunk.isEmpty { break }; response.append(chunk)
        }
        let text = String(decoding: response, as: UTF8.self)
        XCTAssertTrue(text.contains("200 Connection Established")); XCTAssertTrue(text.contains("hello-through-tunnel"))
        await fulfillment(of: [negotiated], timeout: 3)
        proxy.stop()
        let deadline = Date().addingTimeInterval(2)
        while !LocalPortAvailability.isAvailable(address: "127.0.0.1", port: port, reuseAddress: true), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(LocalPortAvailability.isAvailable(address: "127.0.0.1", port: port, reuseAddress: true))
    }

    private func fixtureConfig() -> ServerConnectionConfig {
        .init(id: UUID(), credentialID: UUID(), name: "Fixture", host: "example.invalid", port: 22, username: "fixture", authentication: .password, privateKeyPath: "")
    }
}

private struct FixtureCredentialProvider: CredentialProvider {
    func resolve(_ reference: CredentialReference, hopID: UUID) throws -> ResolvedCredential {
        switch reference { case .sshAgent: .sshAgent; default: .password(account: "fixture-not-a-real-credential") }
    }
}
private final class ConnectionTestBytes: @unchecked Sendable {
    private let lock = NSLock(); private var data = Data()
    func append(_ bytes: Data) -> String { lock.lock(); defer { lock.unlock() }; data.append(bytes); return String(decoding: data, as: UTF8.self) }
}

private final class SOCKSLoopbackFixture: @unchecked Sendable {
    let port: Int
    private var listener: Int32
    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        listener = fd
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0, listen(fd, 4) == 0 else { Darwin.close(fd); throw POSIXError(.EIO) }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
        port = Int(UInt16(bigEndian: address.sin_port))
    }
    func run(completion: @escaping @Sendable (String, String) -> Void) {
        let fd = listener
        DispatchQueue.global().async {
            let client = accept(fd, nil, nil); guard client >= 0 else { return }; defer { Darwin.close(client) }
            Self.configure(client)
            do {
                guard try Self.exact(client, count: 3) == Data([5, 1, 0]) else { return }
                try Self.write(client, Data([5, 0]))
                guard try Self.exact(client, count: 4) == Data([5, 1, 0, 3]) else { return }
                let length = Int(try Self.exact(client, count: 1)[0])
                let host = String(decoding: try Self.exact(client, count: length), as: UTF8.self)
                _ = try Self.exact(client, count: 2)
                try Self.write(client, Data([5, 0, 0, 1, 127, 0, 0, 1, 0, 80]))
                let payload = try Self.exact(client, count: "hello-through-tunnel".utf8.count)
                try Self.write(client, payload); completion(host, String(decoding: payload, as: UTF8.self))
            } catch { XCTFail("Loopback SOCKS fixture: \(error)") }
        }
    }
    func close() { if listener >= 0 { Darwin.close(listener); listener = -1 } }
    deinit { close() }
    static func connect(port: Int) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { throw POSIXError(.EIO) }
        configure(fd)
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = UInt16(port).bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0 else { Darwin.close(fd); throw POSIXError(.ECONNREFUSED) }; return fd
    }
    static func write(_ fd: Int32, _ data: Data) throws {
        var sent = 0
        while sent < data.count {
            let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: sent), $0.count - sent) }
            guard count > 0 else { throw POSIXError(.EIO) }; sent += count
        }
    }
    static func read(_ fd: Int32, maximum: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: maximum); let count = Darwin.read(fd, &bytes, maximum)
        guard count >= 0 else { throw POSIXError(.EIO) }; return Data(bytes.prefix(count))
    }
    private static func exact(_ fd: Int32, count: Int) throws -> Data {
        var data = Data()
        while data.count < count { let next = try read(fd, maximum: count - data.count); guard !next.isEmpty else { throw POSIXError(.EIO) }; data.append(next) }
        return data
    }
    private static func configure(_ fd: Int32) {
        var timeout = timeval(tv_sec: 3, tv_usec: 0); var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    }
}
