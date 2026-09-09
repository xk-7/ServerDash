import XCTest
@testable import ServerDash

final class TerminalWorkbenchTests: XCTestCase {
    func testFifteenHighlightPresetsAreUniqueAndValid() throws {
        let presets = TerminalHighlightRule.presets
        XCTAssertEqual(presets.count, 15)
        XCTAssertEqual(Set(presets.compactMap(\.presetKey)).count, 15)
        for preset in presets {
            XCTAssertLessThanOrEqual(preset.pattern.count, 256)
            _ = try NSRegularExpression(pattern: preset.pattern)
        }
        let examples = ["url": "https://example.com/log", "ipv4": "192.168.1.25", "ipv6": "2001:db8::1", "email": "ops@example.com", "iso-date": "2026-09-08", "unix-date": "Tue Sep 08", "time": "16:42:05", "syslog-date": "Sep  8 16:42:05", "uuid": "c4ff68b0-e7ab-408d-a5cf-b36493660874", "error": "ERROR", "warning": "WARNING", "success": "completed", "path": "/var/log/syslog", "mac": "AA:BB:CC:DD:EE:FF", "number": "123.45"]
        for preset in presets {
            let input = try XCTUnwrap(examples[preset.presetKey ?? ""])
            let regex = try NSRegularExpression(pattern: preset.pattern)
            XCTAssertNotNil(regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)), preset.name)
        }
    }

    @MainActor func testHighlightUpgradePreservesCustomRulesAndDisabledLegacyRule() throws {
        let suite = "terminal-workbench-tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = TerminalHighlightRule(name: "IPv4", pattern: TerminalHighlightRule.presets.first { $0.presetKey == "ipv4" }!.pattern, color: 8, enabled: false)
        let custom = TerminalHighlightRule(name: "IPv4", pattern: "CUSTOM_ONLY", color: 3)
        defaults.set(try JSONEncoder().encode([legacy, custom]), forKey: "terminal.highlight.rules")
        let settings = TerminalHighlightSettings(defaults: defaults)
        XCTAssertEqual(settings.rules.first { $0.id == legacy.id }?.enabled, false)
        XCTAssertEqual(settings.rules.first { $0.id == legacy.id }?.color, 8)
        XCTAssertEqual(settings.rules.first { $0.id == custom.id }?.pattern, custom.pattern)
        XCTAssertNil(settings.rules.first { $0.id == custom.id }?.presetKey)
        XCTAssertEqual(Set(settings.rules.compactMap(\.presetKey)).count, 9)
        XCTAssertFalse(settings.rules.contains { $0.presetKey == "url" }, "Previously deleted legacy presets stay deleted")
        let reloaded = TerminalHighlightSettings(defaults: defaults)
        XCTAssertEqual(reloaded.rules, settings.rules)
    }

    @MainActor func testHighlightUpgradeRespectsLimitWithoutDroppingCustomRules() throws {
        let suite = "terminal-workbench-limit.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let custom = (0..<32).map { TerminalHighlightRule(name: "Rule \($0)", pattern: "term\($0)", color: 0) }
        defaults.set(try JSONEncoder().encode(custom), forKey: "terminal.highlight.rules")
        XCTAssertEqual(TerminalHighlightSettings(defaults: defaults).rules, custom)
    }

    func testBatchRequestCapturesTargetsAndRejectsControlSequences() {
        let first = TerminalBatchTarget(id: UUID(), serverID: UUID(), title: "First", endpoint: "root@a")
        let second = TerminalBatchTarget(id: UUID(), serverID: UUID(), title: "Second", endpoint: "root@b")
        var selection = [first, second]
        let request = TerminalBatchRequest(command: "printf 'ok'\npwd", targets: selection)
        selection.removeAll()
        XCTAssertTrue(request.isValid)
        XCTAssertEqual(request.targets, [first, second])
        XCTAssertEqual(request.payload, "printf 'ok'\npwd\r")
        XCTAssertFalse(TerminalBatchRequest(command: "\u{1B}[3J", targets: [first]).isValid)
        XCTAssertFalse(TerminalBatchRequest(command: "pwd", targets: [first, first]).isValid)
        XCTAssertFalse(TerminalBatchRequest(command: "pwd", targets: []).isValid)
    }

    func testFiltersRespectExplicitAllowlistAndLeaveSourceUnchanged() {
        let root = FilesystemMetric(device: "/dev/vda1", mountPoint: "/", filesystemType: "ext4", usedBytes: 10, totalBytes: 100)
        let docker = FilesystemMetric(device: "overlay", mountPoint: "/var/lib/docker/overlay2/test", filesystemType: "overlay", usedBytes: 10, totalBytes: 100)
        let virtual = NetworkInterfaceMetric(name: "docker0", receivedBytes: 1, sentBytes: 1)
        let physical = NetworkInterfaceMetric(name: "eth0", receivedBytes: 100, sentBytes: 200)
        let defaults = MonitoringFilters()
        XCTAssertTrue(defaults.includes(root))
        XCTAssertFalse(defaults.includes(docker))
        XCTAssertFalse(defaults.includes(virtual))
        XCTAssertTrue(defaults.includes(physical))
        var allowed = defaults
        allowed.mountPoints = " /var/lib/docker/overlay2/test ; /home "
        allowed.interfaceNames = "docker0，wlan0"
        XCTAssertTrue(allowed.includes(docker))
        XCTAssertFalse(allowed.includes(root))
        XCTAssertTrue(allowed.includes(virtual))
        XCTAssertFalse(allowed.includes(physical))
        var snapshot = ServerSnapshot.empty
        snapshot.filesystems = [root, docker]
        snapshot.networkInterfaces = [virtual, physical]
        let filtered = defaults.applying(to: snapshot)
        XCTAssertEqual(filtered.filesystems, [root])
        XCTAssertEqual(filtered.networkInterfaces, [physical])
        XCTAssertEqual(snapshot.filesystems.count, 2)
    }

    func testOptionalNetworkAndCPUMetricsDistinguishMissingAndFailedData() throws {
        let absent = try MonitoringResponseParser.parse("mem_total_kb=100")
        XCTAssertNil(absent.cpuUserPercent)
        XCTAssertNil(absent.sockets)
        XCTAssertFalse(absent.listeningPortsAvailable)
        XCTAssertNil(absent.listeningPortsError)
        let failed = try MonitoringResponseParser.parse("mem_total_kb=100\nlisteners_error=permission denied")
        XCTAssertEqual(failed.listeningPortsError, "permission denied")
        let value = try MonitoringResponseParser.parse("""
        mem_total_kb=100
        cpu_user=1.9
        cpu_system=1.2
        cpu_iowait=0.0
        socket_total=195
        socket_tcp=3
        socket_udp=1
        socket_listening=3
        socket_timewait=8
        file_handles_used=1472
        file_handles_limit=9223372036854775807
        listeners_available=1
        listener=tcp|[::]:22|users:((sshd,pid=123))
        listener=tcp|[::]:22|users:((sshd,pid=123))
        """)
        XCTAssertEqual(value.cpuUserPercent, 1.9)
        XCTAssertEqual(value.cpuIOWaitPercent, 0)
        XCTAssertEqual(value.sockets?.total, 195)
        XCTAssertEqual(value.sockets?.timeWait, 8)
        XCTAssertEqual(value.fileHandlesLimit, Int.max)
        XCTAssertTrue(value.listeningPortsAvailable)
        XCTAssertEqual(value.listeningPorts.count, 1)
        XCTAssertEqual(value.listeningPorts.first?.address, "[::]:22")
    }
}
