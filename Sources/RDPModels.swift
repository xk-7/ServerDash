import Foundation
import SwiftData

enum MachineProtocol: String, Codable, CaseIterable, Sendable { case ssh, rdp }

struct MachineReference: Hashable, Sendable {
    let id: UUID
    let transport: MachineProtocol
}

enum RDPKeyboardMode: String, Codable, CaseIterable, Sendable {
    case fullscreen, local, remote
    var title: String { switch self { case .fullscreen: "仅全屏时远程"; case .local: "始终本地"; case .remote: "始终远程" } }
}

enum RDPAudioMode: String, Codable, CaseIterable, Sendable {
    case local, remote, disabled
    var title: String { switch self { case .local: "本地播放"; case .remote: "远程播放"; case .disabled: "禁用" } }
}

enum RDPCertificatePolicy: String, Codable, CaseIterable, Sendable {
    case confirm, strict
    var title: String { self == .strict ? "严格验证" : "确认并信任证书" }
}

/// Contains only explicitly authorized directory bookmarks, never a password or an SSH identity.
struct RDPDirectoryShare: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var bookmark: Data
    var readOnly = true
}

struct RDPSettings: Codable, Equatable, Sendable {
    var version = 1
    var width = 1920
    var height = 1080
    var colorDepth = 32
    var dynamicResolution = false
    var screenIDs: [UInt32] = []
    var keyboardMode: RDPKeyboardMode = .fullscreen
    var audio: RDPAudioMode = .local
    var textClipboard = false
    var fileClipboard = false
    var shares: [RDPDirectoryShare] = []
    var bitmapCache = true
    var disableWallpaper = false
    var disableWindowDrag = false
    var disableMenuAnimations = false
    var disableThemes = false
    var certificatePolicy: RDPCertificatePolicy = .confirm
    var autoReconnect = true

    mutating func applyLowBandwidthPreset() {
        bitmapCache = true
        disableWallpaper = true
        disableWindowDrag = true
        disableMenuAnimations = true
        disableThemes = true
    }

    func validate() throws {
        guard version == 1 else { throw RDPValidationError.unsupportedSettings }
        try RDPDisplayLayout.validateSize(width: width, height: height)
        guard [16, 24, 32].contains(colorDepth) else { throw RDPValidationError.invalidColorDepth }
        guard screenIDs.count <= 16, Set(screenIDs).count == screenIDs.count,
              shares.count <= 16, Set(shares.map(\.id)).count == shares.count else {
            throw RDPValidationError.invalidLayout
        }
        for share in shares {
            guard !share.name.isEmpty, share.name.utf8.count <= 64,
                  share.name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                  !share.name.contains("/"), !share.name.contains("\\"),
                  !share.bookmark.isEmpty, share.bookmark.count <= 1024 * 1024 else {
                throw RDPValidationError.invalidShare
            }
        }
        guard Set(shares.map { $0.name.lowercased() }).count == shares.count else { throw RDPValidationError.invalidShare }
    }
}

enum RDPValidationError: String, LocalizedError {
    case invalidAddress = "请输入不带协议或路径的主机地址。"
    case invalidPort = "RDP 端口必须为 1–65535 的整数。"
    case invalidUsername = "请输入有效的 Windows 用户名。"
    case invalidDomain = "域名与用户名中的域不能冲突；UPN 用户名无需另填域。"
    case invalidResolution = "分辨率宽高必须为 200–8192，总画布不能超过 32 Mi 像素。"
    case invalidColorDepth = "请选择 16、24 或 32 位色。"
    case invalidLayout = "显示器布局无效或超出限制。"
    case invalidShare = "映射目录名称或授权无效，请重新选择。"
    case unsupportedSettings = "无法读取此版本的 RDP 配置，请更新应用。"
    var errorDescription: String? { rawValue }
}

struct RDPMonitor: Equatable, Sendable {
    var screenID: UInt32
    var x: Int
    var y: Int
    var width: Int
    var height: Int
    var primary: Bool
}

enum RDPDisplayLayout {
    static let maximumPixels = 32 * 1024 * 1024
    static func validateSize(width: Int, height: Int) throws {
        guard (200...8192).contains(width), (200...8192).contains(height),
              width * height <= maximumPixels else { throw RDPValidationError.invalidResolution }
    }
    static func validate(_ monitors: [RDPMonitor]) throws {
        guard !monitors.isEmpty, monitors.count <= 16, monitors.filter(\.primary).count == 1,
              Set(monitors.map(\.screenID)).count == monitors.count else { throw RDPValidationError.invalidLayout }
        for monitor in monitors {
            try validateSize(width: monitor.width, height: monitor.height)
            guard (-32768...32767).contains(monitor.x), (-32768...32767).contains(monitor.y) else {
                throw RDPValidationError.invalidLayout
            }
        }
        let minX = monitors.map(\.x).min()!, minY = monitors.map(\.y).min()!
        let width = monitors.map { $0.x + $0.width }.max()! - minX
        let height = monitors.map { $0.y + $0.height }.max()! - minY
        guard width <= 32766, height <= 32766, width * height <= maximumPixels else {
            throw RDPValidationError.invalidResolution
        }
        for (index, first) in monitors.enumerated() {
            for second in monitors.dropFirst(index + 1) {
                if first.x < second.x + second.width && second.x < first.x + first.width &&
                    first.y < second.y + second.height && second.y < first.y + first.height {
                    throw RDPValidationError.invalidLayout
                }
            }
        }
    }
}

/// RDP stays a separate entity so legacy SSH migrations and monitoring are unchanged.
@Model
final class RDPConnectionRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var domain: String
    var groupName: String
    var tagsText: String
    var notes: String
    var settingsData: Data
    var credentialReference: UUID?
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), name: String, host: String, port: Int = 3389, username: String,
         domain: String = "", groupName: String = "", tagsText: String = "", notes: String = "",
         settings: RDPSettings = RDPSettings()) throws {
        self.id = id; self.name = name; self.host = host; self.port = port
        self.username = username; self.domain = domain; self.groupName = groupName
        self.tagsText = tagsText; self.notes = notes
        self.settingsData = try JSONEncoder().encode(settings)
        self.createdAt = .now; self.updatedAt = .now
    }
    var displayName: String { name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? host : name }
    var tags: [String] { tagsText.split(whereSeparator: { $0 == "," || $0 == "，" || $0 == ";" }).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
    var machineReference: MachineReference { MachineReference(id: id, transport: .rdp) }
    func settings() throws -> RDPSettings {
        guard settingsData.count <= 20 * 1024 * 1024 else { throw RDPValidationError.unsupportedSettings }
        let value = try JSONDecoder().decode(RDPSettings.self, from: settingsData)
        try value.validate()
        return value
    }
    func configuration() throws -> RDPConnectionConfiguration {
        let value = RDPConnectionConfiguration(id: id, name: displayName, host: host, port: port,
            username: username, domain: domain, settings: try settings(), credentialReference: credentialReference)
        try value.validate()
        return value
    }
}

struct RDPConnectionConfiguration: Equatable, Sendable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var domain: String
    var settings: RDPSettings
    var credentialReference: UUID?
    var destination: String { "\(host.lowercased()):\(port)" }
    var initialMonitors: [RDPMonitor] = []
    func validate() throws {
        guard !host.isEmpty, host.utf8.count <= 253,
              !host.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "\\" || $0 == "@" }),
              !host.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw RDPValidationError.invalidAddress
        }
        guard (1...65535).contains(port) else { throw RDPValidationError.invalidPort }
        guard !username.isEmpty, username.utf8.count <= 512,
              !username.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw RDPValidationError.invalidUsername
        }
        guard domain.utf8.count <= 255,
              !domain.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !domain.contains("\\"), !(username.contains("@") && !domain.isEmpty) else {
            throw RDPValidationError.invalidDomain
        }
        if let separator = username.firstIndex(of: "\\"), !domain.isEmpty,
           username[..<separator].lowercased() != domain.lowercased() { throw RDPValidationError.invalidDomain }
        guard !login.username.isEmpty, !login.username.contains("\\") else { throw RDPValidationError.invalidUsername }
        if !initialMonitors.isEmpty { try RDPDisplayLayout.validate(initialMonitors) }
        try settings.validate()
    }
    var login: (username: String, domain: String) {
        if let separator = username.firstIndex(of: "\\") {
            return (String(username[username.index(after: separator)...]), String(username[..<separator]))
        }
        return (username, domain)
    }
}
