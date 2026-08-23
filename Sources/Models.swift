import Foundation
import SwiftData

enum AuthenticationMethod: String, CaseIterable, Identifiable, Codable, Sendable {
    case privateKey
    case password

    var id: String { rawValue }

    var title: String {
        switch self {
        case .privateKey: "SSH 私钥"
        case .password: "密码"
        }
    }
}

enum ServerConnectionStatus: String, Sendable {
    case unknown
    case connecting
    case online
    case offline
    case failed

    var title: String {
        switch self {
        case .unknown: "等待检测"
        case .connecting: "连接中"
        case .online: "在线"
        case .offline: "离线"
        case .failed: "连接异常"
        }
    }
}

@Model
final class ServerRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var authenticationRawValue: String
    var privateKeyPath: String
    var groupName: String
    var tagsText: String
    var notes: String
    var identityID: UUID?
    var createdAt: Date
    var lastConnectedAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = 22,
        username: String,
        authentication: AuthenticationMethod = .privateKey,
        privateKeyPath: String = "",
        groupName: String = "默认分组",
        tagsText: String = "",
        notes: String = "",
        identityID: UUID? = nil,
        createdAt: Date = .now,
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authenticationRawValue = authentication.rawValue
        self.privateKeyPath = privateKeyPath
        self.groupName = groupName
        self.tagsText = tagsText
        self.notes = notes
        self.identityID = identityID
        self.createdAt = createdAt
        self.lastConnectedAt = lastConnectedAt
    }

    var authentication: AuthenticationMethod {
        get { AuthenticationMethod(rawValue: authenticationRawValue) ?? .privateKey }
        set { authenticationRawValue = newValue.rawValue }
    }

    var tags: [String] {
        tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var connectionConfig: ServerConnectionConfig {
        ServerConnectionConfig(
            id: id,
            credentialID: identityID ?? id,
            name: name,
            host: host,
            port: port,
            username: username,
            authentication: authentication,
            privateKeyPath: privateKeyPath
        )
    }
}

@Model
final class IdentityRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var username: String
    var authenticationRawValue: String
    var sshKeyID: UUID?
    var notes: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        username: String,
        authentication: AuthenticationMethod,
        sshKeyID: UUID? = nil,
        notes: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.username = username
        self.authenticationRawValue = authentication.rawValue
        self.sshKeyID = sshKeyID
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var authentication: AuthenticationMethod {
        get { AuthenticationMethod(rawValue: authenticationRawValue) ?? .privateKey }
        set {
            authenticationRawValue = newValue.rawValue
            updatedAt = .now
        }
    }
}

@Model
final class SSHKeyRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var filePath: String
    var algorithm: String
    var fingerprint: String
    var notes: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        filePath: String,
        algorithm: String,
        fingerprint: String,
        notes: String = "",
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.filePath = filePath
        self.algorithm = algorithm
        self.fingerprint = fingerprint
        self.notes = notes
        self.createdAt = createdAt
    }
}

@Model
final class CommandSnippetRecord {
    @Attribute(.unique) var id: UUID
    var title: String
    var command: String
    var category: String
    var notes: String
    var isFavorite: Bool
    var createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?

    init(
        id: UUID = UUID(),
        title: String,
        command: String,
        category: String = "常用",
        notes: String = "",
        isFavorite: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.command = command
        self.category = category
        self.notes = notes
        self.isFavorite = isFavorite
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
    }
}

enum ResourceDeletionPolicy {
    static func identityReferenceCount(
        _ identityID: UUID,
        in servers: [ServerRecord]
    ) -> Int {
        servers.lazy.filter { $0.identityID == identityID }.count
    }

    static func canDeleteIdentity(
        _ identityID: UUID,
        servers: [ServerRecord]
    ) -> Bool {
        identityReferenceCount(identityID, in: servers) == 0
    }

    static func keyReferenceCount(
        _ keyID: UUID,
        in identities: [IdentityRecord]
    ) -> Int {
        identities.lazy.filter { $0.sshKeyID == keyID }.count
    }

    static func canDeleteKey(
        _ keyID: UUID,
        identities: [IdentityRecord]
    ) -> Bool {
        keyReferenceCount(keyID, in: identities) == 0
    }
}

enum ConnectionConfigResolver {
    static func resolve(
        server: ServerRecord,
        identities: [IdentityRecord],
        keys: [SSHKeyRecord]
    ) -> ServerConnectionConfig {
        guard let identityID = server.identityID,
              let identity = identities.first(where: { $0.id == identityID }) else {
            return server.connectionConfig
        }
        let keyPath: String
        if identity.authentication == .privateKey {
            keyPath = keys.first { $0.id == identity.sshKeyID }?.filePath ?? ""
        } else {
            keyPath = ""
        }
        return ServerConnectionConfig(
            id: server.id,
            credentialID: identity.id,
            name: server.name,
            host: server.host,
            port: server.port,
            username: identity.username,
            authentication: identity.authentication,
            privateKeyPath: keyPath
        )
    }

    static func synchronize(
        servers: [ServerRecord],
        identities: [IdentityRecord],
        keys: [SSHKeyRecord]
    ) {
        for server in servers where server.identityID != nil {
            let config = resolve(server: server, identities: identities, keys: keys)
            server.username = config.username
            server.authentication = config.authentication
            server.privateKeyPath = config.privateKeyPath
        }
    }
}

struct ServerConnectionConfig: Hashable, Sendable {
    let id: UUID
    let credentialID: UUID
    let name: String
    let host: String
    let port: Int
    let username: String
    let authentication: AuthenticationMethod
    let privateKeyPath: String
}

struct ProcessMetric: Identifiable, Hashable, Sendable {
    let id = UUID()
    let name: String
    let pid: Int
    let cpu: Double
    let memory: Double
}

struct ServerSnapshot: Hashable, Sendable {
    var capturedAt: Date
    var cpuUsage: Double
    var coreCount: Int
    var load1: Double
    var load5: Double
    var load15: Double
    var memoryUsedBytes: Double
    var memoryTotalBytes: Double
    var swapUsedBytes: Double
    var swapTotalBytes: Double
    var diskUsedBytes: Double
    var diskTotalBytes: Double
    var networkReceivedBytes: Double
    var networkSentBytes: Double
    var downloadBytesPerSecond: Double
    var uploadBytesPerSecond: Double
    var uptime: String
    var distribution: String
    var kernel: String
    var loggedInUsers: Int
    var processCount: Int
    var topProcesses: [ProcessMetric]

    var memoryUsage: Double {
        guard memoryTotalBytes > 0 else { return 0 }
        return memoryUsedBytes / memoryTotalBytes * 100
    }

    var swapUsage: Double {
        guard swapTotalBytes > 0 else { return 0 }
        return swapUsedBytes / swapTotalBytes * 100
    }

    var diskUsage: Double {
        guard diskTotalBytes > 0 else { return 0 }
        return diskUsedBytes / diskTotalBytes * 100
    }

    static let empty = ServerSnapshot(
        capturedAt: .distantPast,
        cpuUsage: 0,
        coreCount: 0,
        load1: 0,
        load5: 0,
        load15: 0,
        memoryUsedBytes: 0,
        memoryTotalBytes: 0,
        swapUsedBytes: 0,
        swapTotalBytes: 0,
        diskUsedBytes: 0,
        diskTotalBytes: 0,
        networkReceivedBytes: 0,
        networkSentBytes: 0,
        downloadBytesPerSecond: 0,
        uploadBytesPerSecond: 0,
        uptime: "—",
        distribution: "等待采集",
        kernel: "—",
        loggedInUsers: 0,
        processCount: 0,
        topProcesses: []
    )
}

struct MetricPoint: Identifiable, Hashable, Sendable {
    let id = UUID()
    let date: Date
    let cpu: Double
    let memory: Double
    let download: Double
    let upload: Double
}

struct TerminalSession: Identifiable, Hashable {
    let id: UUID
    let serverID: UUID
    let serverName: String
    let config: ServerConnectionConfig
    var createdAt: Date

    init(server: ServerRecord) {
        id = UUID()
        serverID = server.id
        serverName = server.name
        config = server.connectionConfig
        createdAt = .now
    }
}
