#if os(macOS)
import Foundation
import SwiftData
import XCTest
@testable import ServerDash

@MainActor
final class MacHistoryMaintenanceTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 36_000)

    func testPagesWithIdenticalTimestampsProduceCompleteIdempotentBuckets() async throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let context = ModelContext(container)
        let server = UUID()
        try seed(1_003, server: server, context: context, date: start)
        let repository = MonitoringHistoryRepository(context: context)
        let now = start.addingTimeInterval(3_600)
        let policy = retainedPolicy
        _ = try await repository.performBatchedMaintenance(policy: policy, now: now, batchSize: 17)
        let first = try cpuAggregate(context: context, server: server, resolution: .minute)
        XCTAssertEqual(first.sampleCount, 1_003)
        XCTAssertEqual(first.minimum, 0)
        XCTAssertEqual(first.maximum, 99)
        _ = try await repository.performBatchedMaintenance(policy: policy, now: now, batchSize: 17)
        XCTAssertEqual(try cpuAggregate(context: context, server: server, resolution: .minute), first)
        XCTAssertEqual(try cpuAggregate(context: context, server: server, resolution: .quarterHour).sampleCount, 1_003)
    }

    func testIncompleteMinuteWaitsForFixedCutoff() async throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let context = ModelContext(container)
        let server = UUID()
        try seed(3, server: server, context: context, date: start.addingTimeInterval(20))
        let repository = MonitoringHistoryRepository(context: context)
        _ = try await repository.performBatchedMaintenance(policy: retainedPolicy, now: start.addingTimeInterval(59))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MonitoringAggregateRecord>()), 0)
        _ = try await repository.performBatchedMaintenance(policy: retainedPolicy, now: start.addingTimeInterval(61))
        XCTAssertEqual(try cpuAggregate(context: context, server: server, resolution: .minute).sampleCount, 3)
    }

    func testRetentionRetiresWholeBucketAndKeepsOpenGap() async throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let context = ModelContext(container)
        let server = UUID()
        try seed(519, server: server, context: context, date: start)
        context.insert(MonitoringGapRecord(serverID: server, startedAt: start,
            reason: .collectorStopped, collectorID: "fixture", collectorVersion: "1"))
        try context.save()
        let repository = MonitoringHistoryRepository(context: context)
        var policy = retainedPolicy
        policy.rawRetention = 60
        let report = try await repository.performBatchedMaintenance(policy: policy,
            now: start.addingTimeInterval(3_600), batchSize: 13)
        XCTAssertEqual(report.rawSamplesRemoved, 519)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MonitoringSampleRecord>()), 0)
        XCTAssertEqual(try cpuAggregate(context: context, server: server, resolution: .minute).sampleCount, 519)
        XCTAssertEqual(try repository.storageSummary().gapCount, 1)
        XCTAssertNil(try context.fetch(FetchDescriptor<MonitoringGapRecord>()).first?.endedAt)
    }

    func testSaveFailurePreservesSourcesAndCachedSummaryThenRetrySucceeds() async throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let context = ModelContext(container)
        let server = UUID()
        try seed(40, server: server, context: context, date: start)
        let repository = MonitoringHistoryRepository(context: context)
        try await repository.prepareStorageSummary(batchSize: 7)
        let before = try repository.storageSummary()
        repository.beforeSave = { throw CocoaError(.fileWriteNoPermission) }
        do {
            _ = try await repository.performBatchedMaintenance(policy: retainedPolicy,
                now: start.addingTimeInterval(3_600), batchSize: 7)
            XCTFail("A failed commit must be reported")
        } catch { }
        XCTAssertEqual(try repository.storageSummary(), before)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MonitoringSampleRecord>()), 40)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MonitoringAggregateRecord>()), 0)
        repository.beforeSave = nil
        _ = try await repository.performBatchedMaintenance(policy: retainedPolicy,
            now: start.addingTimeInterval(3_600), batchSize: 7)
        XCTAssertEqual(try cpuAggregate(context: context, server: server, resolution: .minute).sampleCount, 40)
    }

    func testCancellationAfterCommittedBucketCanRetryWithoutLosingHistory() async throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let context = ModelContext(container)
        let server = UUID()
        for bucket in 0..<8 { try seed(50, server: server, context: context, date: start.addingTimeInterval(Double(bucket * 60))) }
        let repository = MonitoringHistoryRepository(context: context)
        let policy = retainedPolicy
        let now = start.addingTimeInterval(3_600)
        let task = Task { try await repository.performBatchedMaintenance(policy: policy, now: now, batchSize: 7) }
        let firstCommitDeadline = ContinuousClock.now.advanced(by: .seconds(15))
        while repository.maintenanceBatchCount == 0, ContinuousClock.now < firstCommitDeadline { await Task.yield() }
        if repository.maintenanceBatchCount == 0 {
            task.cancel()
            _ = try await task.value
            XCTFail("Maintenance did not reach its first bounded commit")
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation should interrupt between batches") }
        catch is CancellationError { }
        _ = try await repository.performBatchedMaintenance(policy: policy, now: now, batchSize: 7)
        XCTAssertEqual(try cpuAggregate(context: context, server: server, resolution: .quarterHour).sampleCount, 400)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MonitoringSampleRecord>()), 400)
    }

    func testLateSampleAfterRawRetirementMergesWithoutReplacingAggregate() async throws {
        try await assertLateSample(minuteRetention: 20_000, expectedResolution: .minute)
    }

    func testLateSampleAfterMinuteRetirementMergesIntoRetainedQuarter() async throws {
        try await assertLateSample(minuteRetention: 60, expectedResolution: .quarterHour)
    }

    func testLatePreviouslyUnseenMinuteSurvivesParentRecomputation() async throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let context = ModelContext(container)
        let server = UUID()
        try seed(2, server: server, context: context, date: start)
        let clock = ManualMonitoringClock(now: start.addingTimeInterval(3_600))
        let repository = MonitoringHistoryRepository(context: context, clock: clock)
        _ = try await repository.performBatchedMaintenance(policy: retainedPolicy, now: clock.now())
        try repository.recordSnapshot(snapshot(at: start.addingTimeInterval(120), cpu: 99), serverID: server)
        _ = try await repository.performBatchedMaintenance(policy: retainedPolicy, now: clock.now())
        let aggregate = try cpuAggregate(context: context, server: server, resolution: .quarterHour)
        XCTAssertEqual(aggregate.sampleCount, 3)
        XCTAssertEqual(aggregate.last, 99)
        XCTAssertEqual(try repository.storageSummary().rawSampleCount, 3)
    }

    func testLateWriteBetweenPagesRestartsBucketProjection() async throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let context = ModelContext(container)
        let server = UUID()
        try seed(100, server: server, context: context, date: start)
        let clock = ManualMonitoringClock(now: start.addingTimeInterval(3_600))
        let repository = MonitoringHistoryRepository(context: context, clock: clock)
        try await repository.prepareStorageSummary()
        let policy = retainedPolicy
        let task = Task { try await repository.performBatchedMaintenance(policy: policy, now: clock.now(), batchSize: 1) }
        await Task.yield()
        try repository.recordSnapshot(snapshot(at: start.addingTimeInterval(1), cpu: 100), serverID: server)
        _ = try await task.value
        let aggregate = try cpuAggregate(context: context, server: server, resolution: .minute)
        XCTAssertEqual(aggregate.sampleCount, 101)
        XCTAssertEqual(aggregate.last, 100)
        XCTAssertEqual(try repository.storageSummary().rawSampleCount, 101)
    }

    func testSummaryPreparationReconcilesConcurrentSnapshotWithoutMixedCounts() async throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let context = ModelContext(container)
        let server = UUID()
        try seed(50, server: server, context: context, date: start)
        let repository = MonitoringHistoryRepository(context: context)
        let task = Task { try await repository.prepareStorageSummary(batchSize: 1) }
        await Task.yield()
        try repository.recordSnapshot(snapshot(at: start.addingTimeInterval(1), cpu: 20), serverID: server)
        try await task.value
        XCTAssertEqual(try repository.storageSummary().rawSampleCount, 51)
        XCTAssertEqual(repository.summaryScanCount, 1)
    }

    func testCachedSummaryChangesOnlyAfterSuccessfulCommit() async throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let context = ModelContext(container)
        let clock = ManualMonitoringClock(now: start)
        let repository = MonitoringHistoryRepository(context: context, clock: clock)
        try await repository.prepareStorageSummary()
        let server = UUID()
        try repository.recordSnapshot(snapshot(at: start, cpu: 20), serverID: server)
        let after = try repository.storageSummary()
        for _ in 0..<30 { XCTAssertEqual(try repository.storageSummary(), after) }
        XCTAssertEqual(repository.summaryScanCount, 1)
        XCTAssertEqual(after.rawSampleCount, 1)
        repository.beforeSave = { throw CocoaError(.fileWriteNoPermission) }
        XCTAssertThrowsError(try repository.recordSnapshot(snapshot(at: start, cpu: 40), serverID: server))
        XCTAssertEqual(try repository.storageSummary(), after)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MonitoringSampleRecord>()), 1)
    }

    func testAutomaticAndManualMaintenanceCoalesceAndShutdownRejectsNewWork() async throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let clock = ManualMonitoringClock(now: start.addingTimeInterval(3_600))
        let service = MacMonitoringHistoryService(container: container, clock: clock)
        service.requestMaintenance()
        let one = Task { try await service.performMaintenance(now: clock.now()) }
        let two = Task { try await service.performMaintenance(now: clock.now()) }
        _ = try await one.value
        _ = try await two.value
        XCTAssertEqual(service.maintenanceRunCount, 1)
        let drained = await service.stopAndDrain(until: .now.advanced(by: .seconds(8)))
        XCTAssertTrue(drained)
        service.requestMaintenance()
        do { _ = try await service.performMaintenance(); XCTFail("Stopped service must not start a new round") }
        catch is CancellationError { }
        XCTAssertEqual(service.maintenanceRunCount, 1)
    }

    func testAutomaticFailureBackoffDoesNotDelayExplicitRetry() async throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let context = ModelContext(container)
        let server = UUID()
        try seed(40, server: server, context: context, date: start)
        let clock = ManualMonitoringClock(now: start.addingTimeInterval(3_600))
        let repository = MonitoringHistoryRepository(context: context, clock: clock)
        let service = MacMonitoringHistoryService(repository: repository, clock: clock)
        repository.beforeAggregateEncoding = { throw CocoaError(.coderInvalidValue) }
        service.requestMaintenance()
        do { _ = try await service.performMaintenance(); XCTFail("Fixture should fail maintenance") }
        catch { }
        XCTAssertEqual(service.maintenanceRunCount, 1)
        for _ in 0..<50 {
            try repository.recordSnapshot(snapshot(at: clock.now(), cpu: 50), serverID: server)
        }
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(service.maintenanceRunCount, 1, "Successful snapshots must not restart a persistent failure")
        clock.advance(by: 59)
        service.requestMaintenance()
        await Task.yield()
        XCTAssertEqual(service.maintenanceRunCount, 1)
        clock.advance(by: 1)
        service.requestMaintenance()
        do { _ = try await service.performMaintenance(); XCTFail("Fixture should still fail") }
        catch { }
        XCTAssertEqual(service.maintenanceRunCount, 2)
        repository.beforeAggregateEncoding = nil
        _ = try await service.performMaintenance()
        XCTAssertEqual(service.maintenanceRunCount, 3, "Manual retry must be immediate during the automatic backoff")
        service.requestMaintenance()
        await Task.yield()
        XCTAssertEqual(service.maintenanceRunCount, 3, "A successful run retains the normal fifteen-minute schedule")
        service.cancelImmediately()
    }

    func testDedicatedContextDoesNotSavePendingServerFormEdits() throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let formContext = ModelContext(container)
        formContext.autosaveEnabled = false
        let server = ServerRecord(name: "Unsaved form", host: "192.0.2.1", username: "fixture")
        formContext.insert(server)
        let service = MacMonitoringHistoryService(container: container)
        try service.repository.recordSnapshot(snapshot(at: Date(), cpu: 12), serverID: server.id)
        service.cancelImmediately()
        let observer = ModelContext(container)
        XCTAssertEqual(try observer.fetchCount(FetchDescriptor<ServerRecord>()), 0)
        XCTAssertEqual(try observer.fetchCount(FetchDescriptor<MonitoringSampleRecord>()), 1)
        XCTAssertTrue(formContext.hasChanges)
    }

    func testDenseThousandHostBucketYieldsAndDrainsBeforeDeadline() async throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        for _ in 0..<1_000 {
            let server = UUID()
            for value in 0..<12 {
                context.insert(try MonitoringSampleRecord(serverID: server, capturedAt: start,
                    collectorID: "fixture", collectorVersion: "1", quality: .normal, sourceDataAge: 0,
                    metricValues: [MonitoringMetric.cpuUsage.rawValue: Double(value)]))
            }
        }
        try context.save()
        let clock = ManualMonitoringClock(now: start.addingTimeInterval(3_600))
        let repository = MonitoringHistoryRepository(context: context, clock: clock)
        let service = MacMonitoringHistoryService(repository: repository, clock: clock)
        var policy = retainedPolicy
        policy.rawRetention = 60
        let task = Task { try await service.performMaintenance(policy: policy, now: clock.now()) }
        var heartbeats = 0
        let firstRetirementDeadline = ContinuousClock.now.advanced(by: .seconds(20))
        while repository.largestAtomicRetirement == 0, ContinuousClock.now < firstRetirementDeadline {
            heartbeats += 1
            await Task.yield()
        }
        if repository.largestAtomicRetirement == 0 {
            service.cancelImmediately()
            _ = try await task.value
            XCTFail("Dense fixture did not reach its first per-host transaction")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        let drained = await service.stopAndDrain(until: deadline)
        XCTAssertTrue(drained)
        do { _ = try await task.value; XCTFail("Shutdown must cancel remaining hosts") }
        catch is CancellationError { }
        XCTAssertGreaterThan(heartbeats, 1)
        XCTAssertEqual(repository.largestAtomicRetirement, 12)
        XCTAssertFalse(context.hasChanges)
        let remaining = try context.fetchCount(FetchDescriptor<MonitoringSampleRecord>())
        XCTAssertGreaterThan(remaining, 0)
        XCTAssertLessThan(remaining, 12_000)

        let resumed = MonitoringHistoryRepository(context: context, clock: clock)
        _ = try await resumed.performBatchedMaintenance(policy: policy, now: clock.now())
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MonitoringSampleRecord>()), 0)
        let quarter = MonitoringResolution.quarterHour.rawValue
        let aggregates = try context.fetch(FetchDescriptor<MonitoringAggregateRecord>(predicate: #Predicate {
            $0.resolutionSeconds == quarter
        }))
        XCTAssertEqual(aggregates.count, 1_000)
        XCTAssertEqual(aggregates.reduce(0) { $0 + ($1.statistics[MonitoringMetric.cpuUsage.rawValue]?.sampleCount ?? 0) }, 12_000)
        print("Dense history fixture: heartbeat=\(heartbeats), max atomic main-thread unit=\(resumed.maximumAtomicUnitMilliseconds) ms, max commit=\(resumed.maximumCommittedBatchMilliseconds) ms")
    }

    func testPathologicalSingleHostBucketFailsWithoutPartialRetirement() async throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let context = ModelContext(container)
        let server = UUID()
        let count = MonitoringHistoryRepository.maximumAtomicBucketRows + 1
        try seed(count, server: server, context: context, date: start)
        let repository = MonitoringHistoryRepository(context: context)
        var policy = retainedPolicy
        policy.rawRetention = 60
        do {
            _ = try await repository.performBatchedMaintenance(policy: policy, now: start.addingTimeInterval(3_600))
            XCTFail("Pathological bucket must report a safe maintenance failure")
        } catch { }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MonitoringSampleRecord>()), count)
        XCTAssertEqual(try repository.storageSummary().rawSampleCount, count)
        XCTAssertEqual(repository.largestAtomicRetirement, 0)
        XCTAssertFalse(context.hasChanges)
    }

    func testSecondRetirementReadFailureRollsBackBeforeNextSnapshot() async throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let context = ModelContext(container)
        let server = UUID()
        try seed(40, server: server, context: context, date: start)
        let clock = ManualMonitoringClock(now: start.addingTimeInterval(3_600))
        let repository = MonitoringHistoryRepository(context: context, clock: clock)
        var policy = retainedPolicy
        policy.rawRetention = 60
        repository.beforeFetch = {
            if !context.deletedModelsArray.isEmpty { throw CocoaError(.fileReadCorruptFile) }
        }
        do {
            _ = try await repository.performBatchedMaintenance(policy: policy, now: clock.now(), batchSize: 7)
            XCTFail("The second retirement fetch should fail")
        } catch { }
        repository.beforeFetch = nil
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MonitoringSampleRecord>()), 40)
        XCTAssertEqual(try cpuAggregate(context: context, server: server, resolution: .minute).sampleCount, 40)
        try repository.recordSnapshot(snapshot(at: clock.now(), cpu: 50), serverID: server)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MonitoringSampleRecord>()), 41)
        XCTAssertEqual(try repository.storageSummary().rawSampleCount, 41)
        _ = try await repository.performBatchedMaintenance(policy: policy, now: clock.now(), batchSize: 7)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MonitoringSampleRecord>()), 1)
        XCTAssertEqual(try cpuAggregate(context: context, server: server, resolution: .minute).sampleCount, 40)
    }

    func testEncodingFailureLeavesNoPendingAggregateForNextSnapshot() async throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let context = ModelContext(container)
        let server = UUID()
        try seed(40, server: server, context: context, date: start)
        let clock = ManualMonitoringClock(now: start.addingTimeInterval(3_600))
        let repository = MonitoringHistoryRepository(context: context, clock: clock)
        repository.beforeAggregateEncoding = { throw CocoaError(.coderInvalidValue) }
        do {
            _ = try await repository.performBatchedMaintenance(policy: retainedPolicy, now: clock.now(), batchSize: 7)
            XCTFail("Encoding failure must be reported")
        } catch { }
        repository.beforeAggregateEncoding = nil
        XCTAssertFalse(context.hasChanges)
        try repository.recordSnapshot(snapshot(at: clock.now(), cpu: 50), serverID: server)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MonitoringSampleRecord>()), 41)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MonitoringAggregateRecord>()), 0)
        XCTAssertEqual(try repository.storageSummary().rawSampleCount, 41)
    }

    func testSummaryCompletesWhileSnapshotsContinueAtEveryYield() async throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let context = ModelContext(container)
        let server = UUID()
        try seed(1_000, server: server, context: context, date: start)
        let clock = ManualMonitoringClock(now: start.addingTimeInterval(3_600))
        let repository = MonitoringHistoryRepository(context: context, clock: clock)
        let task = Task { try await repository.prepareStorageSummary(batchSize: 17) }
        var writes = 0
        while repository.summaryScanCount == 0, writes < 2_000 {
            try repository.recordSnapshot(snapshot(at: clock.now(), cpu: Double(writes % 100)), serverID: server)
            writes += 1
            await Task.yield()
        }
        XCTAssertEqual(repository.summaryScanCount, 1, "Accounting must finish before continuous writes stop")
        try await task.value
        XCTAssertGreaterThan(writes, 1)
        XCTAssertLessThan(writes, 2_000)
        let summary = try repository.storageSummary()
        XCTAssertEqual(summary.rawSampleCount, 1_000 + writes)
        let records = try context.fetch(FetchDescriptor<MonitoringSampleRecord>())
        let bytes = records.reduce(0) { $0 + 192 + $1.metricValuesData.count + $1.collectorID.utf8.count + $1.collectorVersion.utf8.count }
        XCTAssertEqual(summary.estimatedBytes, bytes)
    }

    private func assertLateSample(minuteRetention: TimeInterval, expectedResolution: MonitoringResolution) async throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let context = ModelContext(container)
        let server = UUID()
        try seed(2, server: server, context: context, date: start)
        let clock = ManualMonitoringClock(now: start.addingTimeInterval(3_600))
        let repository = MonitoringHistoryRepository(context: context, clock: clock)
        var policy = retainedPolicy
        policy.rawRetention = 60
        policy.minuteRetention = minuteRetention
        _ = try await repository.performBatchedMaintenance(policy: policy, now: clock.now(), batchSize: 1)
        try repository.recordSnapshot(snapshot(at: start.addingTimeInterval(1), cpu: 99), serverID: server)
        _ = try await repository.performBatchedMaintenance(policy: policy, now: clock.now(), batchSize: 1)
        let stats = try cpuAggregate(context: context, server: server, resolution: expectedResolution)
        XCTAssertEqual(stats.sampleCount, 3)
        XCTAssertEqual(stats.average, 100.0 / 3, accuracy: 0.001)
        XCTAssertEqual(stats.last, 99)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MonitoringSampleRecord>()), 0)
        // A new service/repository must also understand the persisted compacted bucket.
        let reopened = MonitoringHistoryRepository(context: ModelContext(container), clock: clock)
        try reopened.recordSnapshot(snapshot(at: start.addingTimeInterval(-0.0), cpu: 20), serverID: server)
        _ = try await reopened.performBatchedMaintenance(policy: policy, now: clock.now(), batchSize: 1)
        let freshContext = ModelContext(container)
        let reopenedStats = try cpuAggregate(context: freshContext, server: server, resolution: expectedResolution)
        XCTAssertEqual(reopenedStats.sampleCount, 4)
        XCTAssertEqual(reopenedStats.last, 99)
    }

    private var retainedPolicy: MonitoringRetentionPolicy {
        MonitoringRetentionPolicy(rawRetention: 20_000, minuteRetention: 20_000,
                                  quarterHourRetention: 20_000, diskQuotaBytes: 100_000_000)
    }

    private func seed(_ count: Int, server: UUID, context: ModelContext, date: Date) throws {
        for index in 0..<count {
            context.insert(try MonitoringSampleRecord(serverID: server, capturedAt: date,
                collectorID: "fixture", collectorVersion: "1", quality: .normal, sourceDataAge: 0,
                metricValues: [MonitoringMetric.cpuUsage.rawValue: Double(index % 100)]))
        }
        try context.save()
    }

    private func cpuAggregate(context: ModelContext, server: UUID, resolution: MonitoringResolution) throws -> MonitoringAggregateStatistics {
        let seconds = resolution.rawValue
        let records = try context.fetch(FetchDescriptor<MonitoringAggregateRecord>(predicate: #Predicate {
            $0.serverID == server && $0.resolutionSeconds == seconds
        }, sortBy: [SortDescriptor(\.bucketStart)]))
        return try XCTUnwrap(records.first?.statistics[MonitoringMetric.cpuUsage.rawValue])
    }

    private func snapshot(at date: Date, cpu: Double) -> ServerSnapshot {
        var snapshot = ServerSnapshot.empty
        snapshot.capturedAt = date
        snapshot.cpuUsage = cpu
        return snapshot
    }
}

@MainActor
final class MacHistoryPerformanceTests: XCTestCase {
    func testHistorySummaryAndMaintenanceBenchmarks() async throws {
        guard ProcessInfo.processInfo.environment["SERVERDASH_RUN_LARGE_BENCHMARKS"] == "1" else {
            throw XCTSkip("Opt-in Release benchmark: SERVERDASH_RUN_LARGE_BENCHMARKS=1")
        }
        var results: [[String: Any]] = []
        for count in [10_000, 100_000] {
            let container = try PersistenceController.makeInMemoryContainer()
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let server = UUID()
            let start = Date(timeIntervalSince1970: 36_000)
            for index in 0..<count {
                context.insert(try MonitoringSampleRecord(serverID: server,
                    capturedAt: start.addingTimeInterval(Double(index % 3_600)),
                    collectorID: "fixture", collectorVersion: "1", quality: .normal, sourceDataAge: 0,
                    metricValues: [MonitoringMetric.cpuUsage.rawValue: Double(index % 100)]))
                if index % 1_000 == 999 { try context.save() }
            }
            try context.save()
            let repository = MonitoringHistoryRepository(context: context)
            let preparation = ContinuousClock.now
            let prepareTask = Task { try await repository.prepareStorageSummary() }
            var concurrentWrites = 0
            let liveDate = start.addingTimeInterval(7_200)
            while repository.summaryScanCount == 0, concurrentWrites < 10_000 {
                var snapshot = ServerSnapshot.empty
                snapshot.capturedAt = liveDate
                snapshot.cpuUsage = Double(concurrentWrites % 100)
                try repository.recordSnapshot(snapshot, serverID: server)
                concurrentWrites += 1
                await Task.yield()
            }
            XCTAssertEqual(repository.summaryScanCount, 1, "100k accounting must progress during sustained writes")
            try await prepareTask.value
            let measuredCount = count + concurrentWrites
            let preparationMS = elapsedMS(since: preparation)
            var baseline: [Double] = [], optimized: [Double] = []
            for iteration in 0..<33 {
                let before = ContinuousClock.now
                // The previous history view rebuilt this full accounting pass on every chart refresh.
                let rows = try context.fetch(FetchDescriptor<MonitoringSampleRecord>())
                let bytes = rows.reduce(0) { $0 + 192 + $1.metricValuesData.count + $1.collectorID.utf8.count + $1.collectorVersion.utf8.count }
                let baselineMS = elapsedMS(since: before)
                let after = ContinuousClock.now
                let summary = try repository.storageSummary()
                let optimizedMS = elapsedMS(since: after)
                XCTAssertEqual(summary.rawSampleCount, measuredCount)
                XCTAssertEqual(summary.estimatedBytes, bytes)
                if iteration >= 3 { baseline.append(baselineMS); optimized.append(optimizedMS) }
                await Task.yield()
            }
            let maintenancePolicy = MonitoringRetentionPolicy(
                rawRetention: 100_000, minuteRetention: 100_000, quarterHourRetention: 100_000,
                diskQuotaBytes: 512 * 1_024 * 1_024)
            let maintenanceNow = start.addingTimeInterval(7_200)
            let maintenanceStart = ContinuousClock.now
            _ = try await repository.performBatchedMaintenance(policy: maintenancePolicy, now: maintenanceNow)
            let maintenanceMS = elapsedMS(since: maintenanceStart)
            let maintenanceComparison = try await compareQuietMaintenance(
                sourceContext: context, optimized: repository, policy: maintenancePolicy, now: maintenanceNow)
            var result: [String: Any] = [
                "seedSamples": count, "samples": measuredCount, "concurrentWritesDuringPreparation": concurrentWrites,
                "warmups": 3, "iterations": 30,
                "baselineSummaryMedianMS": percentile(baseline, fraction: 0.5),
                "baselineSummaryP95MS": percentile(baseline, fraction: 0.95),
                "cachedSummaryMedianMS": percentile(optimized, fraction: 0.5),
                "cachedSummaryP95MS": percentile(optimized, fraction: 0.95),
                "initialChunkedSummaryMS": preparationMS,
                "coldBatchedMaintenanceMS": maintenanceMS,
                "committedBatches": repository.maintenanceBatchCount,
                "maximumAtomicUnitMS": repository.maximumAtomicUnitMilliseconds,
                "maximumCommitMS": repository.maximumCommittedBatchMilliseconds,
                "notes": "Summary operations are synchronous MainActor occupied time; async preparation/maintenance are end-to-end elapsed time including yields. In-memory fixture; no UI, network or disk startup claim."
            ]
            result.merge(maintenanceComparison) { _, comparison in comparison }
            result["testHostResourceUsage"] = MacPerformanceResourceMetrics.cumulativeTestHostSnapshot()
            results.append(result)
            XCTAssertLessThan(percentile(optimized, fraction: 0.95), percentile(baseline, fraction: 0.95) * 0.7)
        }
        let output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("serverdash-history-performance-benchmark.json")
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("History performance benchmark: \(output.path)")
    }

    /// Replay the retained synchronous algorithm against a separate store. The source fixture
    /// is copied once per size, not reconstructed for each sample; neither repository can update
    /// the other's cache or aggregate objects. All rounds use the same fixed retention cutoff.
    private func compareQuietMaintenance(
        sourceContext: ModelContext,
        optimized: MonitoringHistoryRepository,
        policy: MonitoringRetentionPolicy,
        now: Date
    ) async throws -> [String: Any] {
        let baselineContainer = try PersistenceController.makeInMemoryContainer()
        let baselineContext = ModelContext(baselineContainer)
        baselineContext.autosaveEnabled = false
        var cursor: UUID?
        var copied = 0
        while true {
            var descriptor: FetchDescriptor<MonitoringSampleRecord>
            if let cursor {
                descriptor = FetchDescriptor(predicate: #Predicate { $0.id > cursor }, sortBy: [SortDescriptor(\.id)])
            } else {
                descriptor = FetchDescriptor(sortBy: [SortDescriptor(\.id)])
            }
            descriptor.fetchLimit = 512
            let page = try sourceContext.fetch(descriptor)
            for source in page {
                baselineContext.insert(try MonitoringSampleRecord(
                    id: source.id, serverID: source.serverID, capturedAt: source.capturedAt,
                    collectorID: source.collectorID, collectorVersion: source.collectorVersion,
                    quality: source.quality, sourceDataAge: source.sourceDataAge,
                    metricValues: source.metricValues))
            }
            copied += page.count
            try baselineContext.save()
            cursor = page.last?.id ?? cursor
            if page.count < 512 { break }
            await Task.yield()
        }
        let baseline = MonitoringHistoryRepository(context: baselineContext)
        let initial = ContinuousClock.now
        _ = try baseline.performMaintenance(policy: policy, now: now)
        let baselineInitialMS = elapsedMS(since: initial)
        var legacyTimes: [Double] = [], batchedTimes: [Double] = []
        for iteration in 0..<33 {
            // This entire legacy call is one uninterrupted MainActor work unit.
            let legacyStart = ContinuousClock.now
            let legacyReport = try baseline.performMaintenance(policy: policy, now: now)
            let legacyMS = elapsedMS(since: legacyStart)
            await Task.yield()
            let batchedStart = ContinuousClock.now
            let batchedReport = try await optimized.performBatchedMaintenance(policy: policy, now: now)
            let batchedMS = elapsedMS(since: batchedStart)
            XCTAssertEqual(legacyReport.rawSamplesRemoved, 0)
            XCTAssertEqual(legacyReport.aggregatesRemoved, 0)
            XCTAssertEqual(batchedReport.rawSamplesRemoved, 0)
            XCTAssertEqual(batchedReport.aggregatesRemoved, 0)
            if iteration >= 3 {
                legacyTimes.append(legacyMS)
                batchedTimes.append(batchedMS)
            }
            await Task.yield()
        }
        let legacySummary = try baseline.storageSummary(policy: policy)
        let optimizedSummary = try optimized.storageSummary(policy: policy)
        XCTAssertEqual(legacySummary.rawSampleCount, copied)
        XCTAssertEqual(optimizedSummary.rawSampleCount, copied)
        XCTAssertEqual(legacySummary.aggregateCount, optimizedSummary.aggregateCount)
        XCTAssertEqual(legacySummary.gapCount, optimizedSummary.gapCount)
        let legacyP95 = percentile(legacyTimes, fraction: 0.95)
        let batchedP95 = percentile(batchedTimes, fraction: 0.95)
        XCTAssertLessThan(batchedP95, legacyP95 * 0.7, "Quiet maintenance should meet the thirty-percent hotspot target")
        return [
            "maintenanceWarmups": 3,
            "maintenanceIterations": 30,
            "maintenanceFixtureCopies": 1,
            "legacyInitialMaintenanceMS": baselineInitialMS,
            "legacyQuietMaintenanceMedianMS": percentile(legacyTimes, fraction: 0.5),
            "legacyQuietMaintenanceP95MS": legacyP95,
            "legacyQuietMaximumUninterruptedMainActorMS": legacyTimes.max() ?? 0,
            "batchedQuietMaintenanceMedianMS": percentile(batchedTimes, fraction: 0.5),
            "batchedQuietMaintenanceP95MS": batchedP95,
            "batchedQuietMaximumElapsedMS": batchedTimes.max() ?? 0,
            "batchedObservedMaximumAtomicUnitMS": optimized.maximumAtomicUnitMilliseconds,
            "batchedObservedMaximumCommitMS": optimized.maximumCommittedBatchMilliseconds,
            "maintenanceComparisonScope": "Separate in-memory stores and repositories, identical committed source frames, fixed cutoff, no new data or deletions during 3 warmups plus 30 measured rounds. The synchronous baseline replays the retained old maintenance API inside the same Release binary; it already benefits from the new summary cache and linear quota loop, so this is a conservative algorithm comparison, not a prior-binary measurement. Legacy call time is uninterrupted MainActor occupancy; batched elapsed can include async scheduling. Batched atomic-unit/commit maxima include initial compaction and these quiet rounds, not frame latency or total main-thread CPU."
        ]
    }

    private func elapsedMS(since start: ContinuousClock.Instant) -> Double {
        let parts = start.duration(to: .now).components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }

    private func percentile(_ values: [Double], fraction: Double) -> Double {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1)]
    }
}
#endif
