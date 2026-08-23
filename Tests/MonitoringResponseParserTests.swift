import XCTest
@testable import ServerDash

final class MonitoringResponseParserTests: XCTestCase {
    func testParsesLinuxMonitoringPayload() throws {
        let payload = """
        cpu=17.50
        cores=8
        load1=1.70
        load5=1.60
        load15=1.50
        mem_total_kb=16777216
        mem_available_kb=8388608
        swap_total_kb=2097152
        swap_free_kb=1048576
        disk_used=48318382080
        disk_total=493921239040
        net_rx=1200000
        net_tx=240000
        uptime=6 days, 2 hours
        distro=Ubuntu 24.04 LTS
        kernel=Linux 6.8.0
        users=2
        processes=168
        proc=918|nginx|2.8|0.7
        """

        let snapshot = try MonitoringResponseParser.parse(payload)

        XCTAssertEqual(snapshot.cpuUsage, 17.5)
        XCTAssertEqual(snapshot.coreCount, 8)
        XCTAssertEqual(snapshot.memoryUsage, 50, accuracy: 0.01)
        XCTAssertEqual(snapshot.swapUsage, 50, accuracy: 0.01)
        XCTAssertEqual(snapshot.loggedInUsers, 2)
        XCTAssertEqual(snapshot.processCount, 168)
        XCTAssertEqual(snapshot.topProcesses.first?.name, "nginx")
    }

    func testRejectsIncompletePayload() {
        XCTAssertThrowsError(try MonitoringResponseParser.parse("kernel=Linux"))
    }
}
