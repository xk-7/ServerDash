@preconcurrency import Foundation
@preconcurrency import SwiftData

protocol MonitoringClock: Sendable {
    func now() -> Date
    func sleep(for duration: TimeInterval) async throws
}

struct SystemMonitoringClock: MonitoringClock {
    func now() -> Date { Date() }

    func sleep(for duration: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(max(0, duration)))
    }
}

enum MonitoringMetric: String, CaseIterable, Identifiable, Codable, Sendable {
    case cpuUsage
    case memoryUsage
    case load1
    case load5
    case load15
    case swapUsage
    case diskUsage
    case downloadBytesPerSecond
    case uploadBytesPerSecond

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpuUsage: "CPU"
        case .memoryUsage: "内存"
        case .load1: "Load 1m"
        case .load5: "Load 5m"
        case .load15: "Load 15m"
        case .swapUsage: "Swap"
        case .diskUsage: "磁盘"
        case .downloadBytesPerSecond: "下载"
        case .uploadBytesPerSecond: "上传"
        }
    }

    var unit: String {
        switch self {
        case .cpuUsage, .memoryUsage, .swapUsage, .diskUsage: "%"
        case .downloadBytesPerSecond, .uploadBytesPerSecond: "B/s"
        case .load1, .load5, .load15: ""
        }
    }
}

enum MonitoringDataQuality: String, Codable, Sendable {
    case normal
    case timeout
    case unreachable
    case authenticationFailed
    case fingerprintChanged
    case sleeping
    case networkInterrupted
    case collectorStopped
    case unsupported
    case unknown
}

enum MonitoringGapReason: String, CaseIterable, Codable, Sendable {
    case timeout
    case unreachable
    case authenticationFailed
    case fingerprintChanged
    case sleeping
    case networkInterrupted
    case collectorStopped
    case unsupported
    case unknown

    var title: String {
        switch self {
        case .timeout: "采集超时"
        case .unreachable: "服务器不可达"
        case .authenticationFailed: "认证失败"
        case .fingerprintChanged: "主机指纹变化"
        case .sleeping: "Mac 睡眠"
        case .networkInterrupted: "本机网络中断"
        case .collectorStopped: "Collector 停止"
        case .unsupported: "Collector 不受支持"
        case .unknown: "未知采集缺口"
        }
    }

    var quality: MonitoringDataQuality {
        switch self {
        case .timeout: .timeout
        case .unreachable: .unreachable
        case .authenticationFailed: .authenticationFailed
        case .fingerprintChanged: .fingerprintChanged
        case .sleeping: .sleeping
        case .networkInterrupted: .networkInterrupted
        case .collectorStopped: .collectorStopped
        case .unsupported: .unsupported
        case .unknown: .unknown
        }
    }

    var isCollectorSide: Bool {
        switch self {
        case .sleeping, .networkInterrupted, .collectorStopped: true
        default: false
        }
    }

    var isCollectionFailure: Bool {
        !isCollectorSide
    }

    static func classify(_ error: Error) -> MonitoringGapReason {
        guard let connectionError = error as? ConnectionError else {
            if error is CancellationError { return .collectorStopped }
            return .unknown
        }
        switch connectionError {
        case .timeout, .queueTimeout:
            return .timeout
        case .dnsFailed, .connectionRefused, .networkUnreachable:
            return .unreachable
        case .authenticationFailed, .privateKeyOrPassphraseFailed,
             .keyboardInteractiveRequired:
            return .authenticationFailed
        case .hostKeyChanged, .hostKeyUntrusted:
            return .fingerprintChanged
        case .incompatibleMonitor, .remoteCommandMissing:
            return .unsupported
        case .identityReferenceMissing, .privateKeyMissing, .credentialMissing:
            return .authenticationFailed
        case .cancelled:
            return .collectorStopped
        case .outputLimitExceeded, .commandFailed:
            return .unknown
        }
    }
}

enum MonitoringResolution: Int, CaseIterable, Codable, Sendable {
    case raw = 5
    case minute = 60
    case quarterHour = 900

    var title: String {
        switch self {
        case .raw: "原始值"
        case .minute: "1 分钟聚合"
        case .quarterHour: "15 分钟聚合"
        }
    }
}

struct MonitoringAggregateStatistics: Codable, Hashable, Sendable {
    var minimum: Double
    var maximum: Double
    var average: Double
    var last: Double
    var sampleCount: Int
}

@Model
final class MonitoringSampleRecord {
    @Attribute(.unique) var id: UUID
    var serverID: UUID
    var capturedAt: Date
    var collectorID: String
    var collectorVersion: String
    var qualityRawValue: String
    var sourceDataAge: TimeInterval
    var metricValuesData: Data

    init(
        id: UUID = UUID(),
        serverID: UUID,
        capturedAt: Date,
        collectorID: String,
        collectorVersion: String,
        quality: MonitoringDataQuality,
        sourceDataAge: TimeInterval,
        metricValues: [String: Double]
    ) throws {
        self.id = id
        self.serverID = serverID
        self.capturedAt = capturedAt
        self.collectorID = collectorID
        self.collectorVersion = collectorVersion
        qualityRawValue = quality.rawValue
        self.sourceDataAge = max(0, sourceDataAge)
        metricValuesData = try JSONEncoder().encode(metricValues)
    }

    var quality: MonitoringDataQuality {
        MonitoringDataQuality(rawValue: qualityRawValue) ?? .unknown
    }

    var metricValues: [String: Double] {
        (try? JSONDecoder().decode([String: Double].self, from: metricValuesData)) ?? [:]
    }
}

@Model
final class MonitoringAggregateRecord {
    @Attribute(.unique) var id: UUID
    var serverID: UUID
    var bucketStart: Date
    var bucketEnd: Date
    var resolutionSeconds: Int
    var collectorID: String
    var collectorVersion: String
    var qualityRawValue: String
    var maximumSourceDataAge: TimeInterval
    var statisticsData: Data

    init(
        id: UUID = UUID(),
        serverID: UUID,
        bucketStart: Date,
        bucketEnd: Date,
        resolution: MonitoringResolution,
        collectorID: String,
        collectorVersion: String,
        quality: MonitoringDataQuality = .normal,
        maximumSourceDataAge: TimeInterval,
        statistics: [String: MonitoringAggregateStatistics]
    ) throws {
        self.id = id
        self.serverID = serverID
        self.bucketStart = bucketStart
        self.bucketEnd = bucketEnd
        resolutionSeconds = resolution.rawValue
        self.collectorID = collectorID
        self.collectorVersion = collectorVersion
        qualityRawValue = quality.rawValue
        self.maximumSourceDataAge = max(0, maximumSourceDataAge)
        statisticsData = try JSONEncoder().encode(statistics)
    }

    var resolution: MonitoringResolution? {
        MonitoringResolution(rawValue: resolutionSeconds)
    }

    var statistics: [String: MonitoringAggregateStatistics] {
        (try? JSONDecoder().decode(
            [String: MonitoringAggregateStatistics].self,
            from: statisticsData
        )) ?? [:]
    }

    func replace(
        bucketEnd: Date,
        collectorID: String,
        collectorVersion: String,
        maximumSourceDataAge: TimeInterval,
        statistics: [String: MonitoringAggregateStatistics]
    ) throws {
        self.bucketEnd = bucketEnd
        self.collectorID = collectorID
        self.collectorVersion = collectorVersion
        self.maximumSourceDataAge = max(0, maximumSourceDataAge)
        statisticsData = try JSONEncoder().encode(statistics)
    }
}

@Model
final class MonitoringGapRecord {
    @Attribute(.unique) var id: UUID
    var serverID: UUID
    var startedAt: Date
    var endedAt: Date?
    var reasonRawValue: String
    var collectorID: String
    var collectorVersion: String

    init(
        id: UUID = UUID(),
        serverID: UUID,
        startedAt: Date,
        endedAt: Date? = nil,
        reason: MonitoringGapReason,
        collectorID: String,
        collectorVersion: String
    ) {
        self.id = id
        self.serverID = serverID
        self.startedAt = startedAt
        self.endedAt = endedAt
        reasonRawValue = reason.rawValue
        self.collectorID = collectorID
        self.collectorVersion = collectorVersion
    }

    var reason: MonitoringGapReason {
        MonitoringGapReason(rawValue: reasonRawValue) ?? .unknown
    }
}

struct MonitoringRetentionPolicy: Equatable, Sendable {
    var rawRetention: TimeInterval = 24 * 60 * 60
    var minuteRetention: TimeInterval = 30 * 24 * 60 * 60
    var quarterHourRetention: TimeInterval = 365 * 24 * 60 * 60
    var diskQuotaBytes: Int = 512 * 1_024 * 1_024

    static let `default` = MonitoringRetentionPolicy()
}

struct MonitoringHistoryPoint: Identifiable, Hashable, Sendable {
    let id: String
    let date: Date
    let minimum: Double
    let maximum: Double
    let average: Double
    let last: Double
    let sampleCount: Int
}

struct MonitoringGapInterval: Identifiable, Hashable, Sendable {
    let id: UUID
    let start: Date
    let end: Date
    let reason: MonitoringGapReason

    var isCollectorSide: Bool { reason.isCollectorSide }
}

struct MonitoringHistorySeries: Sendable {
    let metric: MonitoringMetric
    let resolution: MonitoringResolution
    let points: [MonitoringHistoryPoint]
    let segments: [[MonitoringHistoryPoint]]
    let gaps: [MonitoringGapInterval]
}

struct MonitoringStorageSummary: Equatable, Sendable {
    let rawSampleCount: Int
    let aggregateCount: Int
    let gapCount: Int
    let estimatedBytes: Int
    let quotaBytes: Int

    var quotaFraction: Double {
        guard quotaBytes > 0 else { return 0 }
        return min(1, Double(estimatedBytes) / Double(quotaBytes))
    }
}

struct MonitoringMaintenanceReport: Equatable, Sendable {
    let rawSamplesRemoved: Int
    let aggregatesRemoved: Int
    let gapsRemoved: Int
    let estimatedBytesAfterCleanup: Int
}

struct MonitoringStartupGapRequest: Sendable {
    let serverID: UUID
    let lastSuccessfulAt: Date?
    let refreshInterval: TimeInterval
}

@MainActor
final class MonitoringHistoryRepository {
    nonisolated static let collectorID = "serverdash.ssh.linux"
    nonisolated static let collectorVersion = "1"

    private struct MutableStatistics {
        var minimum: Double
        var maximum: Double
        var total: Double
        var last: Double
        var sampleCount: Int

        init(value: Double, count: Int = 1) {
            minimum = value
            maximum = value
            total = value * Double(count)
            last = value
            sampleCount = count
        }

        mutating func add(value: Double, count: Int = 1, minimum: Double? = nil, maximum: Double? = nil) {
            self.minimum = Swift.min(self.minimum, minimum ?? value)
            self.maximum = Swift.max(self.maximum, maximum ?? value)
            total += value * Double(count)
            last = value
            sampleCount += count
        }

        var frozen: MonitoringAggregateStatistics {
            MonitoringAggregateStatistics(
                minimum: minimum,
                maximum: maximum,
                average: sampleCount == 0 ? 0 : total / Double(sampleCount),
                last: last,
                sampleCount: sampleCount
            )
        }
    }

    private struct AggregateKey: Hashable {
        let serverID: UUID
        let bucketStart: Date
    }

    private let context: ModelContext
    private let clock: any MonitoringClock
    private var lastMaintenanceAt: Date?
    private var cachedStorage: MonitoringStorageSummary?
    private var pendingAggregateByteDelta = 0
    private var pendingAggregateStorageChanges: [UUID: (before: Int, after: Int)] = [:]
    private var pendingMinuteKeys: Set<AggregateKey> = []
    private var accountingProgress: StorageAccountingProgress?
    private var rawKeyVersions: [AggregateKey: Int] = [:]
    private var minuteKeyVersions: [AggregateKey: Int] = [:]
    private var changedRawKeys: Set<AggregateKey> = []
    private var changedMinuteKeys: Set<AggregateKey> = []
    private var mutationVersion = 0
    private var rawBucketVersions: [Date: Int] = [:]
    private var minuteBucketVersions: [Date: Int] = [:]
    private var changedRawBuckets: Set<Date> = []
    private var changedMinuteBuckets: Set<Date> = []
    private var completedBatchedMaintenance = false
    // Set only by the app-owned Mac service; snapshot publication never waits for maintenance.
    var maintenanceRequested: (@MainActor () -> Void)?
    private(set) var summaryScanCount = 0
    private(set) var maintenanceBatchCount = 0
    // Test-only failure injection runs before the transaction commits.
    var beforeSave: (@MainActor () throws -> Void)?
    var beforeFetch: (@MainActor () throws -> Void)?
    var beforeAggregateEncoding: (@MainActor () throws -> Void)?
    private(set) var largestAtomicRetirement = 0
    private(set) var maximumCommittedBatchMilliseconds = 0.0
    private(set) var maximumAtomicUnitMilliseconds = 0.0
    static let maximumAtomicBucketRows = 4_096

    private enum StorageKind { case raw, aggregate, gap }
    private struct StorageMutation {
        let kind: StorageKind
        let id: UUID
        let before: Int
        let after: Int
    }
    private struct AccountingCursor {
        var after: UUID?
        let upperBound: UUID?
        var complete = false
        func hasAccounted(_ id: UUID) -> Bool {
            complete || (upperBound.map { id > $0 } ?? true) || (after.map { id <= $0 } ?? false)
        }
    }
    private final class StorageAccountingProgress {
        var raw: AccountingCursor
        var aggregate: AccountingCursor
        var gap: AccountingCursor
        var rawCount = 0, aggregateCount = 0, gapCount = 0, bytes = 0
        init(raw: UUID?, aggregate: UUID?, gap: UUID?) {
            self.raw = AccountingCursor(upperBound: raw)
            self.aggregate = AccountingCursor(upperBound: aggregate)
            self.gap = AccountingCursor(upperBound: gap)
        }
        func reconcile(_ mutation: StorageMutation) {
            let accounted: Bool
            switch mutation.kind {
            case .raw: accounted = raw.hasAccounted(mutation.id)
            case .aggregate: accounted = aggregate.hasAccounted(mutation.id)
            case .gap: accounted = gap.hasAccounted(mutation.id)
            }
            guard accounted else { return }
            let count = (mutation.after == 0 ? 0 : 1) - (mutation.before == 0 ? 0 : 1)
            switch mutation.kind {
            case .raw: rawCount += count
            case .aggregate: aggregateCount += count
            case .gap: gapCount += count
            }
            bytes += mutation.after - mutation.before
        }
    }



    init(context: ModelContext, clock: any MonitoringClock = SystemMonitoringClock()) {
        self.context = context
        self.clock = clock
    }

    func recordSnapshot(
        _ snapshot: ServerSnapshot,
        serverID: UUID,
        collectorID: String = MonitoringHistoryRepository.collectorID,
        collectorVersion: String = MonitoringHistoryRepository.collectorVersion
    ) throws {
        #if os(macOS)
        defer { rollbackUncommittedChanges() }
        #endif
        let now = clock.now()
        #if os(macOS)
        if snapshot.capturedAt < now.addingTimeInterval(-60),
           try mergeCompactedSnapshot(snapshot, serverID: serverID, collectorID: collectorID,
                                      collectorVersion: collectorVersion, now: now) {
            try closeAllOpenGaps(serverID: serverID, at: snapshot.capturedAt)
            try saveChanges()
            maintenanceRequested?()
            return
        }
        #endif
        let record = try MonitoringSampleRecord(
            serverID: serverID,
            capturedAt: snapshot.capturedAt,
            collectorID: collectorID,
            collectorVersion: collectorVersion,
            quality: .normal,
            sourceDataAge: max(0, now.timeIntervalSince(snapshot.capturedAt)),
            metricValues: Self.metricValues(from: snapshot)
        )
        context.insert(record)
        try closeAllOpenGaps(serverID: serverID, at: snapshot.capturedAt)
        try saveChanges()

        #if os(macOS)
        maintenanceRequested?()
        #else
        if lastMaintenanceAt.map({ now.timeIntervalSince($0) >= 15 * 60 }) ?? true {
            _ = try performMaintenance(policy: .default, now: now)
            lastMaintenanceAt = now
        }
        #endif
    }

    func recordFailure(
        _ error: Error,
        serverID: UUID,
        at date: Date? = nil
    ) throws {
        #if os(macOS)
        defer { rollbackUncommittedChanges() }
        #endif
        let reason = MonitoringGapReason.classify(error)
        let timestamp = date ?? clock.now()
        let open = try openGaps(serverID: serverID)
        for gap in open where gap.reason.isCollectionFailure && gap.reason != reason {
            gap.endedAt = timestamp
        }
        if !open.contains(where: { $0.reason == reason }) {
            context.insert(
                MonitoringGapRecord(
                    serverID: serverID,
                    startedAt: timestamp,
                    reason: reason,
                    collectorID: Self.collectorID,
                    collectorVersion: Self.collectorVersion
                )
            )
        }
        try saveChanges()
    }

    func beginLifecycleGap(
        _ reason: MonitoringGapReason,
        serverIDs: [UUID],
        at date: Date? = nil
    ) throws {
        #if os(macOS)
        defer { rollbackUncommittedChanges() }
        #endif
        precondition(reason.isCollectorSide)
        let timestamp = date ?? clock.now()
        for serverID in serverIDs {
            let open = try openGaps(serverID: serverID)
            guard !open.contains(where: { $0.reason == reason }) else { continue }
            context.insert(
                MonitoringGapRecord(
                    serverID: serverID,
                    startedAt: timestamp,
                    reason: reason,
                    collectorID: Self.collectorID,
                    collectorVersion: Self.collectorVersion
                )
            )
        }
        try saveChanges()
    }

    func endLifecycleGap(
        _ reason: MonitoringGapReason,
        serverIDs: [UUID],
        at date: Date? = nil
    ) throws {
        #if os(macOS)
        defer { rollbackUncommittedChanges() }
        #endif
        let timestamp = date ?? clock.now()
        for serverID in serverIDs {
            for gap in try openGaps(serverID: serverID) where gap.reason == reason {
                gap.endedAt = max(timestamp, gap.startedAt)
            }
        }
        try saveChanges()
    }

    func reconcileStartupGap(
        serverID: UUID,
        lastSuccessfulAt: Date?,
        refreshInterval: TimeInterval,
        at date: Date? = nil
    ) throws {
        let now = date ?? clock.now()
        let openCollectorGaps = try openGaps(serverID: serverID).filter {
            $0.reason == .collectorStopped
        }
        if !openCollectorGaps.isEmpty {
            for gap in openCollectorGaps {
                gap.endedAt = max(now, gap.startedAt)
            }
            try saveChanges()
            return
        }
        guard let lastSuccessfulAt else { return }
        let expectedNext = lastSuccessfulAt.addingTimeInterval(max(5, refreshInterval))
        guard now.timeIntervalSince(expectedNext) > max(15, refreshInterval * 3) else { return }
        context.insert(
            MonitoringGapRecord(
                serverID: serverID,
                startedAt: expectedNext,
                endedAt: now,
                reason: .collectorStopped,
                collectorID: Self.collectorID,
                collectorVersion: Self.collectorVersion
            )
        )
        try saveChanges()
    }

    func recentMetricPoints(serverID: UUID, limit: Int = 120) throws -> [MetricPoint] {
        let requestedID = serverID
        var descriptor = FetchDescriptor<MonitoringSampleRecord>(
            predicate: #Predicate { $0.serverID == requestedID },
            sortBy: [SortDescriptor(\.capturedAt, order: .reverse)]
        )
        descriptor.fetchLimit = max(1, limit)
        return try context.fetch(descriptor).reversed().map { sample in
            let values = sample.metricValues
            return MetricPoint(
                date: sample.capturedAt,
                cpu: values[MonitoringMetric.cpuUsage.rawValue] ?? 0,
                memory: values[MonitoringMetric.memoryUsage.rawValue] ?? 0,
                download: values[MonitoringMetric.downloadBytesPerSecond.rawValue] ?? 0,
                upload: values[MonitoringMetric.uploadBytesPerSecond.rawValue] ?? 0,
                load1: values[MonitoringMetric.load1.rawValue] ?? 0,
                load5: values[MonitoringMetric.load5.rawValue] ?? 0,
                load15: values[MonitoringMetric.load15.rawValue] ?? 0,
                swapUsage: values[MonitoringMetric.swapUsage.rawValue] ?? 0
            )
        }
    }

    func query(
        serverID: UUID,
        metric: MonitoringMetric,
        from start: Date,
        to end: Date,
        pixelWidth: Int
    ) throws -> MonitoringHistorySeries {
        let rangeStart = min(start, end)
        let rangeEnd = max(start, end)
        let resolution = Self.preferredResolution(
            duration: rangeEnd.timeIntervalSince(rangeStart),
            pixelWidth: pixelWidth
        )
        var points = try loadPoints(
            serverID: serverID,
            metric: metric,
            from: rangeStart,
            to: rangeEnd,
            resolution: resolution
        )
        var resolvedResolution = resolution
        if points.isEmpty, resolution != .raw {
            points = try loadPoints(
                serverID: serverID,
                metric: metric,
                from: rangeStart,
                to: rangeEnd,
                resolution: .raw
            )
            resolvedResolution = .raw
        }
        let gaps = try loadGaps(serverID: serverID, from: rangeStart, to: rangeEnd)
        let sourceSegments = Self.segments(points: points, gaps: gaps)
        let rangeDuration = max(1, rangeEnd.timeIntervalSince(rangeStart))
        let downsampledSegments = sourceSegments.map { segment in
            let segmentDuration = max(
                1,
                (segment.last?.date ?? rangeEnd).timeIntervalSince(
                    segment.first?.date ?? rangeStart
                )
            )
            let segmentPixels = max(
                1,
                Int(Double(max(1, pixelWidth)) * segmentDuration / rangeDuration)
            )
            return Self.downsample(
                segment,
                from: rangeStart,
                to: rangeEnd,
                pixelWidth: segmentPixels
            )
        }
        let downsampled = downsampledSegments.flatMap { $0 }
        return MonitoringHistorySeries(
            metric: metric,
            resolution: resolvedResolution,
            points: downsampled,
            segments: downsampledSegments,
            gaps: gaps
        )
    }

    func storageSummary(policy: MonitoringRetentionPolicy = .default) throws -> MonitoringStorageSummary {
        if let cachedStorage { return Self.summary(cachedStorage, quota: policy.diskQuotaBytes) }
        summaryScanCount += 1
        let samples = try context.fetch(FetchDescriptor<MonitoringSampleRecord>())
        let aggregates = try context.fetch(FetchDescriptor<MonitoringAggregateRecord>())
        let gaps = try context.fetch(FetchDescriptor<MonitoringGapRecord>())
        let summary = MonitoringStorageSummary(
            rawSampleCount: samples.count,
            aggregateCount: aggregates.count,
            gapCount: gaps.count,
            estimatedBytes: Self.estimatedBytes(samples: samples, aggregates: aggregates, gaps: gaps),
            quotaBytes: policy.diskQuotaBytes
        )
        cachedStorage = summary
        return summary
    }

    private static func summary(_ value: MonitoringStorageSummary, quota: Int) -> MonitoringStorageSummary {
        MonitoringStorageSummary(rawSampleCount: value.rawSampleCount,
                                 aggregateCount: value.aggregateCount,
                                 gapCount: value.gapCount,
                                 estimatedBytes: value.estimatedBytes, quotaBytes: quota)
    }

    private func saveChanges() throws {
        var rawDelta = 0, aggregateDelta = 0, gapDelta = 0
        var byteDelta = pendingAggregateByteDelta
        var mutations: [StorageMutation] = []
        var rawKeys: Set<AggregateKey> = [], minuteKeys: Set<AggregateKey> = []
        var rawBuckets: Set<Date> = [], minuteBuckets: Set<Date> = []
        for model in context.insertedModelsArray {
            if let sample = model as? MonitoringSampleRecord {
                rawDelta += 1; byteDelta += Self.estimatedBytes(sample: sample)
                mutations.append(StorageMutation(kind: .raw, id: sample.id, before: 0, after: Self.estimatedBytes(sample: sample)))
                let bucket = Self.bucketStart(sample.capturedAt, resolution: .minute)
                rawBuckets.insert(bucket)
                rawKeys.insert(AggregateKey(serverID: sample.serverID, bucketStart: bucket))
            } else if let aggregate = model as? MonitoringAggregateRecord {
                aggregateDelta += 1; byteDelta += Self.estimatedBytes(aggregate: aggregate)
                mutations.append(StorageMutation(kind: .aggregate, id: aggregate.id, before: 0, after: Self.estimatedBytes(aggregate: aggregate)))
                if aggregate.resolution == .minute {
                    let bucket = Self.bucketStart(aggregate.bucketStart, resolution: .quarterHour)
                    minuteBuckets.insert(bucket)
                    minuteKeys.insert(AggregateKey(serverID: aggregate.serverID, bucketStart: bucket))
                }
            } else if let gap = model as? MonitoringGapRecord {
                gapDelta += 1; byteDelta += 224
                mutations.append(StorageMutation(kind: .gap, id: gap.id, before: 0, after: 224))
            }
        }
        for model in context.deletedModelsArray {
            if let sample = model as? MonitoringSampleRecord {
                rawDelta -= 1; byteDelta -= Self.estimatedBytes(sample: sample)
                mutations.append(StorageMutation(kind: .raw, id: sample.id, before: Self.estimatedBytes(sample: sample), after: 0))
                let bucket = Self.bucketStart(sample.capturedAt, resolution: .minute)
                rawBuckets.insert(bucket)
                rawKeys.insert(AggregateKey(serverID: sample.serverID, bucketStart: bucket))
            } else if let aggregate = model as? MonitoringAggregateRecord {
                aggregateDelta -= 1; byteDelta -= Self.estimatedBytes(aggregate: aggregate)
                mutations.append(StorageMutation(kind: .aggregate, id: aggregate.id, before: Self.estimatedBytes(aggregate: aggregate), after: 0))
            } else if let gap = model as? MonitoringGapRecord {
                gapDelta -= 1; byteDelta -= 224
                mutations.append(StorageMutation(kind: .gap, id: gap.id, before: 224, after: 0))
            }
        }
        minuteKeys.formUnion(pendingMinuteKeys)
        for key in pendingMinuteKeys { minuteBuckets.insert(key.bucketStart) }
        for (id, change) in pendingAggregateStorageChanges {
            mutations.append(StorageMutation(kind: .aggregate, id: id, before: change.before, after: change.after))
        }
        do {
            try beforeSave?()
            try context.save()
        } catch {
            context.rollback()
            pendingAggregateByteDelta = 0
            pendingAggregateStorageChanges.removeAll(keepingCapacity: true)
            pendingMinuteKeys.removeAll(keepingCapacity: true)
            throw error
        }
        pendingAggregateByteDelta = 0
        pendingAggregateStorageChanges.removeAll(keepingCapacity: true)
        pendingMinuteKeys.removeAll(keepingCapacity: true)
        for mutation in mutations { accountingProgress?.reconcile(mutation) }
        for key in rawKeys { rawKeyVersions[key, default: 0] += 1 }
        for key in minuteKeys { minuteKeyVersions[key, default: 0] += 1 }
        changedRawKeys.formUnion(rawKeys)
        changedMinuteKeys.formUnion(minuteKeys)
        mutationVersion += 1
        for bucket in rawBuckets { rawBucketVersions[bucket, default: 0] += 1 }
        for bucket in minuteBuckets { minuteBucketVersions[bucket, default: 0] += 1 }
        changedRawBuckets.formUnion(rawBuckets)
        changedMinuteBuckets.formUnion(minuteBuckets)
        if let cachedStorage {
            self.cachedStorage = MonitoringStorageSummary(
                rawSampleCount: cachedStorage.rawSampleCount + rawDelta,
                aggregateCount: cachedStorage.aggregateCount + aggregateDelta,
                gapCount: cachedStorage.gapCount + gapDelta,
                estimatedBytes: cachedStorage.estimatedBytes + byteDelta,
                quotaBytes: cachedStorage.quotaBytes)
        }
    }

    private func noteAggregateChange(_ record: MonitoringAggregateRecord, previousBytes: Int) {
        let current = Self.estimatedBytes(aggregate: record)
        pendingAggregateByteDelta += current - previousBytes
        let original = pendingAggregateStorageChanges[record.id]?.before ?? previousBytes
        pendingAggregateStorageChanges[record.id] = (original, current)
        if record.resolution == .minute {
            pendingMinuteKeys.insert(AggregateKey(serverID: record.serverID,
                bucketStart: Self.bucketStart(record.bucketStart, resolution: .quarterHour)))
        }
    }

    private func fetchHistory<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) throws -> [T] {
        try beforeFetch?()
        return try context.fetch(descriptor)
    }

    private func rollbackUncommittedChanges() {
        guard context.hasChanges else { return }
        // Only the Mac app-owned history context reaches the batching paths. No form context
        // or ServerRecord edits are present, and no uncommitted batch survives a thrown fetch.
        context.rollback()
        pendingAggregateByteDelta = 0
        pendingAggregateStorageChanges.removeAll(keepingCapacity: true)
        pendingMinuteKeys.removeAll(keepingCapacity: true)
        cachedStorage = nil
    }

    func reconcileStartupGaps(_ requests: [MonitoringStartupGapRequest], at date: Date? = nil) throws {
        #if os(macOS)
        defer { rollbackUncommittedChanges() }
        #endif
        let now = date ?? clock.now()
        let reason = MonitoringGapReason.collectorStopped.rawValue
        let open = try context.fetch(FetchDescriptor<MonitoringGapRecord>(
            predicate: #Predicate { $0.endedAt == nil && $0.reasonRawValue == reason }))
        let byServer = Dictionary(grouping: open, by: \.serverID)
        for request in requests {
            if let gaps = byServer[request.serverID], !gaps.isEmpty {
                for gap in gaps { gap.endedAt = max(now, gap.startedAt) }
                continue
            }
            guard let last = request.lastSuccessfulAt else { continue }
            let next = last.addingTimeInterval(max(5, request.refreshInterval))
            guard now.timeIntervalSince(next) > max(15, request.refreshInterval * 3) else { continue }
            context.insert(MonitoringGapRecord(serverID: request.serverID, startedAt: next,
                                               endedAt: now, reason: .collectorStopped,
                                               collectorID: Self.collectorID,
                                               collectorVersion: Self.collectorVersion))
        }
        if context.hasChanges { try saveChanges() }
    }

    func recentMetricPoints(serverIDs: [UUID], limitPerServer: Int = 120) throws -> [UUID: [MetricPoint]] {
        // Per-host limits keep one unusually busy host from consuming another host's history.
        // The caller yields between small batches; every query is bounded by its fetchLimit.
        var result: [UUID: [MetricPoint]] = [:]
        for id in serverIDs { result[id] = try recentMetricPoints(serverID: id, limit: limitPerServer) }
        return result
    }

    @discardableResult
    func performMaintenance(
        policy: MonitoringRetentionPolicy = .default,
        now: Date? = nil
    ) throws -> MonitoringMaintenanceReport {
        #if os(macOS)
        defer { rollbackUncommittedChanges() }
        #endif
        let timestamp = now ?? clock.now()
        let incrementalStart = lastMaintenanceAt?.addingTimeInterval(-120)
        try aggregateRawSamples(
            after: incrementalStart,
            before: timestamp.addingTimeInterval(-60)
        )
        try aggregateMinuteSamples(
            after: incrementalStart?.addingTimeInterval(-900),
            before: timestamp.addingTimeInterval(-900)
        )

        var rawRemoved = 0
        var aggregateRemoved = 0
        var gapsRemoved = 0
        let rawCutoff = timestamp.addingTimeInterval(-policy.rawRetention)
        let minuteCutoff = timestamp.addingTimeInterval(-policy.minuteRetention)
        let quarterCutoff = timestamp.addingTimeInterval(-policy.quarterHourRetention)

        for sample in try context.fetch(FetchDescriptor<MonitoringSampleRecord>())
        where sample.capturedAt < rawCutoff {
            context.delete(sample)
            rawRemoved += 1
        }
        for aggregate in try context.fetch(FetchDescriptor<MonitoringAggregateRecord>()) {
            let cutoff = aggregate.resolution == .minute ? minuteCutoff : quarterCutoff
            if aggregate.bucketEnd < cutoff {
                context.delete(aggregate)
                aggregateRemoved += 1
            }
        }
        for gap in try context.fetch(FetchDescriptor<MonitoringGapRecord>()) {
            if let endedAt = gap.endedAt, endedAt < quarterCutoff {
                context.delete(gap)
                gapsRemoved += 1
            }
        }
        try saveChanges()

        let quotaResult = try enforceQuota(policy.diskQuotaBytes)
        rawRemoved += quotaResult.raw
        aggregateRemoved += quotaResult.aggregates
        let summary = try storageSummary(policy: policy)
        lastMaintenanceAt = timestamp
        return MonitoringMaintenanceReport(
            rawSamplesRemoved: rawRemoved,
            aggregatesRemoved: aggregateRemoved,
            gapsRemoved: gapsRemoved,
            estimatedBytesAfterCleanup: summary.estimatedBytes
        )
    }

    static func preferredResolution(duration: TimeInterval, pixelWidth: Int) -> MonitoringResolution {
        let secondsPerPixel = max(1, duration) / Double(max(1, pixelWidth))
        if secondsPerPixel >= Double(MonitoringResolution.quarterHour.rawValue) {
            return .quarterHour
        }
        if secondsPerPixel >= Double(MonitoringResolution.minute.rawValue) {
            return .minute
        }
        return .raw
    }

    static func downsample(
        _ points: [MonitoringHistoryPoint],
        from start: Date,
        to end: Date,
        pixelWidth: Int
    ) -> [MonitoringHistoryPoint] {
        let targetCount = max(1, pixelWidth)
        guard points.count > targetCount else { return points }
        let duration = max(1, end.timeIntervalSince(start))
        let bucketDuration = duration / Double(targetCount)
        let grouped = Dictionary(grouping: points) { point in
            max(0, min(targetCount - 1, Int(point.date.timeIntervalSince(start) / bucketDuration)))
        }
        return grouped.keys.sorted().compactMap { bucket -> MonitoringHistoryPoint? in
            guard let values = grouped[bucket]?.sorted(by: { $0.date < $1.date }),
                  let first = values.first,
                  let last = values.last else { return nil }
            let count = values.reduce(0) { $0 + $1.sampleCount }
            let weightedTotal = values.reduce(0.0) {
                $0 + $1.average * Double($1.sampleCount)
            }
            return MonitoringHistoryPoint(
                id: "pixel-\(bucket)-\(last.date.timeIntervalSince1970)",
                date: last.date,
                minimum: values.map(\.minimum).min() ?? first.minimum,
                maximum: values.map(\.maximum).max() ?? first.maximum,
                average: count == 0 ? last.average : weightedTotal / Double(count),
                last: last.last,
                sampleCount: count
            )
        }
    }

    static func segments(
        points: [MonitoringHistoryPoint],
        gaps: [MonitoringGapInterval]
    ) -> [[MonitoringHistoryPoint]] {
        guard !points.isEmpty else { return [] }
        var result: [[MonitoringHistoryPoint]] = [[points[0]]]
        for point in points.dropFirst() {
            let previousDate = result[result.count - 1].last?.date ?? point.date
            let crossesGap = gaps.contains { gap in
                gap.start < point.date && gap.end > previousDate
            }
            if crossesGap {
                result.append([point])
            } else {
                result[result.count - 1].append(point)
            }
        }
        return result
    }

    private static func metricValues(from snapshot: ServerSnapshot) -> [String: Double] {
        [
            MonitoringMetric.cpuUsage.rawValue: snapshot.cpuUsage,
            MonitoringMetric.memoryUsage.rawValue: snapshot.memoryUsage,
            MonitoringMetric.load1.rawValue: snapshot.load1,
            MonitoringMetric.load5.rawValue: snapshot.load5,
            MonitoringMetric.load15.rawValue: snapshot.load15,
            MonitoringMetric.swapUsage.rawValue: snapshot.swapUsage,
            MonitoringMetric.diskUsage.rawValue: snapshot.diskUsage,
            MonitoringMetric.downloadBytesPerSecond.rawValue: snapshot.downloadBytesPerSecond,
            MonitoringMetric.uploadBytesPerSecond.rawValue: snapshot.uploadBytesPerSecond
        ]
    }

    private func openGaps(serverID: UUID) throws -> [MonitoringGapRecord] {
        let requestedID = serverID
        return try context.fetch(
            FetchDescriptor<MonitoringGapRecord>(
                predicate: #Predicate {
                    $0.serverID == requestedID && $0.endedAt == nil
                },
                sortBy: [SortDescriptor(\.startedAt)]
            )
        )
    }

    private func closeAllOpenGaps(serverID: UUID, at date: Date) throws {
        for gap in try openGaps(serverID: serverID) {
            gap.endedAt = max(date, gap.startedAt)
        }
    }

    private func loadPoints(
        serverID: UUID,
        metric: MonitoringMetric,
        from start: Date,
        to end: Date,
        resolution: MonitoringResolution
    ) throws -> [MonitoringHistoryPoint] {
        let requestedID = serverID
        if resolution == .raw {
            let records = try context.fetch(
                FetchDescriptor<MonitoringSampleRecord>(
                    predicate: #Predicate {
                        $0.serverID == requestedID &&
                        $0.capturedAt >= start && $0.capturedAt <= end
                    },
                    sortBy: [SortDescriptor(\.capturedAt)]
                )
            )
            return records.compactMap { record in
                guard let value = record.metricValues[metric.rawValue] else { return nil }
                return MonitoringHistoryPoint(
                    id: record.id.uuidString,
                    date: record.capturedAt,
                    minimum: value,
                    maximum: value,
                    average: value,
                    last: value,
                    sampleCount: 1
                )
            }
        }

        let resolutionSeconds = resolution.rawValue
        let records = try context.fetch(
            FetchDescriptor<MonitoringAggregateRecord>(
                predicate: #Predicate {
                    $0.serverID == requestedID &&
                    $0.resolutionSeconds == resolutionSeconds &&
                    $0.bucketEnd >= start && $0.bucketStart <= end
                },
                sortBy: [SortDescriptor(\.bucketStart)]
            )
        )
        return records.compactMap { record in
            guard let statistics = record.statistics[metric.rawValue] else { return nil }
            return MonitoringHistoryPoint(
                id: record.id.uuidString,
                date: record.bucketEnd,
                minimum: statistics.minimum,
                maximum: statistics.maximum,
                average: statistics.average,
                last: statistics.last,
                sampleCount: statistics.sampleCount
            )
        }
    }

    private func loadGaps(
        serverID: UUID,
        from start: Date,
        to end: Date
    ) throws -> [MonitoringGapInterval] {
        let requestedID = serverID
        let records = try context.fetch(
            FetchDescriptor<MonitoringGapRecord>(
                predicate: #Predicate {
                    $0.serverID == requestedID && $0.startedAt <= end
                },
                sortBy: [SortDescriptor(\.startedAt)]
            )
        )
        return records.compactMap { gap in
            let resolvedEnd = gap.endedAt ?? end
            guard resolvedEnd >= start else { return nil }
            return MonitoringGapInterval(
                id: gap.id,
                start: max(start, gap.startedAt),
                end: min(end, max(resolvedEnd, gap.startedAt)),
                reason: gap.reason
            )
        }
    }

    private func aggregateRawSamples(after start: Date?, before end: Date) throws {
        let records: [MonitoringSampleRecord]
        if let start {
            records = try context.fetch(
                FetchDescriptor<MonitoringSampleRecord>(
                    predicate: #Predicate {
                        $0.capturedAt >= start && $0.capturedAt < end
                    },
                    sortBy: [SortDescriptor(\.capturedAt)]
                )
            )
        } else {
            records = try context.fetch(
                FetchDescriptor<MonitoringSampleRecord>(
                    predicate: #Predicate { $0.capturedAt < end },
                    sortBy: [SortDescriptor(\.capturedAt)]
                )
            )
        }
        guard !records.isEmpty else { return }
        var grouped: [AggregateKey: [MonitoringSampleRecord]] = [:]
        for record in records {
            let bucket = Self.bucketStart(record.capturedAt, resolution: .minute)
            grouped[AggregateKey(serverID: record.serverID, bucketStart: bucket), default: []]
                .append(record)
        }
        try upsertAggregates(grouped.mapValues { frames in
            let statistics = Self.statistics(fromSamples: frames)
            return (
                bucketEnd: frames.map(\.capturedAt).max() ?? frames[0].capturedAt,
                collectorID: frames.last?.collectorID ?? Self.collectorID,
                collectorVersion: frames.last?.collectorVersion ?? Self.collectorVersion,
                maximumSourceAge: frames.map(\.sourceDataAge).max() ?? 0,
                statistics: statistics
            )
        }, resolution: .minute)
    }

    private func aggregateMinuteSamples(after start: Date?, before end: Date) throws {
        let minute = MonitoringResolution.minute.rawValue
        let records: [MonitoringAggregateRecord]
        if let start {
            records = try context.fetch(
                FetchDescriptor<MonitoringAggregateRecord>(
                    predicate: #Predicate {
                        $0.resolutionSeconds == minute &&
                        $0.bucketEnd >= start && $0.bucketEnd < end
                    },
                    sortBy: [SortDescriptor(\.bucketStart)]
                )
            )
        } else {
            records = try context.fetch(
                FetchDescriptor<MonitoringAggregateRecord>(
                    predicate: #Predicate {
                        $0.resolutionSeconds == minute && $0.bucketEnd < end
                    },
                    sortBy: [SortDescriptor(\.bucketStart)]
                )
            )
        }
        guard !records.isEmpty else { return }
        var grouped: [AggregateKey: [MonitoringAggregateRecord]] = [:]
        for record in records {
            let bucket = Self.bucketStart(record.bucketStart, resolution: .quarterHour)
            grouped[AggregateKey(serverID: record.serverID, bucketStart: bucket), default: []]
                .append(record)
        }
        try upsertAggregates(grouped.mapValues { frames in
            (
                bucketEnd: frames.map(\.bucketEnd).max() ?? frames[0].bucketEnd,
                collectorID: frames.last?.collectorID ?? Self.collectorID,
                collectorVersion: frames.last?.collectorVersion ?? Self.collectorVersion,
                maximumSourceAge: frames.map(\.maximumSourceDataAge).max() ?? 0,
                statistics: Self.statistics(fromAggregates: frames)
            )
        }, resolution: .quarterHour)
    }

    private func upsertAggregates(
        _ values: [AggregateKey: (
            bucketEnd: Date,
            collectorID: String,
            collectorVersion: String,
            maximumSourceAge: TimeInterval,
            statistics: [String: MonitoringAggregateStatistics]
        )],
        resolution: MonitoringResolution
    ) throws {
        #if os(macOS)
        defer { rollbackUncommittedChanges() }
        #endif
        guard !values.isEmpty else { return }
        let seconds = resolution.rawValue
        let earliestBucket = values.keys.map(\.bucketStart).min() ?? .distantPast
        let existing = try context.fetch(
            FetchDescriptor<MonitoringAggregateRecord>(
                predicate: #Predicate {
                    $0.resolutionSeconds == seconds && $0.bucketStart >= earliestBucket
                }
            )
        )
        var byKey = Dictionary(uniqueKeysWithValues: existing.map {
            (AggregateKey(serverID: $0.serverID, bucketStart: $0.bucketStart), $0)
        })
        for (key, value) in values {
            if let record = byKey[key] {
                let previousBytes = Self.estimatedBytes(aggregate: record)
                try record.replace(
                    bucketEnd: value.bucketEnd,
                    collectorID: value.collectorID,
                    collectorVersion: value.collectorVersion,
                    maximumSourceDataAge: value.maximumSourceAge,
                    statistics: value.statistics
                )
                noteAggregateChange(record, previousBytes: previousBytes)
                if record.resolution == .minute {
                    let bucket = Self.bucketStart(record.bucketStart, resolution: .quarterHour)
                    minuteBucketVersions[bucket, default: 0] += 1
                    changedMinuteBuckets.insert(bucket)
                }
            } else {
                let record = try MonitoringAggregateRecord(
                    serverID: key.serverID,
                    bucketStart: key.bucketStart,
                    bucketEnd: value.bucketEnd,
                    resolution: resolution,
                    collectorID: value.collectorID,
                    collectorVersion: value.collectorVersion,
                    maximumSourceDataAge: value.maximumSourceAge,
                    statistics: value.statistics
                )
                context.insert(record)
                byKey[key] = record
            }
        }
        try saveChanges()
    }

    private func enforceQuota(_ quotaBytes: Int) throws -> (raw: Int, aggregates: Int) {
        let samples = try context.fetch(
            FetchDescriptor<MonitoringSampleRecord>(
                sortBy: [SortDescriptor(\.capturedAt)]
            )
        )
        var aggregates = try context.fetch(
            FetchDescriptor<MonitoringAggregateRecord>(
                sortBy: [SortDescriptor(\.bucketStart)]
            )
        )
        let gaps = try context.fetch(FetchDescriptor<MonitoringGapRecord>())
        var bytes = Self.estimatedBytes(samples: samples, aggregates: aggregates, gaps: gaps)
        var rawRemoved = 0
        var aggregatesRemoved = 0

        for record in samples {
            guard bytes > quotaBytes else { break }
            bytes -= Self.estimatedBytes(sample: record)
            context.delete(record)
            rawRemoved += 1
        }
        // Prefer dropping fine aggregates before the one-year 15-minute context.
        aggregates.sort {
            if $0.resolutionSeconds != $1.resolutionSeconds {
                return $0.resolutionSeconds < $1.resolutionSeconds
            }
            return $0.bucketStart < $1.bucketStart
        }
        for record in aggregates {
            guard bytes > quotaBytes else { break }
            bytes -= Self.estimatedBytes(aggregate: record)
            context.delete(record)
            aggregatesRemoved += 1
        }
        try saveChanges()
        return (rawRemoved, aggregatesRemoved)
    }

    private static func bucketStart(_ date: Date, resolution: MonitoringResolution) -> Date {
        let seconds = TimeInterval(resolution.rawValue)
        return Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / seconds) * seconds)
    }

    private static func statistics(
        fromSamples records: [MonitoringSampleRecord]
    ) -> [String: MonitoringAggregateStatistics] {
        var values: [String: MutableStatistics] = [:]
        for record in records.sorted(by: { $0.capturedAt < $1.capturedAt }) {
            for (metric, value) in record.metricValues {
                if values[metric] == nil {
                    values[metric] = MutableStatistics(value: value)
                } else {
                    values[metric]?.add(value: value)
                }
            }
        }
        return values.mapValues(\.frozen)
    }

    private static func statistics(
        fromAggregates records: [MonitoringAggregateRecord]
    ) -> [String: MonitoringAggregateStatistics] {
        var values: [String: MutableStatistics] = [:]
        for record in records.sorted(by: { $0.bucketStart < $1.bucketStart }) {
            for (metric, statistics) in record.statistics {
                if values[metric] == nil {
                    var initial = MutableStatistics(
                        value: statistics.average,
                        count: statistics.sampleCount
                    )
                    initial.minimum = statistics.minimum
                    initial.maximum = statistics.maximum
                    initial.last = statistics.last
                    values[metric] = initial
                } else {
                    values[metric]?.add(
                        value: statistics.average,
                        count: statistics.sampleCount,
                        minimum: statistics.minimum,
                        maximum: statistics.maximum
                    )
                    values[metric]?.last = statistics.last
                }
            }
        }
        return values.mapValues(\.frozen)
    }

    private static func estimatedBytes(
        samples: [MonitoringSampleRecord],
        aggregates: [MonitoringAggregateRecord],
        gaps: [MonitoringGapRecord]
    ) -> Int {
        samples.reduce(0) { $0 + estimatedBytes(sample: $1) } +
        aggregates.reduce(0) { $0 + estimatedBytes(aggregate: $1) } +
        gaps.count * 224
    }

    private static func estimatedBytes(sample: MonitoringSampleRecord) -> Int {
        192 + sample.metricValuesData.count + sample.collectorID.utf8.count +
        sample.collectorVersion.utf8.count
    }

    private static func estimatedBytes(aggregate: MonitoringAggregateRecord) -> Int {
        224 + aggregate.statisticsData.count + aggregate.collectorID.utf8.count +
        aggregate.collectorVersion.utf8.count
    }
}

#if os(macOS)
extension MonitoringHistoryRepository {
    /// UUID keyset pages have a fixed upper bound. Successful commits reconcile only records
    /// already behind each cursor (or beyond that fixed bound); upcoming pages read the latest
    /// values for all other records. Collection therefore never restarts this initialization.
    func prepareStorageSummary(batchSize: Int = 512) async throws {
        guard cachedStorage == nil else { return }
        let limit = max(1, batchSize)
        var rawLast = FetchDescriptor<MonitoringSampleRecord>(sortBy: [SortDescriptor(\.id, order: .reverse)])
        rawLast.fetchLimit = 1
        var aggregateLast = FetchDescriptor<MonitoringAggregateRecord>(sortBy: [SortDescriptor(\.id, order: .reverse)])
        aggregateLast.fetchLimit = 1
        var gapLast = FetchDescriptor<MonitoringGapRecord>(sortBy: [SortDescriptor(\.id, order: .reverse)])
        gapLast.fetchLimit = 1
        let progress = StorageAccountingProgress(raw: try fetchHistory(rawLast).first?.id,
            aggregate: try fetchHistory(aggregateLast).first?.id, gap: try fetchHistory(gapLast).first?.id)
        accountingProgress = progress
        defer { accountingProgress = nil }
        if let upper = progress.raw.upperBound {
            while true {
                try Task.checkCancellation()
                var descriptor: FetchDescriptor<MonitoringSampleRecord>
                if let after = progress.raw.after {
                    descriptor = FetchDescriptor(predicate: #Predicate { $0.id > after && $0.id <= upper }, sortBy: [SortDescriptor(\.id)])
                } else {
                    descriptor = FetchDescriptor(predicate: #Predicate { $0.id <= upper }, sortBy: [SortDescriptor(\.id)])
                }
                descriptor.fetchLimit = limit
                let page = try fetchHistory(descriptor)
                progress.rawCount += page.count
                progress.bytes += page.reduce(0) { $0 + Self.estimatedBytes(sample: $1) }
                progress.raw.after = page.last?.id ?? progress.raw.after
                if page.count < limit { break }
                await Task.yield()
            }
        }
        progress.raw.complete = true
        if let upper = progress.aggregate.upperBound {
            while true {
                try Task.checkCancellation()
                var descriptor: FetchDescriptor<MonitoringAggregateRecord>
                if let after = progress.aggregate.after {
                    descriptor = FetchDescriptor(predicate: #Predicate { $0.id > after && $0.id <= upper }, sortBy: [SortDescriptor(\.id)])
                } else {
                    descriptor = FetchDescriptor(predicate: #Predicate { $0.id <= upper }, sortBy: [SortDescriptor(\.id)])
                }
                descriptor.fetchLimit = limit
                let page = try fetchHistory(descriptor)
                progress.aggregateCount += page.count
                progress.bytes += page.reduce(0) { $0 + Self.estimatedBytes(aggregate: $1) }
                progress.aggregate.after = page.last?.id ?? progress.aggregate.after
                if page.count < limit { break }
                await Task.yield()
            }
        }
        progress.aggregate.complete = true
        if let upper = progress.gap.upperBound {
            while true {
                try Task.checkCancellation()
                var descriptor: FetchDescriptor<MonitoringGapRecord>
                if let after = progress.gap.after {
                    descriptor = FetchDescriptor(predicate: #Predicate { $0.id > after && $0.id <= upper }, sortBy: [SortDescriptor(\.id)])
                } else {
                    descriptor = FetchDescriptor(predicate: #Predicate { $0.id <= upper }, sortBy: [SortDescriptor(\.id)])
                }
                descriptor.fetchLimit = limit
                let page = try fetchHistory(descriptor)
                progress.gapCount += page.count
                progress.bytes += page.count * 224
                progress.gap.after = page.last?.id ?? progress.gap.after
                if page.count < limit { break }
                await Task.yield()
            }
        }
        progress.gap.complete = true
        try Task.checkCancellation()
        summaryScanCount += 1
        cachedStorage = MonitoringStorageSummary(rawSampleCount: progress.rawCount,
            aggregateCount: progress.aggregateCount, gapCount: progress.gapCount,
            estimatedBytes: progress.bytes, quotaBytes: MonitoringRetentionPolicy.default.diskQuotaBytes)
    }

    /// A round uses one fixed cutoff. A bucket is read completely before its aggregate is
    /// committed. Source retirement is a single transaction per complete bucket, so cancelling
    /// between commits can never leave a partial source bucket that overwrites a full aggregate.
    func performBatchedMaintenance(
        policy: MonitoringRetentionPolicy = .default,
        now: Date? = nil,
        batchSize: Int = 512
    ) async throws -> MonitoringMaintenanceReport {
        let timestamp = now ?? clock.now()
        let size = max(1, batchSize)
        let minuteEnd = Self.bucketStart(timestamp, resolution: .minute)
        let quarterEnd = Self.bucketStart(timestamp, resolution: .quarterHour)
        let rawCutoff = Self.bucketStart(timestamp.addingTimeInterval(-policy.rawRetention), resolution: .minute)
        let minuteCutoff = Self.bucketStart(timestamp.addingTimeInterval(-policy.minuteRetention), resolution: .quarterHour)
        let quarterCutoff = timestamp.addingTimeInterval(-policy.quarterHourRetention)
        var rawRemoved = 0, aggregateRemoved = 0, gapsRemoved = 0
        try await prepareStorageSummary(batchSize: size)

        do {
            var cursor = completedBatchedMaintenance
                ? Self.bucketStart(lastMaintenanceAt ?? .distantPast, resolution: .minute) : .distantPast
            while let bucket = try nextRawBucket(from: cursor, before: minuteEnd) {
                try Task.checkCancellation()
                rawRemoved += try await aggregateRawBucket(bucket, batchSize: size,
                    retire: bucket.addingTimeInterval(60) <= rawCutoff)
                refreshDirtyRawBucket(bucket)
                cursor = bucket.addingTimeInterval(60)
                await Task.yield()
            }
        }
        do {
            for bucket in changedRawBuckets.filter({ $0 < minuteEnd }).sorted() {
                try Task.checkCancellation()
                rawRemoved += try await aggregateRawBucket(bucket, batchSize: size,
                    retire: bucket.addingTimeInterval(60) <= rawCutoff)
                refreshDirtyRawBucket(bucket)
                await Task.yield()
            }
        }
        // Retention can advance without any new sample in an old bucket.
        while let bucket = try nextRawBucket(from: .distantPast, before: rawCutoff) {
            try Task.checkCancellation()
            rawRemoved += try await aggregateRawBucket(bucket, batchSize: size, retire: true)
            refreshDirtyRawBucket(bucket)
            await Task.yield()
        }

        do {
            var cursor = completedBatchedMaintenance
                ? Self.bucketStart(lastMaintenanceAt ?? .distantPast, resolution: .quarterHour) : .distantPast
            while let bucket = try nextMinuteBucket(from: cursor, before: quarterEnd) {
                try Task.checkCancellation()
                aggregateRemoved += try await aggregateQuarterBucket(bucket, batchSize: size,
                    retire: bucket.addingTimeInterval(900) <= minuteCutoff)
                refreshDirtyMinuteBucket(bucket)
                cursor = bucket.addingTimeInterval(900)
                await Task.yield()
            }
        }
        do {
            for bucket in changedMinuteBuckets.filter({ $0 < quarterEnd }).sorted() {
                try Task.checkCancellation()
                aggregateRemoved += try await aggregateQuarterBucket(bucket, batchSize: size,
                    retire: bucket.addingTimeInterval(900) <= minuteCutoff)
                refreshDirtyMinuteBucket(bucket)
                await Task.yield()
            }
        }
        while let bucket = try nextMinuteBucket(from: .distantPast, before: minuteCutoff) {
            try Task.checkCancellation()
            aggregateRemoved += try await aggregateQuarterBucket(bucket, batchSize: size, retire: true)
            refreshDirtyMinuteBucket(bucket)
            await Task.yield()
        }

        let quarter = MonitoringResolution.quarterHour.rawValue
        var expiredAggregates = FetchDescriptor<MonitoringAggregateRecord>(
            predicate: #Predicate { $0.resolutionSeconds == quarter && $0.bucketEnd < quarterCutoff },
            sortBy: [SortDescriptor(\.bucketStart)])
        expiredAggregates.fetchLimit = size
        while true {
            try Task.checkCancellation()
            let page = try context.fetch(expiredAggregates)
            guard !page.isEmpty else { break }
            for record in page { context.delete(record) }
            try commitBatch()
            aggregateRemoved += page.count
            await Task.yield()
        }
        let future = Date.distantFuture
        var expiredGaps = FetchDescriptor<MonitoringGapRecord>(
            predicate: #Predicate { ($0.endedAt ?? future) < quarterCutoff },
            sortBy: [SortDescriptor(\.startedAt)])
        expiredGaps.fetchLimit = size
        while true {
            try Task.checkCancellation()
            let page = try context.fetch(expiredGaps)
            guard !page.isEmpty else { break }
            for record in page { context.delete(record) }
            try commitBatch()
            gapsRemoved += page.count
            await Task.yield()
        }

        while try storageSummary(policy: policy).estimatedBytes > max(0, policy.diskQuotaBytes),
              let bucket = try nextRawBucket(from: .distantPast, before: minuteEnd) {
            try Task.checkCancellation()
            rawRemoved += try await aggregateRawBucket(bucket, batchSize: size, retire: true)
            refreshDirtyRawBucket(bucket)
            // Preserve the parent before quota can remove the fine aggregate.
            let parent = Self.bucketStart(bucket, resolution: .quarterHour)
            if parent < quarterEnd { _ = try await aggregateQuarterBucket(parent, batchSize: size) }
            await Task.yield()
        }
        // Evict complete fine-source groups. Removing only a page of a quarter would make a
        // later recomputation overwrite the complete parent with the remaining partial source.
        while try storageSummary(policy: policy).estimatedBytes > max(0, policy.diskQuotaBytes),
              let parent = try nextMinuteBucket(from: .distantPast, before: quarterEnd) {
            try Task.checkCancellation()
            aggregateRemoved += try await aggregateQuarterBucket(parent, batchSize: size, retire: true)
            refreshDirtyMinuteBucket(parent)
            await Task.yield()
        }
        var oldestAggregates = FetchDescriptor<MonitoringAggregateRecord>(
            predicate: #Predicate { $0.resolutionSeconds == quarter },
            sortBy: [SortDescriptor(\.bucketStart)])
        oldestAggregates.fetchLimit = size
        while try storageSummary(policy: policy).estimatedBytes > max(0, policy.diskQuotaBytes) {
            try Task.checkCancellation()
            let page = try context.fetch(oldestAggregates)
            guard !page.isEmpty else { break }
            var bytes = try storageSummary(policy: policy).estimatedBytes
            var removed = 0
            for record in page where bytes > max(0, policy.diskQuotaBytes) {
                bytes -= Self.estimatedBytes(aggregate: record)
                context.delete(record)
                removed += 1
            }
            try commitBatch()
            aggregateRemoved += removed
            await Task.yield()
        }
        try Task.checkCancellation()
        completedBatchedMaintenance = true
        lastMaintenanceAt = timestamp
        return MonitoringMaintenanceReport(rawSamplesRemoved: rawRemoved,
            aggregatesRemoved: aggregateRemoved, gapsRemoved: gapsRemoved,
            estimatedBytesAfterCleanup: try storageSummary(policy: policy).estimatedBytes)
    }

    private func nextRawBucket(from start: Date, before end: Date) throws -> Date? {
        var descriptor = FetchDescriptor<MonitoringSampleRecord>(
            predicate: #Predicate { $0.capturedAt >= start && $0.capturedAt < end },
            sortBy: [SortDescriptor(\.capturedAt)])
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first.map { Self.bucketStart($0.capturedAt, resolution: .minute) }
    }

    private func nextMinuteBucket(from start: Date, before end: Date) throws -> Date? {
        let minute = MonitoringResolution.minute.rawValue
        var descriptor = FetchDescriptor<MonitoringAggregateRecord>(
            predicate: #Predicate { $0.resolutionSeconds == minute && $0.bucketStart >= start && $0.bucketStart < end },
            sortBy: [SortDescriptor(\.bucketStart)])
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first.map { Self.bucketStart($0.bucketStart, resolution: .quarterHour) }
    }

    private struct BucketAccumulator {
        var statistics: [String: MutableStatistics] = [:]
        var metricDates: [String: Date] = [:]
        var lastDate = Date.distantPast
        var collectorID = MonitoringHistoryRepository.collectorID
        var collectorVersion = MonitoringHistoryRepository.collectorVersion
        var maximumSourceAge: TimeInterval = 0

        mutating func add(_ values: [String: MonitoringAggregateStatistics], date: Date,
                          collector: String, version: String, sourceAge: TimeInterval) {
            for (metric, value) in values {
                if statistics[metric] == nil {
                    var initial = MutableStatistics(value: value.average, count: value.sampleCount)
                    initial.minimum = value.minimum; initial.maximum = value.maximum; initial.last = value.last
                    statistics[metric] = initial
                    metricDates[metric] = date
                } else {
                    let previousLast = statistics[metric]?.last
                    statistics[metric]?.add(value: value.average, count: value.sampleCount,
                                            minimum: value.minimum, maximum: value.maximum)
                    if date >= metricDates[metric, default: .distantPast] {
                        statistics[metric]?.last = value.last
                        metricDates[metric] = date
                    } else if let previousLast { statistics[metric]?.last = previousLast }
                }
            }
            if date >= lastDate { collectorID = collector; collectorVersion = version; lastDate = date }
            maximumSourceAge = max(maximumSourceAge, sourceAge)
        }
    }

    private enum MaintenanceError: Error { case atomicBucketRowLimitExceeded, bucketChangedContinuously, missingRetirementSource }

    private func refreshDirtyRawBucket(_ start: Date) {
        if changedRawKeys.contains(where: { $0.bucketStart == start }) { changedRawBuckets.insert(start) }
        else { changedRawBuckets.remove(start) }
        rawBucketVersions.removeValue(forKey: start)
    }

    private func refreshDirtyMinuteBucket(_ start: Date) {
        if changedMinuteKeys.contains(where: { $0.bucketStart == start }) { changedMinuteBuckets.insert(start) }
        else { changedMinuteBuckets.remove(start) }
        minuteBucketVersions.removeValue(forKey: start)
    }

    /// Enumerate server IDs with bounded keyset pages, then commit each server independently.
    /// A thousand hosts sharing a timestamp never become one MainActor transaction.
    private func aggregateRawBucket(_ start: Date, batchSize: Int, retire: Bool = false) async throws -> Int {
        let end = start.addingTimeInterval(60)
        var cursor: UUID?
        var servers: Set<UUID> = []
        let initialVersions = rawKeyVersions
        var projected: [UUID: BucketAccumulator] = [:]
        var sourceIDs: [UUID: [UUID]] = [:]
        while true {
            try Task.checkCancellation()
            var descriptor: FetchDescriptor<MonitoringSampleRecord>
            if let cursor {
                descriptor = FetchDescriptor(predicate: #Predicate {
                    $0.capturedAt >= start && $0.capturedAt < end && $0.id > cursor
                }, sortBy: [SortDescriptor(\.id)])
            } else {
                descriptor = FetchDescriptor(predicate: #Predicate {
                    $0.capturedAt >= start && $0.capturedAt < end
                }, sortBy: [SortDescriptor(\.id)])
            }
            descriptor.fetchLimit = batchSize
            let page = try fetchHistory(descriptor)
            servers.formUnion(page.map(\.serverID))
            for sample in page {
                projected[sample.serverID, default: BucketAccumulator()].add(sample.metricValues.mapValues {
                    MonitoringAggregateStatistics(minimum: $0, maximum: $0, average: $0, last: $0, sampleCount: 1)
                }, date: sample.capturedAt, collector: sample.collectorID,
                   version: sample.collectorVersion, sourceAge: sample.sourceDataAge)
                sourceIDs[sample.serverID, default: []].append(sample.id)
            }
            cursor = page.last?.id ?? cursor
            if page.count < batchSize { break }
            await Task.yield()
        }
        servers.formUnion(changedRawKeys.filter { $0.bucketStart == start }.map(\.serverID))
        let existingIDs = try await existingAggregateIDs(start: start, resolution: .minute, batchSize: batchSize)
        var removed = 0
        for server in servers.sorted() {
            try Task.checkCancellation()
            let key = AggregateKey(serverID: server, bucketStart: start)
            var retries = 0
            while true {
                let version = rawKeyVersions[key, default: 0]
                let reusable = version == initialVersions[key, default: 0]
                var projection = reusable ? (projected[server] ?? BucketAccumulator()) : BucketAccumulator()
                var ids = reusable ? (sourceIDs[server] ?? []) : []
                var after: UUID?
                var hasRows = !ids.isEmpty
                while !reusable {
                    try Task.checkCancellation()
                    var descriptor: FetchDescriptor<MonitoringSampleRecord>
                    if let after {
                        descriptor = FetchDescriptor(predicate: #Predicate {
                            $0.serverID == server && $0.capturedAt >= start && $0.capturedAt < end && $0.id > after
                        }, sortBy: [SortDescriptor(\.id)])
                    } else {
                        descriptor = FetchDescriptor(predicate: #Predicate {
                            $0.serverID == server && $0.capturedAt >= start && $0.capturedAt < end
                        }, sortBy: [SortDescriptor(\.id)])
                    }
                    descriptor.fetchLimit = batchSize
                    let interval = PerformanceTrace.begin(.historyBatch)
                    let page: [MonitoringSampleRecord]
                    do { page = try fetchHistory(descriptor) }
                    catch { PerformanceTrace.end(interval); throw error }
                    for sample in page {
                        ids.append(sample.id)
                        projection.add(sample.metricValues.mapValues {
                            MonitoringAggregateStatistics(minimum: $0, maximum: $0, average: $0, last: $0, sampleCount: 1)
                        }, date: sample.capturedAt, collector: sample.collectorID,
                           version: sample.collectorVersion, sourceAge: sample.sourceDataAge)
                    }
                    PerformanceTrace.end(interval)
                    hasRows = hasRows || !page.isEmpty
                    after = page.last?.id ?? after
                    if page.count < batchSize { break }
                    await Task.yield()
                    if rawKeyVersions[key, default: 0] != version { break }
                }
                if rawKeyVersions[key, default: 0] != version {
                    retries += 1
                    guard retries < 3 else { throw MaintenanceError.bucketChangedContinuously }
                    continue
                }
                if hasRows {
                    if retire, ids.count > Self.maximumAtomicBucketRows { throw MaintenanceError.atomicBucketRowLimitExceeded }
                    let began = ContinuousClock.now
                    try storeSingleBucket(projection, server: server, start: start, resolution: .minute,
                                          existingID: existingIDs[server])
                    if retire { removed += try retireRawIDs(ids, batchSize: batchSize) }
                    recordAtomicUnitDuration(since: began)
                }
                changedRawKeys.remove(key)
                rawKeyVersions.removeValue(forKey: key)
                break
            }
            await Task.yield()
        }
        return removed
    }

    private func aggregateQuarterBucket(_ start: Date, batchSize: Int, retire: Bool = false) async throws -> Int {
        let end = start.addingTimeInterval(900)
        let minute = MonitoringResolution.minute.rawValue
        var cursor: UUID?
        var servers: Set<UUID> = []
        let initialVersions = minuteKeyVersions
        var projected: [UUID: BucketAccumulator] = [:]
        var sourceIDs: [UUID: [UUID]] = [:]
        while true {
            try Task.checkCancellation()
            var descriptor: FetchDescriptor<MonitoringAggregateRecord>
            if let cursor {
                descriptor = FetchDescriptor(predicate: #Predicate {
                    $0.resolutionSeconds == minute && $0.bucketStart >= start && $0.bucketStart < end && $0.id > cursor
                }, sortBy: [SortDescriptor(\.id)])
            } else {
                descriptor = FetchDescriptor(predicate: #Predicate {
                    $0.resolutionSeconds == minute && $0.bucketStart >= start && $0.bucketStart < end
                }, sortBy: [SortDescriptor(\.id)])
            }
            descriptor.fetchLimit = batchSize
            let page = try fetchHistory(descriptor)
            servers.formUnion(page.map(\.serverID))
            for frame in page {
                projected[frame.serverID, default: BucketAccumulator()].add(frame.statistics,
                    date: frame.bucketEnd, collector: frame.collectorID,
                    version: frame.collectorVersion, sourceAge: frame.maximumSourceDataAge)
                sourceIDs[frame.serverID, default: []].append(frame.id)
            }
            cursor = page.last?.id ?? cursor
            if page.count < batchSize { break }
            await Task.yield()
        }
        servers.formUnion(changedMinuteKeys.filter { $0.bucketStart == start }.map(\.serverID))
        let existingIDs = try await existingAggregateIDs(start: start, resolution: .quarterHour, batchSize: batchSize)
        var removed = 0
        for server in servers.sorted() {
            try Task.checkCancellation()
            let key = AggregateKey(serverID: server, bucketStart: start)
            var retries = 0
            while true {
                let version = minuteKeyVersions[key, default: 0]
                let reusable = version == initialVersions[key, default: 0]
                var projection = reusable ? (projected[server] ?? BucketAccumulator()) : BucketAccumulator()
                var ids = reusable ? (sourceIDs[server] ?? []) : []
                var after: UUID?
                var hasRows = !ids.isEmpty
                while !reusable {
                    try Task.checkCancellation()
                    var descriptor: FetchDescriptor<MonitoringAggregateRecord>
                    if let after {
                        descriptor = FetchDescriptor(predicate: #Predicate {
                            $0.serverID == server && $0.resolutionSeconds == minute &&
                            $0.bucketStart >= start && $0.bucketStart < end && $0.id > after
                        }, sortBy: [SortDescriptor(\.id)])
                    } else {
                        descriptor = FetchDescriptor(predicate: #Predicate {
                            $0.serverID == server && $0.resolutionSeconds == minute && $0.bucketStart >= start && $0.bucketStart < end
                        }, sortBy: [SortDescriptor(\.id)])
                    }
                    descriptor.fetchLimit = batchSize
                    let page = try fetchHistory(descriptor)
                    for frame in page {
                        ids.append(frame.id)
                        projection.add(frame.statistics, date: frame.bucketEnd,
                            collector: frame.collectorID, version: frame.collectorVersion,
                            sourceAge: frame.maximumSourceDataAge)
                    }
                    hasRows = hasRows || !page.isEmpty
                    after = page.last?.id ?? after
                    if page.count < batchSize { break }
                    await Task.yield()
                    if minuteKeyVersions[key, default: 0] != version { break }
                }
                if minuteKeyVersions[key, default: 0] != version {
                    retries += 1
                    guard retries < 3 else { throw MaintenanceError.bucketChangedContinuously }
                    continue
                }
                if hasRows {
                    if retire, ids.count > Self.maximumAtomicBucketRows { throw MaintenanceError.atomicBucketRowLimitExceeded }
                    let began = ContinuousClock.now
                    try storeSingleBucket(projection, server: server, start: start, resolution: .quarterHour,
                                          existingID: existingIDs[server])
                    if retire { removed += try retireMinuteIDs(ids, batchSize: batchSize) }
                    recordAtomicUnitDuration(since: began)
                }
                changedMinuteKeys.remove(key)
                minuteKeyVersions.removeValue(forKey: key)
                break
            }
            await Task.yield()
        }
        return removed
    }

    private func existingAggregateIDs(start: Date, resolution: MonitoringResolution, batchSize: Int) async throws -> [UUID: UUID] {
        let seconds = resolution.rawValue
        var cursor: UUID?
        var result: [UUID: UUID] = [:]
        while true {
            try Task.checkCancellation()
            var descriptor: FetchDescriptor<MonitoringAggregateRecord>
            if let cursor {
                descriptor = FetchDescriptor(predicate: #Predicate {
                    $0.resolutionSeconds == seconds && $0.bucketStart == start && $0.id > cursor
                }, sortBy: [SortDescriptor(\.id)])
            } else {
                descriptor = FetchDescriptor(predicate: #Predicate {
                    $0.resolutionSeconds == seconds && $0.bucketStart == start
                }, sortBy: [SortDescriptor(\.id)])
            }
            descriptor.fetchLimit = batchSize
            let page = try fetchHistory(descriptor)
            for record in page { result[record.serverID] = record.id }
            cursor = page.last?.id ?? cursor
            if page.count < batchSize { break }
            await Task.yield()
        }
        return result
    }

    private func storeSingleBucket(_ value: BucketAccumulator, server: UUID, start: Date,
                                   resolution: MonitoringResolution, existingID: UUID?) throws {
        defer { rollbackUncommittedChanges() }
        let existing: MonitoringAggregateRecord?
        if let existingID {
            var descriptor = FetchDescriptor<MonitoringAggregateRecord>(predicate: #Predicate { $0.id == existingID })
            descriptor.fetchLimit = 1
            existing = try fetchHistory(descriptor).first
        } else { existing = nil }
        try beforeAggregateEncoding?()
        if let record = existing {
            let bytes = Self.estimatedBytes(aggregate: record)
            try record.replace(bucketEnd: value.lastDate, collectorID: value.collectorID,
                collectorVersion: value.collectorVersion, maximumSourceDataAge: value.maximumSourceAge,
                statistics: value.statistics.mapValues(\.frozen))
            noteAggregateChange(record, previousBytes: bytes)
        } else {
            context.insert(try MonitoringAggregateRecord(serverID: server, bucketStart: start,
                bucketEnd: value.lastDate, resolution: resolution, collectorID: value.collectorID,
                collectorVersion: value.collectorVersion, maximumSourceDataAge: value.maximumSourceAge,
                statistics: value.statistics.mapValues(\.frozen)))
        }
        try commitBatch()
    }

    private func retireRawIDs(_ ids: [UUID], batchSize: Int) throws -> Int {
        defer { rollbackUncommittedChanges() }
        guard ids.count <= Self.maximumAtomicBucketRows else { throw MaintenanceError.atomicBucketRowLimitExceeded }
        for offset in stride(from: 0, to: ids.count, by: batchSize) {
            let batch = Array(ids[offset..<min(ids.count, offset + batchSize)])
            var descriptor = FetchDescriptor<MonitoringSampleRecord>(predicate: #Predicate { batch.contains($0.id) })
            descriptor.fetchLimit = batch.count
            descriptor.includePendingChanges = false
            let page = try fetchHistory(descriptor)
            guard page.count == batch.count else { throw MaintenanceError.missingRetirementSource }
            for record in page { context.delete(record) }
        }
        if !ids.isEmpty { try commitBatch() }
        largestAtomicRetirement = max(largestAtomicRetirement, ids.count)
        return ids.count
    }

    private func retireMinuteIDs(_ ids: [UUID], batchSize: Int) throws -> Int {
        defer { rollbackUncommittedChanges() }
        guard ids.count <= Self.maximumAtomicBucketRows else { throw MaintenanceError.atomicBucketRowLimitExceeded }
        for offset in stride(from: 0, to: ids.count, by: batchSize) {
            let batch = Array(ids[offset..<min(ids.count, offset + batchSize)])
            var descriptor = FetchDescriptor<MonitoringAggregateRecord>(predicate: #Predicate { batch.contains($0.id) })
            descriptor.fetchLimit = batch.count
            descriptor.includePendingChanges = false
            let page = try fetchHistory(descriptor)
            guard page.count == batch.count else { throw MaintenanceError.missingRetirementSource }
            for record in page { context.delete(record) }
        }
        if !ids.isEmpty { try commitBatch() }
        largestAtomicRetirement = max(largestAtomicRetirement, ids.count)
        return ids.count
    }

    /// A source bucket is always retired in full. If a delayed snapshot arrives after that
    /// retirement, fold it into the retained aggregate directly instead of recreating a partial
    /// source bucket. The aggregate update and gap closure commit in the caller's transaction.
    private func mergeCompactedSnapshot(
        _ snapshot: ServerSnapshot, serverID: UUID, collectorID: String,
        collectorVersion: String, now: Date
    ) throws -> Bool {
        let start = Self.bucketStart(snapshot.capturedAt, resolution: .minute)
        let end = start.addingTimeInterval(60)
        var raw = FetchDescriptor<MonitoringSampleRecord>(predicate: #Predicate {
            $0.serverID == serverID && $0.capturedAt >= start && $0.capturedAt < end
        })
        raw.fetchLimit = 1
        guard try context.fetch(raw).isEmpty else { return false }
        let minute = MonitoringResolution.minute.rawValue
        var fine = FetchDescriptor<MonitoringAggregateRecord>(predicate: #Predicate {
            $0.serverID == serverID && $0.resolutionSeconds == minute && $0.bucketStart == start
        })
        fine.fetchLimit = 1
        var record = try context.fetch(fine).first
        if record == nil {
            let parent = Self.bucketStart(start, resolution: .quarterHour)
            let parentEnd = parent.addingTimeInterval(900)
            // A previously unseen minute inside a still-retained quarter is new source data,
            // not evidence of compaction. Keep it raw so later parent recomputation retains it.
            var retainedMinutes = FetchDescriptor<MonitoringAggregateRecord>(predicate: #Predicate {
                $0.serverID == serverID && $0.resolutionSeconds == minute &&
                $0.bucketStart >= parent && $0.bucketStart < parentEnd
            })
            retainedMinutes.fetchLimit = 1
            guard try context.fetch(retainedMinutes).isEmpty else { return false }
            let quarter = MonitoringResolution.quarterHour.rawValue
            var coarse = FetchDescriptor<MonitoringAggregateRecord>(predicate: #Predicate {
                $0.serverID == serverID && $0.resolutionSeconds == quarter && $0.bucketStart == parent
            })
            coarse.fetchLimit = 1
            record = try context.fetch(coarse).first
        }
        guard let record else { return false }
        var statistics = record.statistics
        for (metric, value) in Self.metricValues(from: snapshot) {
            if let previous = statistics[metric] {
                let count = previous.sampleCount + 1
                statistics[metric] = MonitoringAggregateStatistics(
                    minimum: min(previous.minimum, value), maximum: max(previous.maximum, value),
                    average: (previous.average * Double(previous.sampleCount) + value) / Double(count),
                    last: snapshot.capturedAt >= record.bucketEnd ? value : previous.last,
                    sampleCount: count)
            } else {
                statistics[metric] = MonitoringAggregateStatistics(
                    minimum: value, maximum: value, average: value, last: value, sampleCount: 1)
            }
        }
        let bytes = Self.estimatedBytes(aggregate: record)
        let newer = snapshot.capturedAt >= record.bucketEnd
        try record.replace(bucketEnd: max(record.bucketEnd, snapshot.capturedAt),
            collectorID: newer ? collectorID : record.collectorID,
            collectorVersion: newer ? collectorVersion : record.collectorVersion,
            maximumSourceDataAge: max(record.maximumSourceDataAge, now.timeIntervalSince(snapshot.capturedAt)),
            statistics: statistics)
        noteAggregateChange(record, previousBytes: bytes)
        if record.resolution == .minute {
            let parent = Self.bucketStart(start, resolution: .quarterHour)
            minuteBucketVersions[parent, default: 0] += 1
            changedMinuteBuckets.insert(parent)
        }
        return true
    }

    private func recordAtomicUnitDuration(since start: ContinuousClock.Instant) {
        let duration = start.duration(to: .now).components
        let milliseconds = Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
        maximumAtomicUnitMilliseconds = max(maximumAtomicUnitMilliseconds, milliseconds)
    }

    private func commitBatch() throws {
        let interval = PerformanceTrace.begin(.historyBatch)
        let began = ContinuousClock.now
        defer {
            PerformanceTrace.end(interval)
            let duration = began.duration(to: .now).components
            let milliseconds = Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
            maximumCommittedBatchMilliseconds = max(maximumCommittedBatchMilliseconds, milliseconds)
        }
        try saveChanges()
        maintenanceBatchCount += 1
    }
}
#endif
