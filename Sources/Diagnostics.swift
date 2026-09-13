import Foundation
import Darwin
import os

enum DiagnosticModule: String, CaseIterable, Identifiable, Sendable {
    case app
    case data
    case ssh
    case monitoring
    case terminal
    case sftp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .app: "应用"
        case .data: "数据"
        case .ssh: "SSH"
        case .monitoring: "监控"
        case .terminal: "终端"
        case .sftp: "SFTP"
        }
    }
}

enum DiagnosticLog {
    private static let subsystem = "com.serverdash.app"

    static func logger(for module: DiagnosticModule) -> Logger {
        Logger(subsystem: subsystem, category: module.rawValue)
    }
}

/// Fixed, privacy-reviewed performance markers for Instruments.
///
/// Operation names are deliberately closed over an enum. Callers cannot attach
/// host names, addresses, user names, paths, commands, fingerprints, or secrets.
enum PerformanceOperation: String, CaseIterable, Sendable {
    case appLaunchToFirstFrame = "app.launch_to_first_frame"
    case appLaunchToInteractive = "app.launch_to_interactive"
    case databaseOpen = "database.open"
    case monitorCollect = "monitor.collect"
    case monitorParse = "monitor.parse"
    case monitorPublish = "monitor.publish"
    case monitorSchedulerDispatch = "monitor.scheduler_dispatch"
    case monitorSchedulerCancel = "monitor.scheduler_cancel"
    case hostKeyInspect = "hostkey.inspect"
    case hostKeyScan = "hostkey.scan"
    case sshHandshake = "ssh.handshake"
    case sshRemoteCommand = "ssh.remote_command"
    case processQueueWait = "process.queue_wait"
    case processRun = "process.run"
    case processCancelToExit = "process.cancel_to_exit"
    case dashboardCardBodyUpdate = "dashboard.card_body_update"
    case terminalOpen = "terminal.open"
    case terminalInteractive = "terminal.interactive"
    case terminalTabSwitch = "terminal.tab_switch"
    case sftpList = "sftp.list"
    case sftpTransfer = "sftp.transfer"
    case sftpProgressPublish = "sftp.progress_publish"

    fileprivate var signpostName: StaticString {
        switch self {
        case .appLaunchToFirstFrame: "app.launch_to_first_frame"
        case .appLaunchToInteractive: "app.launch_to_interactive"
        case .databaseOpen: "database.open"
        case .monitorCollect: "monitor.collect"
        case .monitorParse: "monitor.parse"
        case .monitorPublish: "monitor.publish"
        case .monitorSchedulerDispatch: "monitor.scheduler_dispatch"
        case .monitorSchedulerCancel: "monitor.scheduler_cancel"
        case .hostKeyInspect: "hostkey.inspect"
        case .hostKeyScan: "hostkey.scan"
        case .sshHandshake: "ssh.handshake"
        case .sshRemoteCommand: "ssh.remote_command"
        case .processQueueWait: "process.queue_wait"
        case .processRun: "process.run"
        case .processCancelToExit: "process.cancel_to_exit"
        case .dashboardCardBodyUpdate: "dashboard.card_body_update"
        case .terminalOpen: "terminal.open"
        case .terminalInteractive: "terminal.interactive"
        case .terminalTabSwitch: "terminal.tab_switch"
        case .sftpList: "sftp.list"
        case .sftpTransfer: "sftp.transfer"
        case .sftpProgressPublish: "sftp.progress_publish"
        }
    }
}

struct PerformanceInterval {
    fileprivate let operation: PerformanceOperation
    fileprivate let state: OSSignpostIntervalState
}

enum PerformanceTrace {
    private static let signposter = OSSignposter(
        subsystem: "com.serverdash.app",
        category: "Performance"
    )

    @discardableResult
    static func begin(_ operation: PerformanceOperation) -> PerformanceInterval {
        let state = signposter.beginInterval(
            operation.signpostName,
            id: signposter.makeSignpostID()
        )
        return PerformanceInterval(operation: operation, state: state)
    }

    static func end(_ interval: PerformanceInterval) {
        signposter.endInterval(interval.operation.signpostName, interval.state)
    }

    static func event(_ operation: PerformanceOperation) {
        signposter.emitEvent(operation.signpostName)
    }
}

@MainActor
final class LaunchPerformanceTracker {
    static let shared = LaunchPerformanceTracker()

    private var firstFrame: PerformanceInterval?
    private var interactive: PerformanceInterval?

    private init() {
        firstFrame = PerformanceTrace.begin(.appLaunchToFirstFrame)
        interactive = PerformanceTrace.begin(.appLaunchToInteractive)
    }

    func start() {
        // Accessing the singleton starts both intervals. This method makes that
        // intent explicit at the application entry point.
    }

    func markFirstFrame() {
        guard let firstFrame else { return }
        PerformanceTrace.end(firstFrame)
        self.firstFrame = nil
    }

    func markInteractive() {
        guard let interactive else { return }
        PerformanceTrace.end(interactive)
        self.interactive = nil
    }
}

enum DiagnosticRedactor {
    private static let secretPatterns: [NSRegularExpression] = {
        let raw = [
            #"(?i)(password|passphrase|secret|token|authorization)[=:\s]+\S+"#,
            #"(?i)-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]+?-----END [A-Z ]*PRIVATE KEY-----"#,
            #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#
        ]
        return raw.compactMap { try? NSRegularExpression(pattern: $0) }
    }()
    private static let ipv6CandidatePattern = try? NSRegularExpression(
        pattern: #"(?<![0-9A-Fa-f:])\[?(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}(?:%[A-Za-z0-9._-]+)?\]?(?![0-9A-Fa-f:])"#
    )

    static func redact(_ text: String, hideIP: Bool = true) -> String {
        var result = text
        for pattern in secretPatterns.dropLast() {
            result = pattern.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "[REDACTED]"
            )
        }
        if hideIP {
            result = redactIPv6(in: result)
        }
        if hideIP, let ipPattern = secretPatterns.last {
            result = ipPattern.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "[IP]"
            )
        }
        return result
    }

    private static func redactIPv6(in text: String) -> String {
        guard let ipv6CandidatePattern else { return text }
        let source = text as NSString
        let matches = ipv6CandidatePattern.matches(
            in: text,
            range: NSRange(location: 0, length: source.length)
        )
        let mutable = NSMutableString(string: text)
        for match in matches.reversed() {
            var candidate = source.substring(with: match.range)
            if candidate.hasPrefix("[") { candidate.removeFirst() }
            if candidate.hasSuffix("]") { candidate.removeLast() }
            if let zone = candidate.firstIndex(of: "%") {
                candidate = String(candidate[..<zone])
            }
            var address = in6_addr()
            let isAddress = candidate.withCString {
                inet_pton(AF_INET6, $0, &address) == 1
            }
            if isAddress {
                mutable.replaceCharacters(in: match.range, with: "[IP]")
            }
        }
        return mutable as String
    }
}

struct DiagnosticEvent: Identifiable, Hashable, Sendable {
    let id: UUID
    let date: Date
    let serverID: UUID?
    let module: DiagnosticModule
    let level: String
    let message: String

    init(
        id: UUID = UUID(),
        date: Date = .now,
        serverID: UUID?,
        module: DiagnosticModule,
        level: String = "info",
        message: String
    ) {
        self.id = id
        self.date = date
        self.serverID = serverID
        self.module = module
        self.level = level
        self.message = DiagnosticRedactor.redact(
            message,
            hideIP: true
        )
    }
}

final class EventLogStore: ObservableObject {
    static let shared = EventLogStore()

    @Published private(set) var events: [DiagnosticEvent] = []

    func append(
        serverID: UUID?,
        module: DiagnosticModule,
        level: String = "info",
        message: String
    ) {
        let event = DiagnosticEvent(
            serverID: serverID,
            module: module,
            level: level,
            message: message
        )
        DiagnosticLog.logger(for: module).info("\(event.message, privacy: .public)")
        if Thread.isMainThread {
            events.append(event)
            events = Array(events.suffix(300))
        } else {
            DispatchQueue.main.async {
                self.events.append(event)
                self.events = Array(self.events.suffix(300))
            }
        }
    }

    func events(for serverID: UUID) -> [DiagnosticEvent] {
        events.filter { $0.serverID == serverID }
    }

    func clear(serverID: UUID? = nil) {
        let update = {
            if let serverID {
                self.events.removeAll { $0.serverID == serverID }
            } else {
                self.events.removeAll()
            }
        }
        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }
}

enum SSHDiagnostics {
    static func report(
        config: ServerConnectionConfig,
        error: Error,
        remoteOS: String? = nil
    ) -> String {
        let connectionError = error as? ConnectionError
        _ = config
        return """
        App: ServerDash \(versionDisplay)
        Platform: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Remote OS: \(remoteOS ?? "未知")
        Phase: \(connectionError?.phase.title ?? ConnectionPhase.failed.title)
        Code: \(connectionError?.code ?? "UNKNOWN")
        """
    }

    private static var versionDisplay: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(version) (\($0))" } ?? version
    }
}

enum PrivacySettings {
    static let locationLookupEnabledKey = "privacy.serverLocationLookupEnabled"
    private static let legacyDisableLocationLookupKey = "disableLocationLookup"

    static var hideIPInformation: Bool {
        UserDefaults.standard.bool(forKey: "hideIPInformation")
    }

    static var locationLookupEnabled: Bool {
        locationLookupEnabled(in: .standard)
    }

    static var disableLocationLookup: Bool {
        !locationLookupEnabled
    }

    static func locationLookupEnabled(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: locationLookupEnabledKey)
    }

    /// v1.0.1 used an inverted preference whose missing value enabled lookups.
    /// Do not infer consent from that key; initialize the positive opt-in to off.
    static func migrateLocationLookupPreference(in defaults: UserDefaults = .standard) {
        if defaults.object(forKey: locationLookupEnabledKey) == nil {
            defaults.set(false, forKey: locationLookupEnabledKey)
        }
        defaults.set(!locationLookupEnabled(in: defaults), forKey: legacyDisableLocationLookupKey)
    }

    static func setLocationLookupEnabled(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: locationLookupEnabledKey)
        // Keep downgrades fail-closed even though current code reads the positive key.
        defaults.set(!enabled, forKey: legacyDisableLocationLookupKey)
    }

    static var connectTimeout: TimeInterval {
        let value = UserDefaults.standard.double(forKey: "sshConnectTimeout")
        return value == 0 ? 8 : min(300, max(5, value))
    }
}
