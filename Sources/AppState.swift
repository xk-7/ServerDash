import Foundation
import Network
import SwiftData

enum MonitoringRequestPriority: Int, Comparable, Sendable {
    case retry = 0
    case background = 1
    case visible = 2
    case selected = 3
    case manual = 4

    static func < (lhs: MonitoringRequestPriority, rhs: MonitoringRequestPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct MonitoringScheduleTarget: Sendable, Equatable {
    let serverID: UUID
    let enabled: Bool
}

enum MonitoringBackoff {
    static let delays: [TimeInterval] = [5, 15, 30, 60, 300]

    static func delay(after failureCount: Int) -> TimeInterval {
        guard failureCount > 0 else { return 0 }
        return delays[min(failureCount - 1, delays.count - 1)]
    }
}

private enum MonitoringSuspensionReason: Hashable {
    case sleep
    case network
}

actor MonitoringCoordinator {
    static let maximumDispatchesPerSecond: Double = 24

    typealias Operation = @Sendable (UUID) async -> Bool
    typealias Jitter = @Sendable (ClosedRange<TimeInterval>) -> TimeInterval

    private struct TargetState {
        var enabled: Bool
        var failureCount = 0
    }

    private struct QueueEntry {
        let serverID: UUID
        var priority: MonitoringRequestPriority
        var notBefore: Date
        let sequence: UInt64
        var automatic: Bool
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let baseMaximumConcurrency: Int
    private let operation: Operation
    private let jitter: Jitter
    private let clock: any MonitoringClock
    private var targets: [UUID: TargetState] = [:]
    private var queue: [UUID: QueueEntry] = [:]
    private var running: [UUID: Task<Void, Never>] = [:]
    private var waiters: [UUID: [Waiter]] = [:]
    private var visibleServerIDs: Set<UUID> = []
    private var selectedServerID: UUID?
    private var wakeTask: Task<Void, Never>?
    private var suspensionReasons: Set<MonitoringSuspensionReason> = []
    private var configuredInterval: TimeInterval = 5
    private var lowPowerMode = false
    private var sequence: UInt64 = 0
    private var stopped = false
    private var nextDispatchDate = Date.distantPast

    init(
        maximumConcurrency: Int = 5,
        clock: any MonitoringClock = SystemMonitoringClock(),
        jitter: @escaping Jitter = { range in Double.random(in: range) },
        operation: @escaping Operation
    ) {
        baseMaximumConcurrency = max(1, maximumConcurrency)
        self.clock = clock
        self.jitter = jitter
        self.operation = operation
    }

    var activeCount: Int { running.count }
    var queuedCount: Int { queue.count }
    func queuedPriority(for serverID: UUID) -> MonitoringRequestPriority? {
        queue[serverID]?.priority
    }
    func waiterCount(for serverID: UUID) -> Int {
        waiters[serverID]?.count ?? 0
    }

    func configure(
        targets newTargets: [MonitoringScheduleTarget],
        interval: TimeInterval
    ) {
        stopped = false
        configuredInterval = max(0, interval)
        let newIDs = Set(newTargets.map(\.serverID))
        let removedIDs = Set(targets.keys).subtracting(newIDs)
        for serverID in removedIDs {
            remove(serverID: serverID)
        }

        for target in newTargets {
            var state = targets[target.serverID] ?? TargetState(enabled: target.enabled)
            state.enabled = target.enabled
            targets[target.serverID] = state
            if !target.enabled || configuredInterval == 0 {
                if queue[target.serverID]?.automatic == true {
                    queue[target.serverID] = nil
                }
                if !target.enabled {
                    running[target.serverID]?.cancel()
                }
                continue
            }
            if queue[target.serverID] == nil, running[target.serverID] == nil {
                enqueueAutomatic(
                    target.serverID,
                    priority: basePriority(for: target.serverID),
                    delay: initialStagger()
                )
            }
        }
        pump()
    }

    func refresh(
        serverIDs: [UUID],
        priority: MonitoringRequestPriority = .manual
    ) async -> [UUID: Bool] {
        await withTaskGroup(of: (UUID, Bool).self, returning: [UUID: Bool].self) { group in
            for serverID in serverIDs {
                group.addTask {
                    (serverID, await self.enqueueAndWait(serverID: serverID, priority: priority))
                }
            }
            var results: [UUID: Bool] = [:]
            for await (serverID, succeeded) in group {
                results[serverID] = succeeded
            }
            return results
        }
    }

    func setSelectedServerID(_ serverID: UUID?) {
        selectedServerID = serverID
        if let serverID {
            promote(serverID: serverID, to: .selected)
        }
    }

    func setVisible(_ visible: Bool, serverID: UUID) {
        if visible {
            visibleServerIDs.insert(serverID)
            promote(serverID: serverID, to: .visible)
        } else {
            visibleServerIDs.remove(serverID)
        }
    }

    func setSleeping(_ sleeping: Bool) {
        setSuspended(sleeping, reason: .sleep)
    }

    func setNetworkAvailable(_ available: Bool) {
        setSuspended(!available, reason: .network)
    }

    func setLowPowerMode(_ enabled: Bool) {
        lowPowerMode = enabled
        pump()
    }

    func remove(serverID: UUID) {
        targets[serverID] = nil
        queue[serverID] = nil
        running[serverID]?.cancel()
        resumeWaiters(for: serverID, succeeded: false)
        scheduleWake()
    }

    func stop() {
        stopped = true
        wakeTask?.cancel()
        wakeTask = nil
        queue.removeAll()
        for task in running.values {
            task.cancel()
        }
        for serverID in Array(waiters.keys) {
            resumeWaiters(for: serverID, succeeded: false)
        }
    }

    private var maximumConcurrency: Int {
        lowPowerMode ? min(2, baseMaximumConcurrency) : baseMaximumConcurrency
    }

    private var effectiveRefreshInterval: TimeInterval {
        configuredInterval * (lowPowerMode ? 2 : 1)
    }

    private var isSuspended: Bool {
        !suspensionReasons.isEmpty
    }

    private func enqueueAndWait(
        serverID: UUID,
        priority: MonitoringRequestPriority
    ) async -> Bool {
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                guard !Task.isCancelled,
                      targets[serverID]?.enabled == true,
                      !stopped else {
                    continuation.resume(returning: false)
                    return
                }
                waiters[serverID, default: []].append(
                    Waiter(id: waiterID, continuation: continuation)
                )
                enqueue(
                    serverID,
                    priority: priority,
                    notBefore: clock.now(),
                    automatic: false
                )
                pump()
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(waiterID, serverID: serverID)
            }
        }
    }

    private func cancelWaiter(_ waiterID: UUID, serverID: UUID) {
        guard var serverWaiters = waiters[serverID],
              let index = serverWaiters.firstIndex(where: { $0.id == waiterID }) else {
            return
        }
        let waiter = serverWaiters.remove(at: index)
        waiters[serverID] = serverWaiters.isEmpty ? nil : serverWaiters
        waiter.continuation.resume(returning: false)
    }

    private func enqueue(
        _ serverID: UUID,
        priority: MonitoringRequestPriority,
        notBefore: Date,
        automatic: Bool
    ) {
        guard targets[serverID]?.enabled == true, !stopped else { return }
        if running[serverID] != nil {
            return
        }
        if var existing = queue[serverID] {
            existing.priority = max(existing.priority, priority)
            existing.notBefore = min(existing.notBefore, notBefore)
            existing.automatic = existing.automatic && automatic
            queue[serverID] = existing
            return
        }
        sequence &+= 1
        queue[serverID] = QueueEntry(
            serverID: serverID,
            priority: priority,
            notBefore: notBefore,
            sequence: sequence,
            automatic: automatic
        )
    }

    private func enqueueAutomatic(
        _ serverID: UUID,
        priority: MonitoringRequestPriority,
        delay: TimeInterval
    ) {
        guard configuredInterval > 0 else { return }
        enqueue(
            serverID,
            priority: priority,
            notBefore: clock.now().addingTimeInterval(max(0, delay)),
            automatic: true
        )
    }

    private func promote(serverID: UUID, to priority: MonitoringRequestPriority) {
        guard var entry = queue[serverID], entry.priority < priority else { return }
        entry.priority = priority
        queue[serverID] = entry
        pump()
    }

    private func pump() {
        guard !stopped, !isSuspended else {
            scheduleWake()
            return
        }
        while running.count < maximumConcurrency,
              clock.now() >= nextDispatchDate,
              let entry = nextReadyEntry(now: clock.now()) {
            queue[entry.serverID] = nil
            let serverID = entry.serverID
            let operation = self.operation
            PerformanceTrace.event(.monitorSchedulerDispatch)
            nextDispatchDate = clock.now().addingTimeInterval(
                1 / Self.maximumDispatchesPerSecond
            )
            running[serverID] = Task {
                let succeeded = await operation(serverID)
                self.finished(
                    serverID: serverID,
                    succeeded: succeeded,
                    cancelled: Task.isCancelled
                )
            }
        }
        scheduleWake()
    }

    private func nextReadyEntry(now: Date) -> QueueEntry? {
        queue.values
            .filter { $0.notBefore <= now && running[$0.serverID] == nil }
            .sorted {
                if $0.priority != $1.priority {
                    return $0.priority > $1.priority
                }
                if $0.notBefore != $1.notBefore {
                    return $0.notBefore < $1.notBefore
                }
                return $0.sequence < $1.sequence
            }
            .first
    }

    private func finished(serverID: UUID, succeeded: Bool, cancelled: Bool) {
        running[serverID] = nil
        resumeWaiters(for: serverID, succeeded: succeeded)
        guard !stopped, targets[serverID]?.enabled == true else {
            pump()
            return
        }

        if cancelled {
            // Sleep, network loss, and shutdown are lifecycle events, not failures.
        } else if succeeded {
            targets[serverID]?.failureCount = 0
        } else {
            targets[serverID]?.failureCount += 1
        }
        if configuredInterval > 0, !isSuspended {
            let failures = targets[serverID]?.failureCount ?? 0
            let baseDelay = succeeded
                ? effectiveRefreshInterval
                : MonitoringBackoff.delay(after: failures)
            let jitterAmount = jitter(0...max(0, baseDelay * 0.2))
            enqueueAutomatic(
                serverID,
                priority: succeeded ? basePriority(for: serverID) : .retry,
                delay: baseDelay + jitterAmount
            )
        }
        pump()
    }

    private func resumeWaiters(for serverID: UUID, succeeded: Bool) {
        let serverWaiters = waiters.removeValue(forKey: serverID) ?? []
        for waiter in serverWaiters {
            waiter.continuation.resume(returning: succeeded)
        }
    }

    private func basePriority(for serverID: UUID) -> MonitoringRequestPriority {
        if selectedServerID == serverID { return .selected }
        if visibleServerIDs.contains(serverID) { return .visible }
        return .background
    }

    private func initialStagger() -> TimeInterval {
        let ceiling = min(5, max(0.25, effectiveRefreshInterval * 0.2))
        return jitter(0...ceiling)
    }

    private func setSuspended(_ suspended: Bool, reason: MonitoringSuspensionReason) {
        let wasSuspended = isSuspended
        if suspended {
            suspensionReasons.insert(reason)
        } else {
            suspensionReasons.remove(reason)
        }
        guard wasSuspended != isSuspended else { return }

        if isSuspended {
            PerformanceTrace.event(.monitorSchedulerCancel)
            wakeTask?.cancel()
            wakeTask = nil
            queue.removeAll()
            for task in running.values {
                task.cancel()
            }
            for serverID in Array(waiters.keys) {
                resumeWaiters(for: serverID, succeeded: false)
            }
        } else {
            for (serverID, state) in targets where state.enabled && configuredInterval > 0 {
                if running[serverID] == nil {
                    enqueueAutomatic(
                        serverID,
                        priority: basePriority(for: serverID),
                        delay: initialStagger()
                    )
                }
            }
            pump()
        }
    }

    private func scheduleWake() {
        wakeTask?.cancel()
        wakeTask = nil
        guard !stopped, !isSuspended, running.count < maximumConcurrency,
              let nextDate = queue.values.map(\.notBefore).min() else {
            return
        }
        let rateLimitedDate = max(nextDate, nextDispatchDate)
        let delay = max(0, rateLimitedDate.timeIntervalSince(clock.now()))
        let clock = self.clock
        wakeTask = Task {
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            self.wake()
        }
    }

    private func wake() {
        wakeTask = nil
        pump()
    }
}

enum DetailMode: String, CaseIterable, Identifiable {
    case monitor
    case terminal
    case sftp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .monitor: "监控"
        case .terminal: "终端"
        case .sftp: "SFTP"
        }
    }
}

struct ServerRenderState: Hashable, Sendable {
    var status: ServerConnectionStatus = .unknown
    var snapshot: ServerSnapshot = .empty
    var history: [MetricPoint] = []
    var error: String?
    var diagnostics: String?
    var capabilities: ServerCapabilities?
    var isRefreshing = false
    var lastSuccessfulMonitorAt: Date?

    var hasSnapshot: Bool {
        snapshot.capturedAt != .distantPast
    }

    func isStale(refreshInterval: TimeInterval, now: Date = .now) -> Bool {
        let last = lastSuccessfulMonitorAt ?? (
            snapshot.capturedAt == .distantPast ? nil : snapshot.capturedAt
        )
        guard let last else { return false }
        return now.timeIntervalSince(last) > max(15, refreshInterval * 3)
    }
}

@MainActor
final class ServerRuntimeState: ObservableObject, Identifiable {
    let id: UUID
    @Published private(set) var renderState: ServerRenderState
    private(set) var publicationCount = 0

    init(serverID: UUID, initial: ServerRenderState = ServerRenderState()) {
        id = serverID
        renderState = initial
    }

    func publish(_ state: ServerRenderState) {
        guard state != renderState else { return }
        publicationCount += 1
        renderState = state
    }
}

struct FleetMonitoringSummary: Equatable, Sendable {
    private(set) var onlineCount = 0
    private(set) var issueCount = 0
    private(set) var refreshingCount = 0
    private(set) var onlineCPUTotal = 0.0

    var averageCPU: Double {
        onlineCount == 0 ? 0 : onlineCPUTotal / Double(onlineCount)
    }

    mutating func replace(old: ServerRenderState?, with new: ServerRenderState?) {
        if let old { apply(old, multiplier: -1) }
        if let new { apply(new, multiplier: 1) }
    }

    private mutating func apply(_ state: ServerRenderState, multiplier: Int) {
        if state.status == .online {
            onlineCount += multiplier
            onlineCPUTotal += Double(multiplier) * state.snapshot.cpuUsage
        }
        if state.status == .failed || state.status == .offline {
            issueCount += multiplier
        }
        if state.isRefreshing {
            refreshingCount += multiplier
        }
    }
}

@MainActor
final class FleetMonitoringSummaryState: ObservableObject {
    @Published private(set) var value = FleetMonitoringSummary()
    private(set) var publicationCount = 0

    func replace(old: ServerRenderState?, with new: ServerRenderState?) {
        var updated = value
        updated.replace(old: old, with: new)
        guard updated != value else { return }
        publicationCount += 1
        value = updated
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var selectedServerID: UUID? {
        didSet {
            Task {
                await monitoringCoordinator.setSelectedServerID(selectedServerID)
            }
        }
    }
    @Published var detailMode: DetailMode = .monitor
    @Published private(set) var configs: [UUID: ServerConnectionConfig] = [:]
    @Published var selectedTerminalID: UUID?
    @Published private(set) var pendingTrust: HostTrustRequest?
    @Published private(set) var monitoringHistoryError: String?
    @Published var refreshInterval: TimeInterval {
        didSet {
            UserDefaults.standard.set(refreshInterval, forKey: "refreshInterval")
            synchronizeMonitoringSchedule()
        }
    }

    let terminalRegistry = TerminalSessionRegistry()
    let eventLog = EventLogStore.shared
    let fleetSummaryState = FleetMonitoringSummaryState()

    var fleetSummary: FleetMonitoringSummary {
        fleetSummaryState.value
    }

    var terminalSessions: [TerminalSession] {
        terminalRegistry.sessions
    }

    private var selectedConfig: ServerConnectionConfig?
    private var serverRecords: [UUID: ServerRecord] = [:]
    private var runtimeStates: [UUID: ServerRuntimeState] = [:]
    private var historyBootstrappedServerIDs: Set<UUID> = []
    private let trustCoordinator: HostTrustCoordinator
    private let monitoringClock: any MonitoringClock
    private var monitoringHistory: MonitoringHistoryRepository?
    private let connectivityMonitor = NWPathMonitor()
    private lazy var monitoringCoordinator = MonitoringCoordinator(
        clock: monitoringClock
    ) { [weak self] serverID in
        guard let self else { return false }
        return await self.collectScheduled(serverID: serverID)
    }

    convenience init() {
        self.init(
            trustCoordinator: HostTrustCoordinator(),
            monitoringClock: SystemMonitoringClock()
        )
    }

    init(
        trustCoordinator: HostTrustCoordinator,
        monitoringClock: any MonitoringClock = SystemMonitoringClock()
    ) {
        self.trustCoordinator = trustCoordinator
        self.monitoringClock = monitoringClock
        let savedInterval = UserDefaults.standard.double(forKey: "refreshInterval")
        refreshInterval = savedInterval == 0 && !UserDefaults.standard.bool(forKey: "refreshIntervalConfigured")
            ? 5
            : savedInterval
        trustCoordinator.currentDidChange = { [weak self] request in
            self?.pendingTrust = request
        }
        connectivityMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.setMonitoringNetworkAvailable(path.status == .satisfied)
            }
        }
        connectivityMonitor.start(
            queue: DispatchQueue(label: "com.serverdash.monitoring.connectivity")
        )
        Task {
            await monitoringCoordinator.setLowPowerMode(
                ProcessInfo.processInfo.isLowPowerModeEnabled
            )
        }
    }

    deinit {
        connectivityMonitor.cancel()
    }

    func bootstrap(servers: [ServerRecord], context: ModelContext) {
        if monitoringHistory == nil {
            monitoringHistory = MonitoringHistoryRepository(
                context: context,
                clock: monitoringClock
            )
        }
        for server in servers where runtimeStates[server.id] == nil {
            initializeRuntime(for: server, synchronizeMonitoring: false)
        }
        for server in servers {
            serverRecords[server.id] = server
            guard historyBootstrappedServerIDs.insert(server.id).inserted else { continue }
            do {
                try monitoringHistory?.reconcileStartupGap(
                    serverID: server.id,
                    lastSuccessfulAt: server.lastSuccessfulMonitorAt,
                    refreshInterval: refreshInterval,
                    at: monitoringClock.now()
                )
            } catch {
                reportHistoryFailure()
            }
        }
        synchronizeMonitoringSchedule()
    }

    func initializeRuntime(
        for server: ServerRecord,
        synchronizeMonitoring: Bool = true
    ) {
        serverRecords[server.id] = server
        configs[server.id] = configs[server.id] ?? server.connectionConfig
        if runtimeStates[server.id] == nil {
            runtimeStates[server.id] = ServerRuntimeState(
                serverID: server.id,
                initial: initialRenderState(for: server)
            )
        }
        if synchronizeMonitoring {
            synchronizeMonitoringSchedule()
        }
    }

    func cacheConfig(_ config: ServerConnectionConfig) {
        configs[config.id] = config
    }

    func applyResolvedConfigs(_ resolved: [UUID: ServerConnectionConfig]) {
        configs.merge(resolved) { _, new in new }
        if let selectedServerID, let config = resolved[selectedServerID] {
            selectedConfig = config
        }
    }

    func connectionConfig(for server: ServerRecord) -> ServerConnectionConfig {
        configs[server.id] ?? server.connectionConfig
    }

    func select(_ server: ServerRecord?) {
        selectedServerID = server?.id
        selectedConfig = server.flatMap { configs[$0.id] } ?? server?.connectionConfig
        if let server {
            configs[server.id] = selectedConfig ?? server.connectionConfig
        }
        if server != nil {
            detailMode = .monitor
        }
    }

    func runtime(for server: ServerRecord) -> ServerRuntimeState {
        if let runtime = runtimeStates[server.id] { return runtime }
        serverRecords[server.id] = server
        let runtime = ServerRuntimeState(
            serverID: server.id,
            initial: initialRenderState(for: server)
        )
        runtimeStates[server.id] = runtime
        return runtime
    }

    func status(for server: ServerRecord) -> ServerConnectionStatus {
        runtime(for: server).renderState.status
    }

    func snapshot(for server: ServerRecord) -> ServerSnapshot {
        runtime(for: server).renderState.snapshot
    }

    func history(for server: ServerRecord) -> [MetricPoint] {
        runtime(for: server).renderState.history
    }

    func isRefreshing(_ server: ServerRecord) -> Bool {
        runtime(for: server).renderState.isRefreshing
    }

    func isStale(_ server: ServerRecord) -> Bool {
        runtime(for: server).renderState.isStale(refreshInterval: refreshInterval)
    }

    private func initialRenderState(for server: ServerRecord) -> ServerRenderState {
        var initial = ServerRenderState()
        initial.lastSuccessfulMonitorAt = server.lastSuccessfulMonitorAt
        do {
            initial.history = try monitoringHistory?.recentMetricPoints(serverID: server.id) ?? []
        } catch {
            reportHistoryFailure()
        }
        if let data = server.capabilitiesJSON.data(using: .utf8) {
            initial.capabilities = try? JSONDecoder().decode(
                ServerCapabilities.self,
                from: data
            )
        }
        return initial
    }

    private func runtimeState(for serverID: UUID) -> ServerRuntimeState {
        if let runtime = runtimeStates[serverID] { return runtime }
        let runtime = ServerRuntimeState(serverID: serverID)
        runtimeStates[serverID] = runtime
        return runtime
    }

    private func publish(_ state: ServerRenderState, for serverID: UUID) {
        let runtime = runtimeState(for: serverID)
        let old = runtime.renderState
        guard old != state else { return }
        runtime.publish(state)
        fleetSummaryState.replace(old: old, with: state)
    }

    private func setRefreshing(_ refreshing: Bool, serverID: UUID) {
        var state = runtimeState(for: serverID).renderState
        guard state.isRefreshing != refreshing else { return }
        state.isRefreshing = refreshing
        publish(state, for: serverID)
    }

    func applyValidatedSnapshot(_ snapshot: ServerSnapshot, to server: ServerRecord) {
        let interval = PerformanceTrace.begin(.monitorPublish)
        defer { PerformanceTrace.end(interval) }
        var state = runtime(for: server).renderState
        state.snapshot = snapshot
        state.history = [metricPoint(from: snapshot)]
        state.status = .online
        state.error = nil
        state.isRefreshing = false
        state.lastSuccessfulMonitorAt = snapshot.capturedAt
        do {
            try monitoringHistory?.recordSnapshot(snapshot, serverID: server.id)
            monitoringHistoryError = nil
        } catch {
            reportHistoryFailure()
        }
        publish(state, for: server.id)
        server.lastConnectedAt = snapshot.capturedAt
        server.lastSuccessfulMonitorAt = snapshot.capturedAt
        server.verificationStatus = .monitorReady
        if selectedServerID == server.id {
            selectedConfig = server.connectionConfig
        }
    }

    func refresh(_ server: ServerRecord) async {
        serverRecords[server.id] = server
        await configureMonitoringSchedule()
        setRefreshing(true, serverID: server.id)
        defer { setRefreshing(false, serverID: server.id) }
        _ = await monitoringCoordinator.refresh(serverIDs: [server.id])
    }

    func refreshAll(_ servers: [ServerRecord], failedOnly: Bool = false) async {
        for server in servers {
            serverRecords[server.id] = server
        }
        await configureMonitoringSchedule()
        let targets = servers.filter { server in
            server.enableDashboardMonitor &&
            (!failedOnly || runtime(for: server).renderState.status == .failed)
        }
        guard !targets.isEmpty else { return }
        let serverIDs = targets.map(\.id)
        serverIDs.forEach { setRefreshing(true, serverID: $0) }
        defer { serverIDs.forEach { setRefreshing(false, serverID: $0) } }
        _ = await monitoringCoordinator.refresh(serverIDs: serverIDs)
    }

    func testSSH(_ server: ServerRecord) async {
        do {
            let config = connectionConfig(for: server)
            let elapsed = try await performTrustedConnection(
                config,
                source: .sshTest
            ) {
                try await SSHConnectionTester.test(config)
            }
            server.lastLatencyMS = elapsed * 1000
            server.lastConnectedAt = .now
            if server.verificationStatus == .unverified {
                server.verificationStatus = .sshReady
            }
            var state = runtime(for: server).renderState
            state.status = state.status == .online ? .online : .unknown
            state.error = nil
            publish(state, for: server.id)
            eventLog.append(serverID: server.id, module: .ssh, message: "SSH 测试成功")
        } catch {
            applyFailure(
                error,
                to: server.id,
                remoteOS: runtime(for: server).renderState.snapshot.distribution
            )
        }
    }

    func probeMonitor(_ server: ServerRecord) async {
        do {
            let config = connectionConfig(for: server)
            let capabilities = try await performTrustedConnection(
                config,
                source: .monitoring
            ) {
                try await SSHMonitoringService.probeCapabilities(config)
            }
            var state = runtime(for: server).renderState
            state.capabilities = capabilities
            publish(state, for: server.id)
            if let data = try? JSONEncoder().encode(capabilities),
               let json = String(data: data, encoding: .utf8) {
                server.capabilitiesJSON = json
            }
            await refresh(server)
            if runtime(for: server).renderState.status == .online {
                server.verificationStatus = .monitorReady
            }
        } catch {
            if server.verificationStatus == .sshReady {
                server.verificationStatus = .monitorUnsupported
            }
            applyFailure(
                error,
                to: server.id,
                remoteOS: runtime(for: server).renderState.snapshot.distribution
            )
        }
    }

    func openTerminal(for server: ServerRecord) {
        prepareTerminal(for: server, forceNew: false)
    }

    func newTerminal(for server: ServerRecord) {
        prepareTerminal(for: server, forceNew: true)
    }

    func selectTerminal(_ session: TerminalSession) {
        let interval = PerformanceTrace.begin(.terminalTabSwitch)
        defer { PerformanceTrace.end(interval) }
        selectedTerminalID = session.id
        selectedServerID = session.serverID
        selectedConfig = session.config
        detailMode = .terminal
    }

    func closeTerminal(_ session: TerminalSession, context: ModelContext? = nil) {
        terminalRegistry.close(session.id)
        if let context {
            context.insert(
                TerminalSessionHistory(
                    serverID: session.serverID,
                    serverName: session.serverName,
                    startedAt: session.createdAt,
                    endedAt: .now,
                    result: session.status == .failed ? "failed" : "closed"
                )
            )
            try? context.save()
        }
        if selectedTerminalID == session.id {
            selectedTerminalID = terminalSessions.last?.id
            if terminalSessions.isEmpty {
                detailMode = .monitor
            }
        }
    }

    func reconnectTerminal(_ session: TerminalSession) {
        terminalRegistry.controller(for: session.id)?.reconnect()
    }

    func removeRuntimeData(for serverID: UUID) {
        if let old = runtimeStates.removeValue(forKey: serverID)?.renderState {
            fleetSummaryState.replace(old: old, with: nil)
        }
        configs[serverID] = nil
        serverRecords[serverID] = nil
        terminalRegistry.closeAll(for: serverID)
        Task {
            await monitoringCoordinator.remove(serverID: serverID)
            await ConnectionProcessController.shared.terminateAll(for: serverID)
        }
        if selectedServerID == serverID {
            selectedServerID = nil
            selectedConfig = nil
            detailMode = .monitor
        }
    }

    func shutdown() {
        connectivityMonitor.cancel()
        terminalRegistry.terminateAll()
        KeyMaterialStore.cleanupAll()
        do {
            try monitoringHistory?.beginLifecycleGap(
                .collectorStopped,
                serverIDs: Array(serverRecords.keys),
                at: monitoringClock.now()
            )
        } catch {
            reportHistoryFailure()
        }
        Task {
            await monitoringCoordinator.stop()
            await ConnectionProcessController.shared.terminateAll()
        }
    }

    func updateRefreshInterval(_ interval: TimeInterval) {
        UserDefaults.standard.set(true, forKey: "refreshIntervalConfigured")
        refreshInterval = interval
    }

    func setMonitoringSleeping(_ sleeping: Bool) {
        do {
            if sleeping {
                try monitoringHistory?.beginLifecycleGap(
                    .sleeping,
                    serverIDs: Array(serverRecords.keys),
                    at: monitoringClock.now()
                )
            } else {
                try monitoringHistory?.endLifecycleGap(
                    .sleeping,
                    serverIDs: Array(serverRecords.keys),
                    at: monitoringClock.now()
                )
            }
        } catch {
            reportHistoryFailure()
        }
        Task {
            await monitoringCoordinator.setSleeping(sleeping)
        }
    }

    func setMonitoringNetworkAvailable(_ available: Bool) {
        do {
            if available {
                try monitoringHistory?.endLifecycleGap(
                    .networkInterrupted,
                    serverIDs: Array(serverRecords.keys),
                    at: monitoringClock.now()
                )
            } else {
                try monitoringHistory?.beginLifecycleGap(
                    .networkInterrupted,
                    serverIDs: Array(serverRecords.keys),
                    at: monitoringClock.now()
                )
            }
        } catch {
            reportHistoryFailure()
        }
        Task {
            await monitoringCoordinator.setNetworkAvailable(available)
        }
    }

    func refreshMonitoringPowerMode() {
        Task {
            await monitoringCoordinator.setLowPowerMode(
                ProcessInfo.processInfo.isLowPowerModeEnabled
            )
        }
    }

    func setMonitorVisible(_ visible: Bool, serverID: UUID) {
        Task {
            await monitoringCoordinator.setVisible(visible, serverID: serverID)
        }
    }

    func resolveTrust(_ requestID: UUID) async -> SSHHostKeyProbe? {
        let request = pendingTrust.flatMap { $0.id == requestID ? $0 : nil }
        do {
            if let probe = try await trustCoordinator.accept(requestID) {
                if let request {
                    var state = runtimeState(for: request.serverID).renderState
                    state.error = nil
                    publish(state, for: request.serverID)
                    eventLog.append(
                        serverID: request.serverID,
                        module: .ssh,
                        message: "主机信任已确认"
                    )
                }
                return probe
            }
        } catch {
            if let request {
                applyFailure(error, to: request.serverID, remoteOS: nil)
            }
        }
        return nil
    }

    func cancelTrust(_ requestID: UUID) {
        trustCoordinator.reject(requestID)
    }

    private func synchronizeMonitoringSchedule() {
        Task { [weak self] in
            await self?.configureMonitoringSchedule()
        }
    }

    private func configureMonitoringSchedule() async {
        let targets = serverRecords.values.map {
            MonitoringScheduleTarget(
                serverID: $0.id,
                enabled: $0.enableDashboardMonitor
            )
        }
        await monitoringCoordinator.configure(
            targets: targets,
            interval: refreshInterval
        )
    }

    private func collectScheduled(serverID: UUID) async -> Bool {
        guard let server = serverRecords[serverID], server.enableDashboardMonitor else {
            return false
        }
        return await collect(server)
    }

    private func collect(_ server: ServerRecord) async -> Bool {
        guard server.enableDashboardMonitor else { return false }
        var startingState = runtime(for: server).renderState
        startingState.isRefreshing = true
        if startingState.status == .unknown {
            startingState.status = .connecting
        }
        publish(startingState, for: server.id)
        do {
            let config = connectionConfig(for: server)
            let started = Date()
            var snapshot = try await performTrustedConnection(
                config,
                source: .monitoring
            ) {
                try await SSHMonitoringService.collect(config)
            }
            if PrivacySettings.disableLocationLookup {
                snapshot.geoLocation = nil
            }
            let elapsed = Date().timeIntervalSince(started)
            applyDerivedMetrics(
                to: &snapshot,
                previous: startingState.snapshot,
                serverID: server.id
            )
            let publishInterval = PerformanceTrace.begin(.monitorPublish)
            var completedState = runtime(for: server).renderState
            completedState.snapshot = snapshot
            completedState.history = appendingHistory(
                snapshot,
                to: completedState.history
            )
            completedState.status = .online
            completedState.error = nil
            completedState.diagnostics = nil
            completedState.isRefreshing = false
            completedState.lastSuccessfulMonitorAt = snapshot.capturedAt
            do {
                try monitoringHistory?.recordSnapshot(snapshot, serverID: server.id)
                monitoringHistoryError = nil
            } catch {
                reportHistoryFailure()
            }
            publish(completedState, for: server.id)
            server.lastConnectedAt = .now
            server.lastSuccessfulMonitorAt = snapshot.capturedAt
            server.lastLatencyMS = elapsed * 1000
            PerformanceTrace.end(publishInterval)
            eventLog.append(serverID: server.id, module: .monitoring, message: "监控采集成功")
            return true
        } catch {
            if Task.isCancelled || (error as? ConnectionError) == .cancelled {
                setRefreshing(false, serverID: server.id)
                return false
            }
            do {
                try monitoringHistory?.recordFailure(
                    error,
                    serverID: server.id,
                    at: monitoringClock.now()
                )
            } catch {
                reportHistoryFailure()
            }
            applyFailure(
                error,
                to: server.id,
                remoteOS: runtime(for: server).renderState.snapshot.distribution
            )
            return false
        }
    }

    func authorizeConnection(
        _ config: ServerConnectionConfig,
        source: HostTrustSource,
        forceScan: Bool = false
    ) async throws {
        try validateConnectionConfiguration(config)
        try await trustCoordinator.authorize(
            config,
            source: source,
            forceScan: forceScan
        )
    }

    private func validateConnectionConfiguration(_ config: ServerConnectionConfig) throws {
        if config.identityReferenceMissing {
            throw ConnectionError.identityReferenceMissing
        }
        let hasPassword = KeychainService.hasPassword(for: config.credentialID)
        if config.authentication == .password, !hasPassword {
            throw ConnectionError.credentialMissing
        }
        if config.authentication == .privateKey {
            if config.usesImportedKey {
                guard let keyID = config.sshKeyID,
                      (try KeychainService.secret(
                          account: KeychainService.importedKeyAccount(for: keyID)
                      )) != nil else {
                    throw ConnectionError.credentialMissing
                }
            } else if config.privateKeyPath.isEmpty {
                throw ConnectionError.privateKeyMissing
            }
        }
        if config.authentication == .keyThenPassword,
           config.privateKeyPath.isEmpty,
           !config.usesImportedKey,
           !hasPassword {
            throw ConnectionError.credentialMissing
        }
    }

    func performTrustedConnection<T>(
        _ config: ServerConnectionConfig,
        source: HostTrustSource,
        operation: () async throws -> T
    ) async throws -> T {
        try await authorizeConnection(config, source: source)
        do {
            return try await operation()
        } catch {
            let connectionError = (error as? ConnectionError) ?? ConnectionError.classify(
                error.localizedDescription,
                host: config.host,
                port: config.port
            )
            switch connectionError {
            case .hostKeyChanged, .hostKeyUntrusted:
                try await authorizeConnection(config, source: source, forceScan: true)
                return try await operation()
            default:
                throw error
            }
        }
    }

    private func applyFailure(_ error: Error, to serverID: UUID, remoteOS: String?) {
        let waitingForTrust: Bool = {
            switch error as? ConnectionError {
            case .hostKeyUntrusted, .hostKeyChanged:
                return true
            default:
                return false
            }
        }()
        var state = runtimeState(for: serverID).renderState
        state.status = waitingForTrust ? .unknown : .failed
        state.error = waitingForTrust
            ? (error as? ConnectionError == .hostKeyUntrusted
                ? "请先确认主机指纹。"
                : error.localizedDescription)
            : error.localizedDescription
        state.isRefreshing = false
        let config = configs[serverID] ?? ServerConnectionConfig(
            id: serverID,
            credentialID: serverID,
            name: "",
            host: "",
            port: 22,
            username: "",
            authentication: .privateKey,
            privateKeyPath: ""
        )
        state.diagnostics = SSHDiagnostics.report(
            config: config,
            error: error,
            remoteOS: remoteOS
        )
        publish(state, for: serverID)
        eventLog.append(
            serverID: serverID,
            module: .ssh,
            level: "error",
            message: "连接失败（\((error as? ConnectionError)?.code ?? "SSH_FAILED")）"
        )
    }

    private func prepareTerminal(for server: ServerRecord, forceNew: Bool) {
        let config = connectionConfig(for: server)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await authorizeConnection(config, source: .terminal)
                let controller = terminalRegistry.open(
                    for: server,
                    forceNew: forceNew,
                    config: config,
                    onHostKeyFailure: { [weak self] sessionID in
                        self?.recoverTerminalAfterHostKeyChange(
                            sessionID: sessionID,
                            config: config
                        )
                    }
                )
                selectedTerminalID = controller.id
                selectedServerID = server.id
                selectedConfig = config
                detailMode = .terminal
            } catch {
                guard (error as? ConnectionError) != .cancelled else { return }
                applyFailure(error, to: server.id, remoteOS: nil)
            }
        }
    }

    private func recoverTerminalAfterHostKeyChange(
        sessionID: UUID,
        config: ServerConnectionConfig
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await authorizeConnection(
                    config,
                    source: .terminal,
                    forceScan: true
                )
                terminalRegistry.controller(for: sessionID)?.reconnect()
            } catch {
                guard (error as? ConnectionError) != .cancelled else { return }
                applyFailure(error, to: config.id, remoteOS: nil)
            }
        }
    }

    private func appendingHistory(
        _ snapshot: ServerSnapshot,
        to history: [MetricPoint]
    ) -> [MetricPoint] {
        var points = history
        points.append(
            metricPoint(from: snapshot)
        )
        return Array(points.suffix(120))
    }

    private func metricPoint(from snapshot: ServerSnapshot) -> MetricPoint {
        MetricPoint(
            date: snapshot.capturedAt,
            cpu: snapshot.cpuUsage,
            memory: snapshot.memoryUsage,
            download: snapshot.downloadBytesPerSecond,
            upload: snapshot.uploadBytesPerSecond,
            load1: snapshot.load1,
            load5: snapshot.load5,
            load15: snapshot.load15,
            swapUsage: snapshot.swapUsage
        )
    }

    private func applyDerivedMetrics(
        to snapshot: inout ServerSnapshot,
        previous: ServerSnapshot?,
        serverID: UUID
    ) {
        guard let previous, previous.capturedAt != .distantPast else { return }
        let elapsed = max(0.1, snapshot.capturedAt.timeIntervalSince(previous.capturedAt))
        snapshot.networkInterfaces = snapshot.networkInterfaces.map { current in
            var updated = current
            if let prior = previous.networkInterfaces.first(where: { $0.name == current.name }) {
                updated.downloadBytesPerSecond = max(
                    0,
                    (current.receivedBytes - prior.receivedBytes) / elapsed
                )
                updated.uploadBytesPerSecond = max(
                    0,
                    (current.sentBytes - prior.sentBytes) / elapsed
                )
            }
            return updated
        }

        let pinnedName = UserDefaults.standard.string(
            forKey: "defaultNetworkInterface.\(serverID.uuidString)"
        )
        let selectedInterface = snapshot.networkInterfaces.first {
            $0.name == pinnedName
        } ?? snapshot.networkInterfaces.first {
            $0.name == snapshot.activeNetworkInterface
        } ?? snapshot.networkInterfaces.max {
            ($0.receivedBytes + $0.sentBytes) < ($1.receivedBytes + $1.sentBytes)
        }

        if let selectedInterface {
            snapshot.activeNetworkInterface = selectedInterface.name
            snapshot.networkReceivedBytes = selectedInterface.receivedBytes
            snapshot.networkSentBytes = selectedInterface.sentBytes
            snapshot.downloadBytesPerSecond = selectedInterface.downloadBytesPerSecond
            snapshot.uploadBytesPerSecond = selectedInterface.uploadBytesPerSecond
            snapshot.networkInterfaces = snapshot.networkInterfaces.map { item in
                var updated = item
                updated.isActive = item.name == selectedInterface.name
                return updated
            }
        } else {
            snapshot.downloadBytesPerSecond = max(
                0,
                (snapshot.networkReceivedBytes - previous.networkReceivedBytes) / elapsed
            )
            snapshot.uploadBytesPerSecond = max(
                0,
                (snapshot.networkSentBytes - previous.networkSentBytes) / elapsed
            )
        }
    }

    private func reportHistoryFailure() {
        monitoringHistoryError = "监控历史写入失败；实时快照仍可用。"
        eventLog.append(
            serverID: nil,
            module: .data,
            level: "error",
            message: "监控历史持久化失败（MON_HISTORY_STORE）"
        )
    }
}
