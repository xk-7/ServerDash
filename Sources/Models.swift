import Foundation
import SwiftData

enum AuthenticationMethod: String, CaseIterable, Identifiable, Codable, Sendable {
    case privateKey
    case password
    case keyThenPassword

    var id: String { rawValue }

    var title: String {
        switch self {
        case .privateKey: "SSH 私钥"
        case .password: "密码"
        case .keyThenPassword: "私钥优先，密码回退"
        }
    }

    var usesPrivateKey: Bool {
        self == .privateKey || self == .keyThenPassword
    }

    var usesPassword: Bool {
        self == .password || self == .keyThenPassword
    }
}

enum ServerVerificationStatus: String, Codable, Sendable {
    case unverified
    case sshReady
    case monitorReady
    case monitorUnsupported

    var title: String {
        switch self {
        case .unverified: "未验证"
        case .sshReady: "SSH 可用"
        case .monitorReady: "监控可用"
        case .monitorUnsupported: "仅终端/SFTP"
        }
    }
}

enum SSHKeyStorageMode: String, Codable, Sendable {
    case file
    case imported
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
    var verificationStatusRawValue: String = ServerVerificationStatus.unverified.rawValue
    var enableDashboardMonitor: Bool = true
    var defaultSFTPPath: String = "."
    var capabilitiesJSON: String = ""
    var lastSuccessfulMonitorAt: Date?
    var lastLatencyMS: Double = 0

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
        lastConnectedAt: Date? = nil,
        verificationStatus: ServerVerificationStatus = .unverified,
        enableDashboardMonitor: Bool = true,
        defaultSFTPPath: String = ".",
        capabilitiesJSON: String = "",
        lastSuccessfulMonitorAt: Date? = nil,
        lastLatencyMS: Double = 0
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
        self.verificationStatusRawValue = verificationStatus.rawValue
        self.enableDashboardMonitor = enableDashboardMonitor
        self.defaultSFTPPath = defaultSFTPPath
        self.capabilitiesJSON = capabilitiesJSON
        self.lastSuccessfulMonitorAt = lastSuccessfulMonitorAt
        self.lastLatencyMS = lastLatencyMS
    }

    var authentication: AuthenticationMethod {
        get { AuthenticationMethod(rawValue: authenticationRawValue) ?? .privateKey }
        set { authenticationRawValue = newValue.rawValue }
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? host : trimmed
    }

    var verificationStatus: ServerVerificationStatus {
        get { ServerVerificationStatus(rawValue: verificationStatusRawValue) ?? .unverified }
        set { verificationStatusRawValue = newValue.rawValue }
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
            name: displayName,
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
    var storageModeRawValue: String = SSHKeyStorageMode.file.rawValue
    var bookmarkData: Data?
    var hasPassphrase: Bool = false
    var publicKeyText: String = ""

    init(
        id: UUID = UUID(),
        name: String,
        filePath: String,
        algorithm: String,
        fingerprint: String,
        notes: String = "",
        createdAt: Date = .now,
        storageMode: SSHKeyStorageMode = .file,
        bookmarkData: Data? = nil,
        hasPassphrase: Bool = false,
        publicKeyText: String = ""
    ) {
        self.id = id
        self.name = name
        self.filePath = filePath
        self.algorithm = algorithm
        self.fingerprint = fingerprint
        self.notes = notes
        self.createdAt = createdAt
        self.storageModeRawValue = storageMode.rawValue
        self.bookmarkData = bookmarkData
        self.hasPassphrase = hasPassphrase
        self.publicKeyText = publicKeyText
    }

    var storageMode: SSHKeyStorageMode {
        get { SSHKeyStorageMode(rawValue: storageModeRawValue) ?? .file }
        set { storageModeRawValue = newValue.rawValue }
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

@Model
final class TerminalSessionHistory {
    @Attribute(.unique) var id: UUID
    var serverID: UUID
    var serverName: String
    var startedAt: Date
    var endedAt: Date?
    var result: String

    init(
        id: UUID = UUID(),
        serverID: UUID,
        serverName: String,
        startedAt: Date = .now,
        endedAt: Date? = nil,
        result: String = "running"
    ) {
        self.id = id
        self.serverID = serverID
        self.serverName = serverName
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.result = result
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
        let key = keys.first { $0.id == identity.sshKeyID }
        let keyPath = identity.authentication.usesPrivateKey ? (key?.filePath ?? "") : ""
        return ServerConnectionConfig(
            id: server.id,
            credentialID: identity.id,
            name: server.displayName,
            host: server.host,
            port: server.port,
            username: identity.username,
            authentication: identity.authentication,
            privateKeyPath: keyPath,
            sshKeyID: key?.id,
            usesImportedKey: key?.storageMode == .imported,
            hasPassphrase: key?.hasPassphrase ?? false
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
    var sshKeyID: UUID? = nil
    var usesImportedKey: Bool = false
    var hasPassphrase: Bool = false
    var connectTimeout: TimeInterval = PrivacySettings.connectTimeout
}

struct ServerCapabilities: Hashable, Sendable, Codable {
    var platform: String = "linux"
    var family: String = ""
    var gnuCoreutils: Bool = true
    var hasProc: Bool = true
    var hasDocker: Bool = false
    var hasGPU: Bool = false
    var hasVnStat: Bool = false
    var limitedSupport: Bool = false

    var summary: String {
        var parts = [family.isEmpty ? platform : family]
        if limitedSupport { parts.append("有限支持") }
        if hasDocker { parts.append("Docker") }
        if hasGPU { parts.append("GPU") }
        if hasVnStat { parts.append("vnStat") }
        return parts.joined(separator: " · ")
    }
}

struct CPUCoreMetric: Identifiable, Hashable, Sendable {
    let index: Int
    let user: Double
    let system: Double
    let nice: Double
    let ioWait: Double
    let steal: Double

    var id: Int { index }
    var usage: Double { min(100, max(0, user + system + nice + ioWait + steal)) }
}

struct ProcessMetric: Identifiable, Hashable, Sendable {
    let name: String
    let pid: Int
    let cpu: Double
    let memory: Double
    var user: String = ""
    var arguments: String = ""
    var threadCount: Int = 0

    var id: Int { pid }
}

struct NetworkInterfaceMetric: Identifiable, Hashable, Sendable {
    let name: String
    let receivedBytes: Double
    let sentBytes: Double
    var downloadBytesPerSecond: Double = 0
    var uploadBytesPerSecond: Double = 0
    var isActive: Bool = false

    var id: String { name }
}

struct FilesystemMetric: Identifiable, Hashable, Sendable {
    let device: String
    let mountPoint: String
    let filesystemType: String
    let usedBytes: Double
    let totalBytes: Double

    var id: String { "\(device)|\(mountPoint)" }
    var usage: Double {
        guard totalBytes > 0 else { return 0 }
        return usedBytes / totalBytes * 100
    }
}

struct DiskIOMetric: Identifiable, Hashable, Sendable {
    let device: String
    let readBytesPerSecond: Double
    let writeBytesPerSecond: Double
    let readIOPS: Double
    let writeIOPS: Double
    let readLatencyMilliseconds: Double
    let writeLatencyMilliseconds: Double
    let lifetimeReadBytes: Double
    let lifetimeWriteBytes: Double

    var id: String { device }
}

enum VnStatPeriod: String, CaseIterable, Hashable, Identifiable, Sendable {
    case hourly
    case daily
    case weekly
    case monthly
    case yearly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hourly: "小时"
        case .daily: "每日"
        case .weekly: "每周"
        case .monthly: "每月"
        case .yearly: "每年"
        }
    }
}

struct VnStatTrafficPoint: Identifiable, Hashable, Sendable {
    let period: VnStatPeriod
    let timestamp: TimeInterval
    let receivedBytes: Double
    let sentBytes: Double

    var id: String { "\(period.rawValue)-\(timestamp)" }
    var date: Date { Date(timeIntervalSince1970: timestamp) }
    var totalBytes: Double { receivedBytes + sentBytes }
}

struct GPUMetric: Identifiable, Hashable, Sendable {
    let index: Int
    let uuid: String
    let name: String
    let utilization: Double
    let memoryUsedBytes: Double
    let memoryTotalBytes: Double
    let fanPercent: Double?
    let temperatureCelsius: Double?
    let powerWatts: Double?
    let powerLimitWatts: Double?

    var id: Int { index }
}

struct GPUProcessMetric: Identifiable, Hashable, Sendable {
    let gpuID: String
    let pid: Int
    let name: String
    let memoryBytes: Double

    var id: String { "\(gpuID)-\(pid)-\(name)" }
}

struct DockerContainerMetric: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let image: String
    let state: String
    let status: String
}

struct ServerGeoLocation: Hashable, Sendable {
    let publicIP: String
    let city: String
    let region: String
    let country: String
    let organization: String
    let latitude: Double?
    let longitude: Double?
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
    var cpuModel: String = ""
    var cpuTemperatureCelsius: Double?
    var cpuCores: [CPUCoreMetric] = []
    var memoryCachedBytes: Double = 0
    var memoryFreeBytes: Double = 0
    var memoryBuffersBytes: Double = 0
    var activeNetworkInterface: String = ""
    var networkInterfaces: [NetworkInterfaceMetric] = []
    var filesystems: [FilesystemMetric] = []
    var diskIO: [DiskIOMetric] = []
    var processes: [ProcessMetric] = []
    var vnStatAvailable: Bool = false
    var vnStatCollecting: Bool = false
    var vnStatSource: String = ""
    var vnStatHistory: [VnStatTrafficPoint] = []
    var gpuDriverVersion: String = ""
    var cudaVersion: String = ""
    var gpus: [GPUMetric] = []
    var gpuProcesses: [GPUProcessMetric] = []
    var dockerAvailable: Bool = false
    var dockerVersion: String = ""
    var dockerContainers: [DockerContainerMetric] = []
    var geoLocation: ServerGeoLocation?

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
    var load1: Double = 0
    var load5: Double = 0
    var load15: Double = 0
    var swapUsage: Double = 0
}

struct TerminalSession: Identifiable, Hashable {
    let id: UUID
    let serverID: UUID
    let serverName: String
    let config: ServerConnectionConfig
    var createdAt: Date
    var status: TerminalConnectionStatus = .connecting
    var lastError: String? = nil

    init(
        id: UUID,
        serverID: UUID,
        serverName: String,
        config: ServerConnectionConfig,
        createdAt: Date,
        status: TerminalConnectionStatus = .connecting,
        lastError: String? = nil
    ) {
        self.id = id
        self.serverID = serverID
        self.serverName = serverName
        self.config = config
        self.createdAt = createdAt
        self.status = status
        self.lastError = lastError
    }

    init(server: ServerRecord) {
        self.init(
            id: UUID(),
            serverID: server.id,
            serverName: server.displayName,
            config: server.connectionConfig,
            createdAt: .now
        )
    }
}
