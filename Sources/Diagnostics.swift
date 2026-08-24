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

enum DiagnosticRedactor {
    private static let secretPatterns: [NSRegularExpression] = {
        let raw = [
            #"(?i)(password|passphrase|secret|token|authorization)[=:\s]+\S+"#,
            #"(?i)-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]+?-----END [A-Z ]*PRIVATE KEY-----"#,
            #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#
        ]
        return raw.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    static func redact(_ text: String, hideIP: Bool = false) -> String {
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
            hideIP: PrivacySettings.hideIPInformation
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
        let hideIP = PrivacySettings.hideIPInformation
        let host = hideIP ? "[IP]" : config.host
        return """
        App: ServerDash 0.1.0
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Remote OS: \(remoteOS ?? "未知")
        Host: \(config.username)@\(host):\(config.port)
        Phase: \(connectionError?.phase.title ?? ConnectionPhase.failed.title)
        Code: \(connectionError?.code ?? "UNKNOWN")
        Message: \(DiagnosticRedactor.redact(error.localizedDescription, hideIP: hideIP))
        """
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
