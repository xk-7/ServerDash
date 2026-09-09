import Foundation
import Darwin
import SwiftData

enum WorkbenchConnectionError: LocalizedError, Equatable {
    case invalidHost, invalidPort, invalidSerialSettings, missingDevice, invalidShell, invalidAdvancedSettings
    case unavailable(String)
    var errorDescription: String? {
        switch self {
        case .invalidHost: "请输入不带用户名、密码、协议或路径的有效主机地址。"
        case .invalidPort: "端口必须为 1–65535。"
        case .invalidSerialSettings: "串口参数无效，请检查波特率、数据位、校验、停止位和流控。"
        case .missingDevice: "请重新选择本机串口设备。"
        case .invalidShell: "本地 Shell 必须是可执行文件的绝对路径。"
        case .invalidAdvancedSettings: "SSH 高级参数无效：心跳 10–300 秒、失败次数 1–10、连接超时 5–300 秒、认证超时 10–120 秒。"
        case .unavailable(let reason): reason
        }
    }
}

private func connectionTags(_ text: String) -> [String] {
    text.split(whereSeparator: { ",，;；".contains($0) })
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
}

@Model final class VNCConnectionRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var host: String
    var port: Int
    var groupName: String
    var tagsText: String
    var notes: String
    var createdAt: Date
    var updatedAt: Date
    var lastLaunchedAt: Date?
    init(id: UUID = UUID(), name: String, host: String, port: Int = 5900,
         groupName: String = "默认分组", tagsText: String = "", notes: String = "") {
        self.id = id; self.name = name; self.host = host; self.port = port
        self.groupName = groupName; self.tagsText = tagsText; self.notes = notes
        createdAt = .now; updatedAt = .now
    }
    var displayName: String { name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? host : name }
    var tags: [String] { connectionTags(tagsText) }
    func connectionURL() throws -> URL { try VNCAddress.url(host: host, port: port) }
}

enum VNCAddress {
    static func url(host: String, port: Int) throws -> URL {
        var host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard !host.isEmpty, host.count <= 253,
              !host.contains(where: { $0.isWhitespace || $0.isNewline || "/\\@?#%".contains($0) }),
              !host.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !host.contains("://") else { throw WorkbenchConnectionError.invalidHost }
        guard (1...65535).contains(port) else { throw WorkbenchConnectionError.invalidPort }
        if host.contains(":") {
            var address = in6_addr()
            guard inet_pton(AF_INET6, host, &address) == 1 else { throw WorkbenchConnectionError.invalidHost }
        }
        var parts = URLComponents()
        parts.scheme = "vnc"; parts.host = host.contains(":") ? "[\(host)]" : host; parts.port = port
        guard let url = parts.url, url.user == nil, url.password == nil else { throw WorkbenchConnectionError.invalidHost }
        return url
    }
}

enum SerialParity: String, Codable, CaseIterable, Sendable { case none, even, odd }
enum SerialFlowControl: String, Codable, CaseIterable, Sendable { case none, hardware, software }
struct SerialPortConfiguration: Hashable, Codable, Sendable {
    var devicePath: String
    var baudRate = 115200
    var dataBits = 8
    var parity: SerialParity = .none
    var stopBits = 1
    var flowControl: SerialFlowControl = .none
    static let baudRates = [300, 600, 1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200, 230400, 460800, 921600]
    func validate() throws {
        guard devicePath.hasPrefix("/dev/"), !devicePath.contains(".."),
              !devicePath.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw WorkbenchConnectionError.missingDevice
        }
        guard Self.baudRates.contains(baudRate), (5...8).contains(dataBits), (1...2).contains(stopBits) else {
            throw WorkbenchConnectionError.invalidSerialSettings
        }
    }
}

@Model final class SerialConnectionRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var devicePath: String
    var baudRate: Int
    var dataBits: Int
    var parityRawValue: String
    var stopBits: Int
    var flowControlRawValue: String
    var groupName: String
    var tagsText: String
    var notes: String
    var createdAt: Date
    var updatedAt: Date
    var lastConnectedAt: Date?
    init(id: UUID = UUID(), name: String, devicePath: String = "", baudRate: Int = 115200,
         dataBits: Int = 8, parity: SerialParity = .none, stopBits: Int = 1,
         flowControl: SerialFlowControl = .none, groupName: String = "默认分组", tagsText: String = "", notes: String = "") {
        self.id = id; self.name = name; self.devicePath = devicePath; self.baudRate = baudRate
        self.dataBits = dataBits; self.parityRawValue = parity.rawValue; self.stopBits = stopBits
        self.flowControlRawValue = flowControl.rawValue; self.groupName = groupName
        self.tagsText = tagsText; self.notes = notes; createdAt = .now; updatedAt = .now
    }
    var displayName: String { name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "串口" : name }
    var tags: [String] { connectionTags(tagsText) }
    var configuration: SerialPortConfiguration {
        SerialPortConfiguration(devicePath: devicePath, baudRate: baudRate, dataBits: dataBits,
            parity: SerialParity(rawValue: parityRawValue) ?? .none, stopBits: stopBits,
            flowControl: SerialFlowControl(rawValue: flowControlRawValue) ?? .none)
    }
}

struct SSHAdvancedSettingsDraft: Hashable, Codable, Sendable {
    var keepAliveEnabled = true
    var keepAliveInterval = 30
    var keepAliveCountMax = 3
    var connectTimeout = 15
    var authenticationTimeout = 30
    var logOutput = false
    var commandsEnabled = false
    var beforeConnectCommand = ""
    var afterConnectCommand = ""
    static let `default` = Self()
    static var legacyDefault: Self {
        var value = Self(); value.keepAliveInterval = 15
        value.connectTimeout = Int(PrivacySettings.connectTimeout)
        return value
    }
    func validate() throws {
        guard (10...300).contains(keepAliveInterval), (1...10).contains(keepAliveCountMax),
              (5...300).contains(connectTimeout), (10...120).contains(authenticationTimeout),
              beforeConnectCommand.utf8.count <= 16384, afterConnectCommand.utf8.count <= 16384,
              !beforeConnectCommand.contains("\0"), !afterConnectCommand.contains("\0") else {
            throw WorkbenchConnectionError.invalidAdvancedSettings
        }
    }
}

@Model final class SSHAdvancedSettingsRecord {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var serverID: UUID
    var settingsData: Data
    var updatedAt: Date
    init(serverID: UUID, settings: SSHAdvancedSettingsDraft = .default) {
        id = UUID(); self.serverID = serverID
        settingsData = (try? JSONEncoder().encode(settings)) ?? Data(); updatedAt = .now
    }
    var settings: SSHAdvancedSettingsDraft {
        get { (try? JSONDecoder().decode(SSHAdvancedSettingsDraft.self, from: settingsData)) ?? .default }
        set { settingsData = (try? JSONEncoder().encode(newValue)) ?? Data(); updatedAt = .now }
    }
    @MainActor static func load(serverID: UUID, in context: ModelContext) -> SSHAdvancedSettingsDraft {
        let query = FetchDescriptor<SSHAdvancedSettingsRecord>(predicate: #Predicate { $0.serverID == serverID })
        return (try? context.fetch(query).first?.settings) ?? .legacyDefault
    }
    @MainActor static func upsert(serverID: UUID, settings: SSHAdvancedSettingsDraft, in context: ModelContext) throws {
        try settings.validate()
        let query = FetchDescriptor<SSHAdvancedSettingsRecord>(predicate: #Predicate { $0.serverID == serverID })
        if let record = try context.fetch(query).first { record.settings = settings }
        else { context.insert(SSHAdvancedSettingsRecord(serverID: serverID, settings: settings)) }
    }
}

extension ServerConnectionConfig {
    var effectiveConnectTimeout: TimeInterval { advancedSettings.map { TimeInterval($0.connectTimeout) } ?? connectTimeout }
    var keepAliveInterval: Int { advancedSettings.map { $0.keepAliveEnabled ? $0.keepAliveInterval : 0 } ?? 15 }
    var keepAliveCountMax: Int { advancedSettings?.keepAliveCountMax ?? 3 }
}
