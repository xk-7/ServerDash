import Foundation
import Security
import SwiftUI

enum AIMode: String, Codable, CaseIterable, Sendable {
    case ops, general
    var title: String { self == .ops ? "运维模式" : "通用模式" }
}

struct AIMessage: Codable, Identifiable, Equatable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant }
    enum State: String, Codable, Sendable { case complete, streaming, interrupted }
    var id = UUID()
    var role: Role
    var text: String
    var state: State = .complete
    var date = Date()
    var provider: AIProviderID?
    var model: String?
}

struct AIConversation: Codable, Identifiable, Equatable, Sendable {
    var version = 1
    var id = UUID()
    var mode: AIMode
    var title: String
    var serverID: UUID?
    var updatedAt = Date()
    var messages: [AIMessage] = []
    var destination: AIConversationDestination?
}

enum AIError: LocalizedError {
    case configuration, keychain, storage, limit, tooLarge, malformedStream, incompleteStream
    case http(Int), network, cancelled
    case outputLimit, refused, destinationChanged, modelDiscovery, parameters
    var errorDescription: String? {
        switch self {
        case .outputLimit: return "回复达到输出上限，已保留内容。请调整 Max Tokens 后手动重试；未完成代码不可执行。"
        case .refused: return "模型拒绝了请求或触发安全限制。已保留收到的内容。"
        case .destinationChanged: return "此对话的发送地址已变更，请新建对话；不会向新地址发送旧历史。"
        case .modelDiscovery: return "无法获取模型列表。已保留原选择，请手动填写模型 ID，或检查地址、凭据及区域。"
        case .parameters: return "模型参数无效或不受支持。请检查 Temperature、Max Tokens 和历史消息上限。"
        case .configuration: return "请配置有效的 API 地址与模型。仅支持 HTTPS，HTTP 仅限本机回环地址；地址中不能包含凭据、查询或片段。"
        case .keychain: return "无法访问 AI API Key，请在设置中重新保存或解锁本机 Keychain。"
        case .storage: return "AI 对话无法读取或保存。请检查本机目录权限和磁盘空间；不会覆盖损坏的文件。"
        case .limit: return "最多保存 50 个对话。请先在对话列表中删除不需要的记录。"
        case .tooLarge: return "内容超过安全大小限制。请缩短输入、减少上下文，或新建对话。"
        case .malformedStream: return "服务返回了不支持或损坏的流式数据，请检查提供商协议与模型。"
        case .incompleteStream: return "回复未完整结束，已保留收到的内容。请手动重试；不会自动重复请求。"
        case .http(let status):
            switch status {
            case 401, 403: return "AI 服务拒绝访问（\(status)），请检查 API Key 和模型权限。"
            case 429: return "AI 服务限流或额度不足（429），请稍后手动重试。"
            default: return "AI 请求失败（HTTP \(status)），请检查服务地址和模型。"
            }
        case .network: return "AI 网络请求失败或超时。请检查网络后手动重试。"
        case .cancelled: return "已停止生成，保留未完成回复。"
        }
    }
    static func safeDescription(_ error: Error) -> String {
        // Never expose server error bodies, request URLs, API keys or prompt echoes.
        if let error = error as? AIError { return error.localizedDescription }
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return AIError.cancelled.localizedDescription }
        return AIError.network.localizedDescription
    }
}

struct AIConfiguration: Codable, Equatable, Sendable {
    var baseURL = "https://api.openai.com/v1"
    var model = ""
    var contextMessages = 20

    func endpoint() throws -> URL {
        guard let parts = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.scheme == "https" || (parts.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)),
              let url = parts.url, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              model.utf8.count <= 256 else { throw AIError.configuration }
        return url.appendingPathComponent("chat/completions")
    }
}

enum AIKeychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.serverdash.ai.api-key",
        kSecAttrAccount as String: "active-provider",
        kSecAttrSynchronizable as String: false
    ]
    static func read() throws -> String {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = item as? Data, let value = String(data: data, encoding: .utf8) else { throw AIError.keychain }
        return value
    }
    static func save(_ key: String) throws {
        if key.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw AIError.keychain }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw AIError.keychain }
        } else if status != errSecSuccess { throw AIError.keychain }
    }
}

/// Ephemeral only. Deliberately not Codable; never included in the conversation file.
struct AITerminalContext: Sendable {
    var text: String
    static let byteLimit = 16 * 1024
    static func bounded(_ text: String, limit: Int = byteLimit) -> String {
        var result = ""
        var bytes = 0
        for scalar in text.unicodeScalars {
            // CharacterSet.controlCharacters also includes ZWJ/format scalars used by Emoji.
            // Strip terminal control bytes and bidi overrides, not Unicode grapheme joiners.
            if (scalar.value < 32 && scalar != "\n" && scalar != "\t") || (0x7f...0x9f).contains(scalar.value) ||
                (0x202a...0x202e).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value) { continue }
            let count = scalar.utf8.count
            guard bytes + count <= limit else { break }
            result.unicodeScalars.append(scalar); bytes += count
        }
        return result
    }
}

struct AICommandTarget: Equatable, Sendable {
    let paneID: UUID
    let generation: UUID
    let serverName: String
    func matches(paneID: UUID?, generation: UUID?, connected: Bool) -> Bool {
        connected && self.paneID == paneID && self.generation == generation
    }
    static func isSingleCommand(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= 32 * 1024 &&
            !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || $0 == "\u{2028}" || $0 == "\u{2029}" }
    }
}

struct AICodeBlock: Identifiable, Equatable {
    let id: Int
    let language: String
    let text: String
    var isShell: Bool { ["", "sh", "shell", "bash", "zsh"].contains(language.lowercased()) }
    static func parse(_ text: String) -> [Self] {
        var language: String?
        var lines: [String] = []
        var blocks: [Self] = []
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if let current = language {
                    blocks.append(.init(id: blocks.count, language: current, text: lines.joined(separator: "\n")))
                    language = nil; lines = []
                } else { language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
            } else if language != nil { lines.append(line) }
        }
        return blocks // Incomplete streaming fences are not actionable.
    }
}

struct AIMessagePart: Identifiable {
    let id: Int
    let text: String
    let language: String?
    let complete: Bool
    static func parse(_ text: String) -> [Self] {
        var result: [Self] = [], lines: [String] = []
        var language: String?
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```"), result.count < 64 {
                if !lines.isEmpty || language != nil {
                    result.append(.init(id: result.count, text: lines.joined(separator: "\n"), language: language, complete: true))
                }
                lines = []
                language = language == nil ? String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces) : nil
            } else { lines.append(line) }
        }
        if !lines.isEmpty { result.append(.init(id: result.count, text: lines.joined(separator: "\n"), language: language, complete: language == nil)) }
        return result
    }
}
