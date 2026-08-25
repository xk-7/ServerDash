import Foundation
import SwiftData

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
        case .timeout:
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
        let now = clock.now()
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
        try context.save()

        if lastMaintenanceAt.map({ now.timeIntervalSince($0) >= 15 * 60 }) ?? true {
            _ = try performMaintenance(policy: .default, now: now)
            lastMaintenanceAt = now
        }
    }

    func recordFailure(
        _ error: Error,
        serverID: UUID,
        at date: Date? = nil
    ) throws {
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
        try context.save()
    }

    func beginLifecycleGap(
        _ reason: MonitoringGapReason,
        serverIDs: [UUID],
        at date: Date? = nil
    ) throws {
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
        try context.save()
    }

    func endLifecycleGap(
        _ reason: MonitoringGapReason,
        serverIDs: [UUID],
        at date: Date? = nil
    ) throws {
        let timestamp = date ?? clock.now()
        for serverID in serverIDs {
            for gap in try openGaps(serverID: serverID) where gap.reason == reason {
                gap.endedAt = max(timestamp, gap.startedAt)
            }
        }
        try context.save()
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
            try context.save()
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
        try context.save()
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
        let samples = try context.fetch(FetchDescriptor<MonitoringSampleRecord>())
        let aggregates = try context.fetch(FetchDescriptor<MonitoringAggregateRecord>())
        let gaps = try context.fetch(FetchDescriptor<MonitoringGapRecord>())
        return MonitoringStorageSummary(
            rawSampleCount: samples.count,
            aggregateCount: aggregates.count,
            gapCount: gaps.count,
            estimatedBytes: Self.estimatedBytes(samples: samples, aggregates: aggregates, gaps: gaps),
            quotaBytes: policy.diskQuotaBytes
        )
    }

    @discardableResult
    func performMaintenance(
        policy: MonitoringRetentionPolicy = .default,
        now: Date? = nil
    ) throws -> MonitoringMaintenanceReport {
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
        try context.save()

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
                try record.replace(
                    bucketEnd: value.bucketEnd,
                    collectorID: value.collectorID,
                    collectorVersion: value.collectorVersion,
                    maximumSourceDataAge: value.maximumSourceAge,
                    statistics: value.statistics
                )
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
        try context.save()
    }

    private func enforceQuota(_ quotaBytes: Int) throws -> (raw: Int, aggregates: Int) {
        var samples = try context.fetch(
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

        while bytes > quotaBytes, !samples.isEmpty {
            let record = samples.removeFirst()
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
        while bytes > quotaBytes, !aggregates.isEmpty {
            let record = aggregates.removeFirst()
            bytes -= Self.estimatedBytes(aggregate: record)
            context.delete(record)
            aggregatesRemoved += 1
        }
        try context.save()
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
