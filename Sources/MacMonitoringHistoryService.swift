#if os(macOS)
import Foundation
import SwiftData

/// One owner for history I/O. Its context never contains ServerRecord edits from a form.
/// SwiftData and all mutable state remain on MainActor; work yields between committed batches.
@MainActor
final class MacMonitoringHistoryService {
    let repository: MonitoringHistoryRepository
    var onError: (@MainActor (Error) -> Void)?
    private let clock: any MonitoringClock
    private var maintenance: Task<MonitoringMaintenanceReport, Error>?
    private var summaryPreparation: Task<Void, Error>?
    private var lastCompletedAt: Date?
    private var automaticRetryAfter: Date?
    private static let automaticFailureBackoff: TimeInterval = 60
    private var stopped = false
    private(set) var maintenanceRunCount = 0

    convenience init(container: ModelContainer, clock: any MonitoringClock = SystemMonitoringClock()) {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        self.init(repository: MonitoringHistoryRepository(context: context, clock: clock), clock: clock)
    }

    init(repository: MonitoringHistoryRepository, clock: any MonitoringClock = SystemMonitoringClock()) {
        self.repository = repository
        self.clock = clock
        repository.maintenanceRequested = { [weak self] in self?.requestMaintenance() }
    }

    func requestMaintenance() {
        guard !stopped, maintenance == nil,
              automaticRetryAfter.map({ clock.now() >= $0 }) ?? true,
              lastCompletedAt.map({ clock.now().timeIntervalSince($0) >= 15 * 60 }) ?? true else { return }
        let task = startMaintenance(policy: .default, now: clock.now())
        Task { @MainActor [weak self] in
            do { _ = try await task.value }
            catch is CancellationError { }
            catch { self?.onError?(error) }
        }
    }

    /// Concurrent manual and automatic requests share the already running transaction sequence.
    /// Cancellation of a view's waiter does not cancel the app-owned maintenance task.
    func performMaintenance(
        policy: MonitoringRetentionPolicy = .default,
        now: Date? = nil
    ) async throws -> MonitoringMaintenanceReport {
        guard !stopped else { throw CancellationError() }
        return try await (maintenance ?? startMaintenance(policy: policy, now: now ?? clock.now())).value
    }

    func storageSummary(policy: MonitoringRetentionPolicy = .default) async throws -> MonitoringStorageSummary {
        guard !stopped else { throw CancellationError() }
        let task: Task<Void, Error>
        if let summaryPreparation { task = summaryPreparation }
        else {
            task = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.summaryPreparation = nil }
                try await self.repository.prepareStorageSummary()
            }
            summaryPreparation = task
        }
        try await task.value
        return try repository.storageSummary(policy: policy)
    }

    private func startMaintenance(policy: MonitoringRetentionPolicy, now: Date) -> Task<MonitoringMaintenanceReport, Error> {
        let task = Task { @MainActor [weak self] () throws -> MonitoringMaintenanceReport in
            guard let self, !self.stopped else { throw CancellationError() }
            defer { self.maintenance = nil }
            await Task.yield()
            try Task.checkCancellation()
            self.maintenanceRunCount += 1
            let interval = PerformanceTrace.begin(.historyMaintenance)
            defer { PerformanceTrace.end(interval) }
            do {
                _ = try await self.storageSummary(policy: policy)
                try Task.checkCancellation()
                let report = try await self.repository.performBatchedMaintenance(policy: policy, now: now)
                self.lastCompletedAt = now
                self.automaticRetryAfter = nil
                return report
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A malformed bucket or unavailable store must not start another full attempt
                // on every successful monitor frame. Explicit cleanup still bypasses this delay.
                self.automaticRetryAfter = self.clock.now().addingTimeInterval(Self.automaticFailureBackoff)
                throw error
            }
        }
        maintenance = task
        return task
    }

    func cancelImmediately() {
        stopped = true
        repository.maintenanceRequested = nil
        maintenance?.cancel()
        summaryPreparation?.cancel()
    }

    func stopAndDrain(until deadline: ContinuousClock.Instant) async -> Bool {
        cancelImmediately()
        let task = maintenance
        let summaryTask = summaryPreparation
        // Each database commit is synchronous on MainActor. Cancellation is observed before the
        // next batch; nothing can mutate its context after this task has completed.
        _ = await task?.result
        _ = await summaryTask?.result
        return ContinuousClock.now < deadline
    }
}
#endif
