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

    func testAcceptsPayloadWhenOptionalCPUSampleIsUnavailable() throws {
        let snapshot = try MonitoringResponseParser.parse("mem_total_kb=1024")

        XCTAssertEqual(snapshot.cpuUsage, 0)
        XCTAssertEqual(snapshot.memoryTotalBytes, 1024 * 1024)
    }

    func testParsesExtendedMonitoringPayload() throws {
        let vnStatJSON = """
        {
          "interfaces": [{
            "name": "eth0",
            "traffic": {
              "hour": [{
                "date": {"year": 2026, "month": 8, "day": 24},
                "time": {"hour": 9, "minute": 0},
                "rx": 1200,
                "tx": 300
              }],
              "day": [{
                "date": {"year": 2026, "month": 8, "day": 24},
                "rx": 12000,
                "tx": 3000
              }],
              "month": [],
              "year": []
            }
          }]
        }
        """
        let geoJSON = """
        {
          "ip": "203.0.113.10",
          "city": "Singapore",
          "region": "Singapore",
          "country": "SG",
          "org": "AS64500 Example",
          "loc": "1.2903,103.8519"
        }
        """
        let payload = """
        cpu=42.5
        cores=2
        cpu_model=Example CPU
        cpu_temp=55.5
        core=0|20|10|1|2|3
        core=1|30|11|0|1|0
        load1=1.1
        load5=0.8
        load15=0.5
        mem_total_kb=1000
        mem_available_kb=500
        mem_free_kb=100
        mem_cached_kb=200
        mem_buffers_kb=50
        swap_total_kb=200
        swap_free_kb=150
        disk_used=400
        disk_total=1000
        iface=eth0|10000|20000
        active_iface=eth0
        net_rx=10000
        net_tx=20000
        fs=/dev/vda1|ext4|400|1000|/
        diskio=vda|1024|2048|3|4|1.2|1.5|100000|200000
        uptime=2 days
        distro=Example Linux
        kernel=Linux 6.8
        users=1
        processes=24
        proc=12|root|exampled|8.5|1.2|4|/usr/bin/exampled --serve
        gpu_driver=555.1
        cuda_version=12.5
        gpu=0|GPU-123|Example GPU|75|1024|8192|40|62|120|250
        gproc=GPU-123|99|python|512
        docker_available=1
        docker_version=27.0
        dcont=abcdef|web|nginx:latest|running|Up 2 hours
        vnstat_available=1
        vnstat_source=vnstat
        vnstat_json=\(Data(vnStatJSON.utf8).base64EncodedString())
        geo_json=\(Data(geoJSON.utf8).base64EncodedString())
        """

        let snapshot = try MonitoringResponseParser.parse(payload)

        XCTAssertEqual(snapshot.cpuModel, "Example CPU")
        XCTAssertEqual(snapshot.cpuTemperatureCelsius, 55.5)
        XCTAssertEqual(snapshot.cpuCores.count, 2)
        XCTAssertEqual(snapshot.cpuCores[0].usage, 36, accuracy: 0.01)
        XCTAssertEqual(snapshot.memoryUsedBytes, 650 * 1024)
        XCTAssertEqual(snapshot.memoryCachedBytes, 250 * 1024)
        XCTAssertEqual(snapshot.activeNetworkInterface, "eth0")
        XCTAssertTrue(snapshot.networkInterfaces[0].isActive)
        XCTAssertEqual(snapshot.filesystems.first?.mountPoint, "/")
        XCTAssertEqual(snapshot.diskIO.first?.readIOPS, 3)
        XCTAssertEqual(snapshot.processes.first?.user, "root")
        XCTAssertEqual(snapshot.processes.first?.threadCount, 4)
        XCTAssertEqual(snapshot.gpus.first?.uuid, "GPU-123")
        XCTAssertEqual(snapshot.gpuProcesses.first?.pid, 99)
        XCTAssertTrue(snapshot.dockerAvailable)
        XCTAssertEqual(snapshot.dockerContainers.first?.name, "web")
        XCTAssertEqual(snapshot.vnStatHistory.filter { $0.period == .hourly }.count, 1)
        XCTAssertEqual(snapshot.vnStatHistory.filter { $0.period == .weekly }.count, 1)
        XCTAssertEqual(snapshot.geoLocation?.country, "SG")
        XCTAssertEqual(snapshot.geoLocation?.latitude ?? 0, 1.2903, accuracy: 0.0001)
    }

    func testMarksEmptyVnStatDatabaseAsCollecting() throws {
        let json = """
        {"interfaces":[{"traffic":{"hour":[],"day":[],"month":[],"year":[]}}]}
        """
        let payload = """
        cpu=1
        mem_total_kb=100
        vnstat_available=1
        vnstat_json=\(Data(json.utf8).base64EncodedString())
        """

        let snapshot = try MonitoringResponseParser.parse(payload)

        XCTAssertTrue(snapshot.vnStatAvailable)
        XCTAssertTrue(snapshot.vnStatCollecting)
    }

    func testRemoteCollectorHasValidShellSyntax() throws {
        for command in [
            SSHMonitoringService.remoteCommand,
            SSHMonitoringService.fallbackRemoteCommand
        ] {
            let prefix = "sh -lc '\n"
            let suffix = "\n'"
            XCTAssertTrue(command.hasPrefix(prefix))
            XCTAssertTrue(command.hasSuffix(suffix))
            let script = String(command.dropFirst(prefix.count).dropLast(suffix.count))

            let process = Process()
            let errorPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-n", "-c", script]
            process.standardError = errorPipe
            try process.run()
            process.waitUntilExit()

            let error = String(
                decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            XCTAssertEqual(process.terminationStatus, 0, error)
        }
    }

    func testEmbeddedCPUAwkProgramProducesOverallAndCoreMetrics() throws {
        let command = SSHMonitoringService.remoteCommand
        let marker = "cpu_metrics=$(awk \""
        let suffix = "\" \"$cpu_a\" \"$cpu_b\")"
        guard let start = command.range(of: marker),
              let end = command.range(
                of: suffix,
                range: start.upperBound..<command.endIndex
              ) else {
            return XCTFail("CPU awk collector was not found")
        }
        let escapedProgram = String(command[start.upperBound..<end.lowerBound])
        let program = escapedProgram
            .replacingOccurrences(of: "\\$", with: "$")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first")
        let second = directory.appendingPathComponent("second")
        try """
        cpu 100 20 30 1000 5 1 2 0 0 0
        cpu0 50 10 15 500 2 1 1 0 0 0
        """.write(to: first, atomically: true, encoding: .utf8)
        try """
        cpu 130 22 45 1060 7 2 4 1 0 0
        cpu0 65 11 22 530 3 2 2 1 0 0
        """.write(to: second, atomically: true, encoding: .utf8)

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/awk")
        process.arguments = [program, first.path, second.path]
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        let output = String(
            decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        let error = String(
            decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )

        XCTAssertEqual(process.terminationStatus, 0, error)
        XCTAssertTrue(output.contains("cpu="), output)
        XCTAssertTrue(output.contains("core=0|"), output)
    }
}
