import Foundation
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

    static func redact(_ text: String, hideIP: Bool = true) -> String {
        var result = text
        for pattern in secretPatterns.dropLast() {
            result = pattern.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "[REDACTED]"
            )
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
    static var hideIPInformation: Bool {
        UserDefaults.standard.bool(forKey: "hideIPInformation")
    }

    static var disableLocationLookup: Bool {
        UserDefaults.standard.bool(forKey: "disableLocationLookup")
    }

    static var confirmHostFingerprint: Bool {
        if UserDefaults.standard.object(forKey: "confirmHostFingerprint") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "confirmHostFingerprint")
    }

    static var connectTimeout: TimeInterval {
        let value = UserDefaults.standard.double(forKey: "sshConnectTimeout")
        return value == 0 ? 8 : min(300, max(5, value))
    }
}
