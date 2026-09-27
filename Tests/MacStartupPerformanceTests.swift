import Foundation
import SwiftData
import XCTest
@testable import ServerDash

@MainActor
final class MacStartupPerformanceTests: XCTestCase {
    func testHistoryHydrationQueuePrioritizesAndRotatesFailedReads() {
        let background = (0..<4).map { _ in UUID() }
        let visible = UUID()
        let selected = UUID()
        var queue = HistoryHydrationQueue()

        queue.enqueue(
            serverIDs: background + [visible, selected],
            priority: .background
        )
        queue.enqueue(serverIDs: [visible], priority: .visible)
        queue.enqueue(serverIDs: [selected], priority: .selected)

        let first = queue.nextBatch(limit: 3)
        XCTAssertEqual(first, [selected, visible, background[0]])

        queue.complete(first, succeeded: false)
        XCTAssertTrue(queue.hydrated.isEmpty)
        XCTAssertTrue(queue.hasPending)
        let unaffected = queue.nextBatch(limit: 3)
        XCTAssertEqual(unaffected, Array(background.dropFirst()))
        queue.complete(unaffected, succeeded: true)

        // Failed batches retry individually and rotate after another failure,
        // so one unreadable selected host cannot starve its batch companions.
        XCTAssertEqual(queue.nextBatch(limit: 3), [selected])
        queue.complete([selected], succeeded: false)
        XCTAssertEqual(queue.nextBatch(limit: 3), [visible])
        queue.complete([visible], succeeded: true)
        XCTAssertEqual(queue.nextBatch(limit: 3), [background[0]])
        queue.complete([background[0]], succeeded: true)
        XCTAssertEqual(queue.nextBatch(limit: 3), [selected])
    }

    func testBootstrapBatchLoadsRoutesAndAdvancedWithoutReplacingRuntime() throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let context = container.mainContext
        let servers = try makeServers(count: 3, context: context)
        try context.save()

        let app = AppState(
            trustCoordinator: HostTrustCoordinator(),
            fileServicesEnabled: false
        )
        app.bootstrap(servers: servers, context: context)
        let runtime = app.runtime(for: servers[1])

        XCTAssertEqual(app.configs.count, servers.count)
        XCTAssertEqual(app.configs[servers[1].id]?.route?.name, "Route 1")
        XCTAssertEqual(
            app.configs[servers[1].id]?.advancedSettings?.keepAliveInterval,
            31
        )

        app.bootstrap(servers: servers, context: context)
        XCTAssertTrue(app.runtime(for: servers[1]) === runtime)
        XCTAssertEqual(app.configs[servers[1].id]?.route?.name, "Route 1")
    }

    func testBootstrapRetriesStartupGapAfterTransientSaveFailure() throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let context = container.mainContext
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = ManualMonitoringClock(now: now)
        let server = ServerRecord(
            name: "Gap Retry Host",
            host: "192.0.2.11",
            username: "operator",
            enableDashboardMonitor: false
        )
        server.lastSuccessfulMonitorAt = now.addingTimeInterval(-120)
        context.insert(server)
        try context.save()

        let historyContext = ModelContext(container)
        historyContext.autosaveEnabled = false
        let repository = MonitoringHistoryRepository(
            context: historyContext,
            clock: clock
        )
        repository.beforeSave = { throw CocoaError(.fileWriteNoPermission) }
        let app = AppState(
            trustCoordinator: HostTrustCoordinator(),
            monitoringClock: clock,
            fileServicesEnabled: false,
            monitoringHistoryService: MacMonitoringHistoryService(
                repository: repository,
                clock: clock
            )
        )

        app.bootstrap(servers: [server], context: context)
        XCTAssertEqual(
            try historyContext.fetchCount(FetchDescriptor<MonitoringGapRecord>()),
            0
        )

        repository.beforeSave = nil
        app.bootstrap(servers: [server], context: context)
        XCTAssertEqual(
            try historyContext.fetchCount(FetchDescriptor<MonitoringGapRecord>()),
            1
        )
        app.bootstrap(servers: [server], context: context)
        XCTAssertEqual(
            try historyContext.fetchCount(FetchDescriptor<MonitoringGapRecord>()),
            1
        )
    }

    func testAsyncHistoryHydrationMergesFreshSampleAndKeepsRuntimeIdentity() async throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let context = container.mainContext
        let server = ServerRecord(
            name: "History Host",
            host: "192.0.2.10",
            username: "operator",
            enableDashboardMonitor: false
        )
        context.insert(server)
        try context.save()

        let historyContext = ModelContext(container)
        historyContext.autosaveEnabled = false
        let repository = MonitoringHistoryRepository(context: historyContext)
        let oldDate = Date().addingTimeInterval(-120)
        var old = ServerSnapshot.empty
        old.capturedAt = oldDate
        old.cpuUsage = 10
        try repository.recordSnapshot(old, serverID: server.id)

        let service = MacMonitoringHistoryService(repository: repository)
        let app = AppState(
            trustCoordinator: HostTrustCoordinator(),
            fileServicesEnabled: false,
            monitoringHistoryService: service
        )
        app.bootstrap(servers: [server], context: context)
        let runtime = app.runtime(for: server)

        let freshDate = Date()
        var fresh = ServerSnapshot.empty
        fresh.capturedAt = freshDate
        fresh.cpuUsage = 90
        app.applyValidatedSnapshot(fresh, to: server)

        await app.waitForHistoryHydration()

        XCTAssertTrue(app.runtime(for: server) === runtime)
        XCTAssertEqual(runtime.renderState.history.map(\.date), [oldDate, freshDate])
        XCTAssertEqual(runtime.renderState.history.last?.cpu, 90)
    }

    func testShutdownBoundaryRejectsLateMonitoringHistoryWrites() throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let context = container.mainContext
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = ManualMonitoringClock(now: now)
        let server = ServerRecord(
            name: "Shutdown Host",
            host: "192.0.2.12",
            username: "operator",
            enableDashboardMonitor: false
        )
        context.insert(server)
        try context.save()

        let historyContext = ModelContext(container)
        historyContext.autosaveEnabled = false
        let repository = MonitoringHistoryRepository(
            context: historyContext,
            clock: clock
        )
        let app = AppState(
            trustCoordinator: HostTrustCoordinator(),
            monitoringClock: clock,
            fileServicesEnabled: false,
            monitoringHistoryService: MacMonitoringHistoryService(
                repository: repository,
                clock: clock
            )
        )
        app.bootstrap(servers: [server], context: context)

        XCTAssertTrue(app.beginShutdownStateTransition())
        // Production beginShutdown intentionally writes this after entering the
        // boundary. Late callbacks must preserve, rather than close, that gap.
        try repository.beginLifecycleGap(
            .collectorStopped,
            serverIDs: [server.id],
            at: now
        )
        let gapsBefore = try historyContext.fetch(
            FetchDescriptor<MonitoringGapRecord>()
        )
        XCTAssertEqual(gapsBefore.count, 1)
        XCTAssertEqual(gapsBefore.first?.reason, .collectorStopped)
        XCTAssertNil(gapsBefore.first?.endedAt)
        XCTAssertEqual(
            try historyContext.fetchCount(FetchDescriptor<MonitoringSampleRecord>()),
            0
        )

        app.setMonitoringNetworkAvailable(false)
        app.setMonitoringNetworkAvailable(true)
        app.setMonitoringSleeping(true)
        app.setMonitoringSleeping(false)
        var snapshot = ServerSnapshot.empty
        snapshot.capturedAt = now.addingTimeInterval(60)
        snapshot.cpuUsage = 42
        app.applyValidatedSnapshot(snapshot, to: server)

        let gapsAfter = try historyContext.fetch(
            FetchDescriptor<MonitoringGapRecord>()
        )
        XCTAssertEqual(gapsAfter.map(\.id), gapsBefore.map(\.id))
        XCTAssertEqual(gapsAfter.map(\.reason), [.collectorStopped])
        XCTAssertNil(gapsAfter.first?.endedAt)
        XCTAssertEqual(
            try historyContext.fetchCount(FetchDescriptor<MonitoringSampleRecord>()),
            0
        )
        XCTAssertTrue(app.history(for: server).isEmpty)
        XCTAssertNil(server.lastSuccessfulMonitorAt)
        XCTAssertFalse(app.beginShutdownStateTransition())
    }

    func testHundredAndThousandHostBootstrapBenchmark() throws {
        var reports: [[String: Any]] = []

        for hostCount in [100, 1_000] {
            let container = try PersistenceController.makeInMemoryContainer()
            let context = container.mainContext
            let servers = try makeServers(count: hostCount, context: context)
            try context.save()

            let clock = ManualMonitoringClock(
                now: Date(timeIntervalSince1970: 1_800_000_000)
            )
            let legacyRepository = MonitoringHistoryRepository(
                context: context,
                clock: clock
            )
            let batchedHistoryContext = ModelContext(container)
            batchedHistoryContext.autosaveEnabled = false
            let batchedRepository = MonitoringHistoryRepository(
                context: batchedHistoryContext,
                clock: clock
            )

            let queryComparison = benchmarkPair(warmups: 3, iterations: 10) {
                self.legacyPerHostStartupQuerySubsteps(
                    servers: servers,
                    context: context,
                    repository: legacyRepository,
                    clock: clock
                )
            } second: {
                self.batchedStartupQuerySubsteps(
                    servers: servers,
                    context: context,
                    repository: batchedRepository,
                    clock: clock
                )
            }
            let expectedQueryChecksum = hostCount * 4 * 10
            XCTAssertEqual(queryComparison.first.checksum, expectedQueryChecksum)
            XCTAssertEqual(queryComparison.second.checksum, expectedQueryChecksum)

            let bootstrap = benchmarkWithSetup(warmups: 3, iterations: 10) {
                AppState(
                    trustCoordinator: HostTrustCoordinator(),
                    monitoringClock: clock,
                    fileServicesEnabled: false
                )
            } operation: { app in
                app.bootstrap(servers: servers, context: context)
                return app.configs.count
            }
            XCTAssertEqual(bootstrap.checksum, hostCount * 10)

            let buildConfiguration: String
            #if DEBUG
            buildConfiguration = "Debug"
            #else
            buildConfiguration = "Release"
            #endif
            reports.append([
                "hosts": hostCount,
                "routes": hostCount,
                "advancedSettings": hostCount,
                "warmups": 3,
                "iterations": 10,
                "mainThread": Thread.isMainThread,
                "processIdentifier": ProcessInfo.processInfo.processIdentifier,
                "buildConfiguration": buildConfiguration,
                "baselineCommit": "e4d6b84e8561be3fe0688bb38fb9685654e5ffa3",
                "legacyPerHostQuerySubsteps": [
                    "medianMilliseconds": queryComparison.first.median,
                    "p95Milliseconds": queryComparison.first.p95,
                    "checksum": queryComparison.first.checksum
                ],
                "batchedQuerySubsteps": [
                    "medianMilliseconds": queryComparison.second.median,
                    "p95Milliseconds": queryComparison.second.p95,
                    "checksum": queryComparison.second.checksum
                ],
                "currentAppStateBootstrapMethod": [
                    "medianMilliseconds": bootstrap.median,
                    "p95Milliseconds": bootstrap.p95,
                    "checksum": bootstrap.checksum
                ],
                "querySubstepsMedianSpeedup": queryComparison.first.median
                    / max(queryComparison.second.median, Double.leastNonzeroMagnitude),
                "bootstrapMedianMilliseconds": bootstrap.median,
                "bootstrapP95Milliseconds": bootstrap.p95,
                "queryComparisonScope": "Same-process algorithm replay over the same in-memory fixture. Legacy performs one route fetch, one advanced-settings fetch, and one startup-gap reconciliation per host. Batched performs one all-route fetch, one all-advanced-settings fetch, and one all-host startup-gap reconciliation.",
                "queryComparisonExcluded": "The historical baseline's synchronous recentMetricPoints read and runtime creation are excluded from this query-substep pair; it isolates only route, advanced-settings, and startup-gap work.",
                "bootstrapMethodScope": "Times only AppState.bootstrap after AppState construction. Includes monitoring-history service creation, batched connection catalog reads, runtime/config creation, startup-gap reconciliation, hydration queue scheduling, and monitoring schedule synchronization.",
                "excluded": "Fixture insertion, AppState initialization, deferred history reads after the first MainActor yield, SwiftUI launch, and first-frame rendering are excluded. This is not full application startup.",
                "fixtureHistory": "No samples and nil lastSuccessfulMonitorAt; startup-gap paths perform reads without inserting gaps.",
                "releaseInvocation": "Scripts/benchmark-macos.sh compiles and runs this comparison in Release with -O."
            ])
        }

        let data = try JSONSerialization.data(
            withJSONObject: [
                "measurements": reports,
                "testHostResourceUsage": MacPerformanceResourceMetrics.cumulativeTestHostSnapshot()
            ],
            options: [.prettyPrinted, .sortedKeys]
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("serverdash-startup-benchmark.json")
        try data.write(to: url, options: .atomic)
        print("MAC_STARTUP_PERFORMANCE \(String(decoding: data, as: UTF8.self)); report=\(url.path)")
    }

    /// Replays the query-bearing startup substeps from e4d6b84. It intentionally
    /// excludes runtime creation and the old synchronous per-host history load.
    private func legacyPerHostStartupQuerySubsteps(
        servers: [ServerRecord],
        context: ModelContext,
        repository: MonitoringHistoryRepository,
        clock: any MonitoringClock
    ) -> Int {
        var checksum = 0
        for server in servers {
            var config = server.connectionConfig
            let serverID = server.id
            do {
                let routes = try context.fetch(
                    FetchDescriptor<ConnectionRouteRecord>(
                        predicate: #Predicate { $0.serverID == serverID }
                    )
                )
                config.route = ConnectionConfigResolver.persistedRoute(
                    for: serverID,
                    routes: routes
                )
            } catch {
                config.route = nil
            }
            if let advanced = try? context.fetch(
                FetchDescriptor<SSHAdvancedSettingsRecord>(
                    predicate: #Predicate { $0.serverID == serverID }
                )
            ).first {
                config.advancedSettings = advanced.settings
                config.connectTimeout = TimeInterval(advanced.settings.connectTimeout)
            }
            checksum &+= 1
            if config.route != nil { checksum &+= 1 }
            if config.advancedSettings != nil { checksum &+= 1 }
        }
        for server in servers {
            do {
                try repository.reconcileStartupGap(
                    serverID: server.id,
                    lastSuccessfulAt: server.lastSuccessfulMonitorAt,
                    refreshInterval: 30,
                    at: clock.now()
                )
            } catch {
                // Matches the old bootstrap's per-host fail-and-continue behavior.
            }
            checksum &+= 1
        }
        return checksum
    }

    /// Replays the current query-bearing startup substeps without counting
    /// runtime/config object construction that belongs to AppState.bootstrap.
    private func batchedStartupQuerySubsteps(
        servers: [ServerRecord],
        context: ModelContext,
        repository: MonitoringHistoryRepository,
        clock: any MonitoringClock
    ) -> Int {
        let routesByServerID: [UUID: [ConnectionRouteRecord]]?
        do {
            var grouped: [UUID: [ConnectionRouteRecord]] = [:]
            for record in try context.fetch(FetchDescriptor<ConnectionRouteRecord>()) {
                guard let serverID = record.serverID else { continue }
                grouped[serverID, default: []].append(record)
            }
            routesByServerID = grouped
        } catch {
            routesByServerID = nil
        }
        let advancedByServerID: [UUID: SSHAdvancedSettingsDraft]
        do {
            advancedByServerID = Dictionary(
                try context.fetch(FetchDescriptor<SSHAdvancedSettingsRecord>()).map {
                    ($0.serverID, $0.settings)
                },
                uniquingKeysWith: { first, _ in first }
            )
        } catch {
            advancedByServerID = [:]
        }

        var checksum = 0
        for server in servers {
            var config = server.connectionConfig
            if let routesByServerID {
                config.route = ConnectionConfigResolver.persistedRoute(
                    for: server.id,
                    routes: routesByServerID[server.id] ?? []
                )
            } else {
                config.route = nil
            }
            if let advanced = advancedByServerID[server.id] {
                config.advancedSettings = advanced
                config.connectTimeout = TimeInterval(advanced.connectTimeout)
            }
            checksum &+= 1
            if config.route != nil { checksum &+= 1 }
            if config.advancedSettings != nil { checksum &+= 1 }
        }

        let gapRequests = servers.map {
            MonitoringStartupGapRequest(
                serverID: $0.id,
                lastSuccessfulAt: $0.lastSuccessfulMonitorAt,
                refreshInterval: 30
            )
        }
        do {
            try repository.reconcileStartupGaps(gapRequests, at: clock.now())
        } catch {
            // Matches current bootstrap's fail-and-continue behavior for the batch.
        }
        checksum &+= gapRequests.count
        return checksum
    }

    private func makeServers(
        count: Int,
        context: ModelContext
    ) throws -> [ServerRecord] {
        try (0..<count).map { index in
            let server = ServerRecord(
                name: "Host \(index)",
                host: "192.0.2.\(index % 240 + 1)",
                username: "operator\(index % 10)",
                enableDashboardMonitor: false
            )
            context.insert(server)
            context.insert(
                try ConnectionRouteRecord(
                    route: ConnectionRoute(name: "Route \(index)"),
                    serverID: server.id
                )
            )
            var advanced = SSHAdvancedSettingsDraft.default
            advanced.keepAliveInterval = 30 + index % 10
            advanced.connectTimeout = 60 + index % 30
            context.insert(
                SSHAdvancedSettingsRecord(
                    serverID: server.id,
                    settings: advanced
                )
            )
            return server
        }
    }

    private func benchmarkPair(
        warmups: Int,
        iterations: Int,
        first: () -> Int,
        second: () -> Int
    ) -> (
        first: (median: Double, p95: Double, checksum: Int),
        second: (median: Double, p95: Double, checksum: Int)
    ) {
        for _ in 0..<warmups {
            _ = first()
            _ = second()
        }
        var firstDurations: [Double] = []
        var secondDurations: [Double] = []
        var firstChecksum = 0
        var secondChecksum = 0
        firstDurations.reserveCapacity(iterations)
        secondDurations.reserveCapacity(iterations)

        func measure(
            _ operation: () -> Int,
            durations: inout [Double],
            checksum: inout Int
        ) {
            let started = ProcessInfo.processInfo.systemUptime
            checksum &+= operation()
            durations.append(
                (ProcessInfo.processInfo.systemUptime - started) * 1_000
            )
        }

        for iteration in 0..<iterations {
            if iteration.isMultiple(of: 2) {
                measure(first, durations: &firstDurations, checksum: &firstChecksum)
                measure(second, durations: &secondDurations, checksum: &secondChecksum)
            } else {
                measure(second, durations: &secondDurations, checksum: &secondChecksum)
                measure(first, durations: &firstDurations, checksum: &firstChecksum)
            }
        }
        let firstStats = statistics(firstDurations, checksum: firstChecksum)
        let secondStats = statistics(secondDurations, checksum: secondChecksum)
        return (firstStats, secondStats)
    }

    private func benchmarkWithSetup<Value>(
        warmups: Int,
        iterations: Int,
        setup: () -> Value,
        operation: (Value) -> Int
    ) -> (median: Double, p95: Double, checksum: Int) {
        for _ in 0..<warmups {
            let value = setup()
            _ = operation(value)
        }
        var durations: [Double] = []
        var checksum = 0
        durations.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let value = setup()
            let started = ProcessInfo.processInfo.systemUptime
            checksum &+= operation(value)
            durations.append(
                (ProcessInfo.processInfo.systemUptime - started) * 1_000
            )
        }
        return statistics(durations, checksum: checksum)
    }

    private func statistics(
        _ durations: [Double],
        checksum: Int
    ) -> (median: Double, p95: Double, checksum: Int) {
        let sorted = durations.sorted()
        let median = sorted[sorted.count / 2]
        let p95Index = min(
            sorted.count - 1,
            max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        )
        return (median, sorted[p95Index], checksum)
    }
}
