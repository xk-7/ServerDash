import Foundation
import SwiftData
import XCTest
@testable import ServerDash

@MainActor
final class MonitoringHistoryTests: XCTestCase {
    func testSamplePersistsCollectorQualitySourceAgeAndMetricNames() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let clock = ManualMonitoringClock(now: now)
        let container = try PersistenceController.makeInMemoryContainer()
        let context = ModelContext(container)
        let repository = MonitoringHistoryRepository(context: context, clock: clock)
        let serverID = UUID()
        let capturedAt = now.addingTimeInterval(-7)

        try repository.recordSnapshot(
            snapshot(at: capturedAt, cpu: 42, memory: 64),
            serverID: serverID
        )

        let samples = try context.fetch(FetchDescriptor<MonitoringSampleRecord>())
        let sample = try XCTUnwrap(samples.first)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(sample.serverID, serverID)
        XCTAssertEqual(sample.collectorID, MonitoringHistoryRepository.collectorID)
        XCTAssertEqual(sample.collectorVersion, MonitoringHistoryRepository.collectorVersion)
        XCTAssertEqual(sample.quality, .normal)
        XCTAssertEqual(sample.sourceDataAge, 7, accuracy: 0.001)
        XCTAssertEqual(sample.metricValues[MonitoringMetric.cpuUsage.rawValue], 42)
        XCTAssertEqual(sample.metricValues[MonitoringMetric.memoryUsage.rawValue], 64)
        XCTAssertEqual(sample.metricValues.count, MonitoringMetric.allCases.count)
    }

    func testFailureReasonsRemainStructuredAndDistinct() {
        XCTAssertEqual(MonitoringGapReason.classify(ConnectionError.timeout), .timeout)
        XCTAssertEqual(
            MonitoringGapReason.classify(ConnectionError.networkUnreachable),
            .unreachable
        )
        XCTAssertEqual(
            MonitoringGapReason.classify(ConnectionError.authenticationFailed),
            .authenticationFailed
        )
        XCTAssertEqual(
            MonitoringGapReason.classify(
                ConnectionError.hostKeyChanged(oldFingerprint: nil, newFingerprint: nil)
            ),
            .fingerprintChanged
        )
        XCTAssertEqual(
            MonitoringGapReason.classify(ConnectionError.incompatibleMonitor("")),
            .unsupported
        )
        XCTAssertEqual(
            MonitoringGapReason.classify(ConnectionError.cancelled),
            .collectorStopped
        )
    }

    func testSleepGapBreaksChartAndDoesNotBecomeServerFailure() throws {
        let start = Date(timeIntervalSince1970: 20_000)
        let clock = ManualMonitoringClock(now: start)
        let container = try PersistenceController.makeInMemoryContainer()
        let context = ModelContext(container)
        let repository = MonitoringHistoryRepository(context: context, clock: clock)
        let serverID = UUID()

        try repository.recordSnapshot(snapshot(at: start, cpu: 10), serverID: serverID)
        clock.advance(by: 10)
        try repository.beginLifecycleGap(.sleeping, serverIDs: [serverID])
        clock.advance(by: 600)
        try repository.endLifecycleGap(.sleeping, serverIDs: [serverID])
        clock.advance(by: 5)
        try repository.recordSnapshot(snapshot(at: clock.now(), cpu: 20), serverID: serverID)

        let series = try repository.query(
            serverID: serverID,
            metric: .cpuUsage,
            from: start.addingTimeInterval(-1),
            to: clock.now().addingTimeInterval(1),
            pixelWidth: 1
        )
        XCTAssertEqual(series.gaps.map(\.reason), [.sleeping])
        XCTAssertTrue(series.gaps[0].isCollectorSide)
        XCTAssertEqual(series.points.count, 2)
        XCTAssertEqual(series.segments.count, 2)
        XCTAssertEqual(series.segments.map(\.count), [1, 1])
    }

    func testOverlappingSleepAndNetworkGapsCloseIndependently() throws {
        let start = Date(timeIntervalSince1970: 25_000)
        let clock = ManualMonitoringClock(now: start)
        let container = try PersistenceController.makeInMemoryContainer()
        let context = ModelContext(container)
        let repository = MonitoringHistoryRepository(context: context, clock: clock)
        let serverID = UUID()

        try repository.beginLifecycleGap(.sleeping, serverIDs: [serverID])
        clock.advance(by: 10)
        try repository.beginLifecycleGap(.networkInterrupted, serverIDs: [serverID])
        clock.advance(by: 10)
        try repository.endLifecycleGap(.sleeping, serverIDs: [serverID])

        var gaps = try context.fetch(FetchDescriptor<MonitoringGapRecord>())
        XCTAssertNotNil(gaps.first(where: { $0.reason == .sleeping })?.endedAt)
        XCTAssertNil(gaps.first(where: { $0.reason == .networkInterrupted })?.endedAt)

        clock.advance(by: 10)
        try repository.endLifecycleGap(.networkInterrupted, serverIDs: [serverID])
        gaps = try context.fetch(FetchDescriptor<MonitoringGapRecord>())
        XCTAssertTrue(gaps.allSatisfy { $0.endedAt != nil })
    }

    func testStartupReconciliationCreatesClosedCollectorStoppedGap() throws {
        let now = Date(timeIntervalSince1970: 28_000)
        let clock = ManualMonitoringClock(now: now)
        let container = try PersistenceController.makeInMemoryContainer()
        let context = ModelContext(container)
        let repository = MonitoringHistoryRepository(context: context, clock: clock)
        let serverID = UUID()

        try repository.reconcileStartupGap(
            serverID: serverID,
            lastSuccessfulAt: now.addingTimeInterval(-120),
            refreshInterval: 5,
            at: now
        )

        let gaps = try context.fetch(FetchDescriptor<MonitoringGapRecord>())
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps[0].reason, .collectorStopped)
        XCTAssertEqual(gaps[0].startedAt, now.addingTimeInterval(-115))
        XCTAssertEqual(gaps[0].endedAt, now)
    }

    func testAggregationPreservesMinMaxAverageLastAndSampleCount() throws {
        let start = Date(timeIntervalSince1970: 30_000)
        let clock = ManualMonitoringClock(now: start.addingTimeInterval(3_600))
        let container = try PersistenceController.makeInMemoryContainer()
        let context = ModelContext(container)
        let repository = MonitoringHistoryRepository(context: context, clock: clock)
        let serverID = UUID()

        for (offset, cpu) in [(0.0, 10.0), (5, 30), (10, 20)] {
            context.insert(
                try MonitoringSampleRecord(
                    serverID: serverID,
                    capturedAt: start.addingTimeInterval(offset),
                    collectorID: "fixture",
                    collectorVersion: "1",
                    quality: .normal,
                    sourceDataAge: 2,
                    metricValues: [MonitoringMetric.cpuUsage.rawValue: cpu]
                )
            )
        }
        try context.save()

        _ = try repository.performMaintenance(
            policy: MonitoringRetentionPolicy(
                rawRetention: 7_200,
                minuteRetention: 7_200,
                quarterHourRetention: 7_200,
                diskQuotaBytes: 10_000_000
            ),
            now: start.addingTimeInterval(3_600)
        )

        let minute = MonitoringResolution.minute.rawValue
        let aggregates = try context.fetch(
            FetchDescriptor<MonitoringAggregateRecord>(
                predicate: #Predicate { $0.resolutionSeconds == minute }
            )
        )
        let statistics = try XCTUnwrap(
            aggregates.first?.statistics[MonitoringMetric.cpuUsage.rawValue]
        )
        XCTAssertEqual(statistics.minimum, 10)
        XCTAssertEqual(statistics.maximum, 30)
        XCTAssertEqual(statistics.average, 20, accuracy: 0.001)
        XCTAssertEqual(statistics.last, 20)
        XCTAssertEqual(statistics.sampleCount, 3)
    }

    func testRetentionAndDiskQuotaRemoveOldestFramesButKeepActiveGap() throws {
        let now = Date(timeIntervalSince1970: 100_000)
        let clock = ManualMonitoringClock(now: now)
        let container = try PersistenceController.makeInMemoryContainer()
        let context = ModelContext(container)
        let repository = MonitoringHistoryRepository(context: context, clock: clock)
        let serverID = UUID()

        for index in 0..<20 {
            context.insert(
                try MonitoringSampleRecord(
                    serverID: serverID,
                    capturedAt: now.addingTimeInterval(TimeInterval(-10_000 + index * 5)),
                    collectorID: "fixture",
                    collectorVersion: "1",
                    quality: .normal,
                    sourceDataAge: 0,
                    metricValues: [MonitoringMetric.cpuUsage.rawValue: Double(index)]
                )
            )
        }
        context.insert(
            MonitoringGapRecord(
                serverID: serverID,
                startedAt: now.addingTimeInterval(-20_000),
                reason: .collectorStopped,
                collectorID: "fixture",
                collectorVersion: "1"
            )
        )
        try context.save()

        let report = try repository.performMaintenance(
            policy: MonitoringRetentionPolicy(
                rawRetention: 60,
                minuteRetention: 120,
                quarterHourRetention: 600,
                diskQuotaBytes: 2_048
            ),
            now: now
        )
        XCTAssertGreaterThan(report.rawSamplesRemoved, 0)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<MonitoringSampleRecord>()).count,
            0
        )
        let gaps = try context.fetch(FetchDescriptor<MonitoringGapRecord>())
        XCTAssertEqual(gaps.count, 1)
        XCTAssertNil(gaps[0].endedAt)
    }

    func testPixelDownsamplingIsBoundedAndPreservesExtrema() {
        let start = Date(timeIntervalSince1970: 0)
        var points: [MonitoringHistoryPoint] = []
        points.reserveCapacity(1_000)
        for index in 0..<1_000 {
            let point = MonitoringHistoryPoint(
                id: String(index),
                date: start.addingTimeInterval(TimeInterval(index)),
                minimum: Double(index),
                maximum: Double(index),
                average: Double(index),
                last: Double(index),
                sampleCount: 1
            )
            points.append(point)
        }
        let result = MonitoringHistoryRepository.downsample(
            points,
            from: start,
            to: start.addingTimeInterval(1_000),
            pixelWidth: 100
        )
        XCTAssertLessThanOrEqual(result.count, 100)
        XCTAssertEqual(result.first?.minimum, 0)
        XCTAssertEqual(result.last?.maximum, 999)
        XCTAssertEqual(result.reduce(0) { $0 + $1.sampleCount }, 1_000)
    }

    func testOneTenAndFiftyServerFixturesKeepOneCompactFramePerCollection() throws {
        let now = Date(timeIntervalSince1970: 200_000)
        for serverCount in [1, 10, 50] {
            let container = try PersistenceController.makeInMemoryContainer()
            let context = ModelContext(container)
            let serverIDs = (0..<serverCount).map { _ in UUID() }

            for serverID in serverIDs {
                for sampleIndex in 0..<12 {
                    context.insert(
                        try MonitoringSampleRecord(
                            serverID: serverID,
                            capturedAt: now.addingTimeInterval(TimeInterval(sampleIndex * 5)),
                            collectorID: "fixture",
                            collectorVersion: "1",
                            quality: .normal,
                            sourceDataAge: 0,
                            metricValues: Dictionary(
                                uniqueKeysWithValues: MonitoringMetric.allCases.map {
                                    ($0.rawValue, Double(sampleIndex))
                                }
                            )
                        )
                    )
                }
            }
            try context.save()

            let samples = try context.fetch(FetchDescriptor<MonitoringSampleRecord>())
            XCTAssertEqual(samples.count, serverCount * 12)
            XCTAssertTrue(samples.allSatisfy {
                $0.metricValues.count == MonitoringMetric.allCases.count
            })
            let repository = MonitoringHistoryRepository(context: context)
            for serverID in serverIDs {
                let series = try repository.query(
                    serverID: serverID,
                    metric: .cpuUsage,
                    from: now,
                    to: now.addingTimeInterval(60),
                    pixelWidth: 120
                )
                XCTAssertEqual(series.points.count, 12)
            }
        }
    }

    func testFiftyServerFixtureWithTenPercentTimeoutsCreatesFiveTypedGaps() throws {
        let now = Date(timeIntervalSince1970: 250_000)
        let clock = ManualMonitoringClock(now: now)
        let container = try PersistenceController.makeInMemoryContainer()
        let context = ModelContext(container)
        let repository = MonitoringHistoryRepository(context: context, clock: clock)
        let serverIDs = (0..<50).map { _ in UUID() }

        for (index, serverID) in serverIDs.enumerated() {
            if index.isMultiple(of: 10) {
                try repository.recordFailure(
                    ConnectionError.timeout,
                    serverID: serverID,
                    at: now
                )
            } else {
                try repository.recordSnapshot(
                    snapshot(at: now, cpu: Double(index)),
                    serverID: serverID
                )
            }
        }

        let samples = try context.fetch(FetchDescriptor<MonitoringSampleRecord>())
        let gaps = try context.fetch(FetchDescriptor<MonitoringGapRecord>())
        XCTAssertEqual(samples.count, 45)
        XCTAssertEqual(gaps.count, 5)
        XCTAssertTrue(gaps.allSatisfy { $0.reason == .timeout })
    }

    func testTwentyFourHourAndThirtyDayQueriesStayPixelBounded() throws {
        let end = Date(timeIntervalSince1970: 5_000_000)
        let container = try PersistenceController.makeInMemoryContainer()
        let context = ModelContext(container)
        let repository = MonitoringHistoryRepository(context: context)
        let serverID = UUID()
        let statistics = [
            MonitoringMetric.cpuUsage.rawValue: MonitoringAggregateStatistics(
                minimum: 10,
                maximum: 90,
                average: 50,
                last: 60,
                sampleCount: 12
            )
        ]

        for index in 0..<1_440 {
            let start = end.addingTimeInterval(TimeInterval(-(1_440 - index) * 60))
            context.insert(
                try MonitoringAggregateRecord(
                    serverID: serverID,
                    bucketStart: start,
                    bucketEnd: start.addingTimeInterval(59),
                    resolution: .minute,
                    collectorID: "fixture",
                    collectorVersion: "1",
                    maximumSourceDataAge: 1,
                    statistics: statistics
                )
            )
        }
        for index in 0..<2_880 {
            let start = end.addingTimeInterval(TimeInterval(-(2_880 - index) * 900))
            context.insert(
                try MonitoringAggregateRecord(
                    serverID: serverID,
                    bucketStart: start,
                    bucketEnd: start.addingTimeInterval(899),
                    resolution: .quarterHour,
                    collectorID: "fixture",
                    collectorVersion: "1",
                    maximumSourceDataAge: 1,
                    statistics: statistics
                )
            )
        }
        try context.save()

        let day = try repository.query(
            serverID: serverID,
            metric: .cpuUsage,
            from: end.addingTimeInterval(-24 * 60 * 60),
            to: end,
            pixelWidth: 600
        )
        let month = try repository.query(
            serverID: serverID,
            metric: .cpuUsage,
            from: end.addingTimeInterval(-30 * 24 * 60 * 60),
            to: end,
            pixelWidth: 600
        )

        XCTAssertEqual(day.resolution, .minute)
        XCTAssertEqual(month.resolution, .quarterHour)
        XCTAssertLessThanOrEqual(day.points.count, 600)
        XCTAssertLessThanOrEqual(month.points.count, 600)
    }

    func testSchemaMigrationFixturePreservesExistingServerAndAddsHistoryEntities() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerDash-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("fixture.store")
        let serverID = UUID()

        do {
            let v1Schema = Schema(versionedSchema: PersistenceSchemaV1.self)
            let configuration = ModelConfiguration(
                "FixtureV1",
                schema: v1Schema,
                url: storeURL,
                allowsSave: true,
                cloudKitDatabase: .none
            )
            let v1 = try ModelContainer(for: v1Schema, configurations: [configuration])
            let context = ModelContext(v1)
            context.insert(
                ServerRecord(
                    id: serverID,
                    name: "Migration fixture",
                    host: "fixture.invalid",
                    username: "fixture",
                    notes: "preserve-user-field"
                )
            )
            try context.save()
        }

        let v2Schema = Schema(versionedSchema: PersistenceSchemaV2.self)
        let configuration = ModelConfiguration(
            "FixtureV2",
            schema: v2Schema,
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let v2 = try ModelContainer(
            for: v2Schema,
            migrationPlan: ServerDashMigrationPlan.self,
            configurations: [configuration]
        )
        let context = ModelContext(v2)
        let servers = try context.fetch(FetchDescriptor<ServerRecord>())
        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers[0].id, serverID)
        XCTAssertEqual(servers[0].notes, "preserve-user-field")
        XCTAssertEqual(try context.fetch(FetchDescriptor<MonitoringSampleRecord>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<MonitoringGapRecord>()).count, 0)
    }

    func testPersistenceScopeNeverDiscoversSiblingStore() {
        let root = URL(fileURLWithPath: "/tmp/ServerDash-scope-fixture", isDirectory: true)
        let sentinel = root.appendingPathComponent("sentinel.store")
        let scoped = PersistenceController.scopedStoreFileURLs(applicationSupportRoot: root)
        XCTAssertFalse(scoped.contains(sentinel))
        XCTAssertEqual(
            scoped.first,
            root.appendingPathComponent("ServerDash/Data/default.store")
        )
        XCTAssertFalse(
            PersistenceController.legacyStoreURLs(applicationSupportRoot: root).contains(sentinel)
        )
    }

    private func snapshot(
        at date: Date,
        cpu: Double,
        memory: Double = 50
    ) -> ServerSnapshot {
        var value = ServerSnapshot.empty
        value.capturedAt = date
        value.cpuUsage = cpu
        value.memoryUsedBytes = memory
        value.memoryTotalBytes = 100
        value.swapUsedBytes = 5
        value.swapTotalBytes = 100
        value.diskUsedBytes = 25
        value.diskTotalBytes = 100
        value.load1 = cpu / 10
        value.load5 = cpu / 20
        value.load15 = cpu / 30
        value.downloadBytesPerSecond = cpu * 1_000
        value.uploadBytesPerSecond = cpu * 500
        return value
    }
}

final class MonitoringCoordinatorClockTests: XCTestCase {
    func testDisabledTargetNeverSchedulesCollection() async {
        let clock = ManualMonitoringClock(now: Date(timeIntervalSince1970: 0))
        let probe = ImmediateMonitoringProbe(results: [])
        let coordinator = MonitoringCoordinator(
            clock: clock,
            jitter: { _ in 0 },
            operation: { id in await probe.run(id) }
        )
        await coordinator.configure(
            targets: [MonitoringScheduleTarget(serverID: UUID(), enabled: false)],
            interval: 5
        )
        clock.advance(by: 60)
        await settle()
        let queued = await coordinator.queuedCount
        let starts = await probe.count
        XCTAssertEqual(queued, 0)
        XCTAssertEqual(starts, 0)
        await coordinator.stop()
    }

    func testFailureBackoffUsesInjectedClockWithoutWallClockSleep() async {
        let clock = ManualMonitoringClock(now: Date(timeIntervalSince1970: 0))
        let probe = ImmediateMonitoringProbe(results: [false, true])
        let serverID = UUID()
        let coordinator = MonitoringCoordinator(
            maximumConcurrency: 1,
            clock: clock,
            jitter: { _ in 0 },
            operation: { id in await probe.run(id) }
        )

        await coordinator.configure(
            targets: [MonitoringScheduleTarget(serverID: serverID, enabled: true)],
            interval: 1_000
        )
        await waitUntil { await probe.count == 1 }
        await waitUntil {
            let queued = await coordinator.queuedCount
            return queued == 1 && clock.pendingSleepCount == 1
        }
        clock.advance(by: 4)
        await settle()
        let countBeforeBackoff = await probe.count
        XCTAssertEqual(countBeforeBackoff, 1)
        clock.advance(by: 1)
        await waitUntil { await probe.count == 2 }
        let startedIDs = await probe.ids
        XCTAssertEqual(startedIDs, [serverID, serverID])
        await coordinator.stop()
    }

    func testInjectedJitterExtendsFirstFailureBackoffByAtMostTwentyPercent() async {
        let clock = ManualMonitoringClock(now: Date(timeIntervalSince1970: 0))
        let probe = ImmediateMonitoringProbe(results: [false, true])
        let jitter = LockedJitterProbe()
        let serverID = UUID()
        let coordinator = MonitoringCoordinator(
            maximumConcurrency: 1,
            clock: clock,
            jitter: { range in jitter.value(in: range) },
            operation: { id in await probe.run(id) }
        )

        await coordinator.configure(
            targets: [MonitoringScheduleTarget(serverID: serverID, enabled: true)],
            interval: 1_000
        )
        await waitUntil { await probe.count == 1 }
        await waitUntil {
            let queued = await coordinator.queuedCount
            return queued == 1 && clock.pendingSleepCount == 1
        }
        clock.advance(by: 5)
        await settle()
        let countBeforeJitter = await probe.count
        XCTAssertEqual(countBeforeJitter, 1)
        clock.advance(by: 1)
        await waitUntil { await probe.count == 2 }
        let ranges = jitter.ranges
        XCTAssertEqual(ranges.first, 0...5)
        XCTAssertTrue(ranges.contains(0...1))
        await coordinator.stop()
    }

    func testSleepDropsQueueAndWakeQueuesEachOfFiftyServersOnce() async {
        let clock = ManualMonitoringClock(now: Date(timeIntervalSince1970: 0))
        let probe = ImmediateMonitoringProbe(results: [])
        let serverIDs = (0..<50).map { _ in UUID() }
        let coordinator = MonitoringCoordinator(
            maximumConcurrency: 5,
            clock: clock,
            jitter: { _ in 1 },
            operation: { id in await probe.run(id) }
        )
        await coordinator.configure(
            targets: serverIDs.map { MonitoringScheduleTarget(serverID: $0, enabled: true) },
            interval: 1_000
        )
        let initiallyQueued = await coordinator.queuedCount
        XCTAssertEqual(initiallyQueued, 50)
        await coordinator.setSleeping(true)
        let sleepingQueue = await coordinator.queuedCount
        XCTAssertEqual(sleepingQueue, 0)
        clock.advance(by: 100)
        await settle()
        let startsWhileSleeping = await probe.count
        XCTAssertEqual(startsWhileSleeping, 0)
        await coordinator.setSleeping(false)
        let firstWakeQueue = await coordinator.queuedCount
        XCTAssertEqual(firstWakeQueue, 50)
        await coordinator.setSleeping(false)
        let duplicateWakeQueue = await coordinator.queuedCount
        XCTAssertEqual(duplicateWakeQueue, 50)
        await coordinator.stop()
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("Condition was not met before timeout")
    }

    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }
}

private actor ImmediateMonitoringProbe {
    private var results: [Bool]
    private(set) var ids: [UUID] = []

    init(results: [Bool]) {
        self.results = results
    }

    var count: Int { ids.count }

    func run(_ id: UUID) -> Bool {
        ids.append(id)
        return results.isEmpty ? true : results.removeFirst()
    }
}

private final class LockedJitterProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ClosedRange<TimeInterval>] = []

    func value(in range: ClosedRange<TimeInterval>) -> TimeInterval {
        lock.withLock {
            recorded.append(range)
            return recorded.count == 1 ? range.lowerBound : range.upperBound
        }
    }

    var ranges: [ClosedRange<TimeInterval>] {
        lock.withLock { recorded }
    }
}

final class ManualMonitoringClock: MonitoringClock, @unchecked Sendable {
    private struct Sleeper {
        let deadline: Date
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var current: Date
    private var sleepers: [UUID: Sleeper] = [:]
    private var cancelledSleeperIDs: Set<UUID> = []

    init(now: Date) {
        current = now
    }

    func now() -> Date {
        lock.withLock { current }
    }

    func sleep(for duration: TimeInterval) async throws {
        let id = UUID()
        let deadline = now().addingTimeInterval(max(0, duration))
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let shouldResume = lock.withLock { () -> Bool in
                    if cancelledSleeperIDs.remove(id) != nil || deadline <= current {
                        return true
                    }
                    sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return false
                }
                if shouldResume {
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume()
                    }
                }
            }
        } onCancel: {
            let continuation = self.lock.withLock { () -> CheckedContinuation<Void, Error>? in
                if let sleeper = self.sleepers.removeValue(forKey: id) {
                    return sleeper.continuation
                }
                self.cancelledSleeperIDs.insert(id)
                return nil
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: TimeInterval) {
        let continuations = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            current = current.addingTimeInterval(duration)
            let ready = sleepers.filter { $0.value.deadline <= current }
            for id in ready.keys { sleepers[id] = nil }
            return ready.values.map(\.continuation)
        }
        continuations.forEach { $0.resume() }
    }

    var pendingSleepCount: Int {
        lock.withLock { sleepers.count }
    }
}
