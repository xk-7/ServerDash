import Foundation
import CryptoKit
import Security
import SwiftUI

enum AIProviderID: String, Codable, CaseIterable, Sendable, Identifiable {
    case openAI, anthropic, gemini, deepSeek, qwen, volcengine, ollama, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic · Claude"
        case .gemini: return "Google Gemini"
        case .deepSeek: return "DeepSeek"
        case .qwen: return "通义千问"
        case .volcengine: return "火山引擎 · 方舟"
        case .ollama: return "Ollama"
        case .custom: return "自定义 API"
        }
    }
    var defaultURL: String {
        switch self {
        case .openAI: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        case .deepSeek: return "https://api.deepseek.com/v1"
        case .qwen: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .volcengine: return "https://ark.cn-beijing.volces.com/api/v3"
        case .ollama: return "http://localhost:11434"
        case .custom: return "https://api.example.com/v1"
        }
    }
    var requiresKey: Bool { self != .ollama && self != .custom }
    var discoverySupported: Bool { self != .volcengine }
    var help: String {
        switch self {
        case .qwen: return "API Key 必须与地域匹配。可填写百炼业务空间域名；不支持 Coding Plan 专用协议。"
        case .volcengine: return "填写已开通的模型 ID 或 ep- 开头的推理接入点 ID；不查询管理资源。"
        case .ollama: return "仅使用本机本地模型时可离线。Ollama 也支持云模型；本应用不会下载或启动模型。"
        case .anthropic: return "使用 Claude Messages API；不支持 Bedrock 或 Vertex 认证。"
        case .gemini: return "使用 Gemini API Key 与 GenerateContent；不支持 Vertex。"
        default: return "使用 Chat Completions 流式接口，基础地址不包含 /chat/completions。"
        }
    }
}

struct AIGenerationOptions: Codable, Equatable, Sendable {
    var temperature: Double?
    var maxTokens: Int? = 4096
    var historyMessages = 20
}

struct AIModelDescriptor: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var maxOutputTokens: Int?
    var maxTemperature: Double?
}

struct AIProviderProfile: Codable, Equatable, Sendable {
    var provider: AIProviderID
    var baseURL: String
    var model = ""
    var options = AIGenerationOptions()
    var credentialID: String?
    var authorizationRevision = UUID()
    init(provider: AIProviderID) { self.provider = provider; baseURL = provider.defaultURL }

    var destination: AIConversationDestination {
        .init(provider: provider, baseURL: (try? validatedBaseURL().absoluteString) ?? baseURL, model: model)
    }
    func validatedBaseURL() throws -> URL {
        let value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              var parts = URLComponents(string: value), let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.scheme == "https" || (parts.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)) else { throw AIError.configuration }
        parts.host = host
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        guard let url = parts.url else { throw AIError.configuration }
        return url
    }
    func validate(model descriptor: AIModelDescriptor? = nil, requireModel: Bool = true) throws {
        _ = try validatedBaseURL()
        guard !requireModel || (!model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.utf8.count <= 256 &&
            !model.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })) else { throw AIError.configuration }
        guard (1...50).contains(options.historyMessages) else { throw AIError.parameters }
        if let count = options.maxTokens {
            guard count > 0, count <= Int(Int32.max), descriptor?.maxOutputTokens.map({ count <= $0 }) ?? true else { throw AIError.parameters }
        }
        if provider == .anthropic && options.maxTokens == nil { throw AIError.parameters }
        if let temperature = options.temperature {
            guard let maximum = temperatureMaximum, temperature.isFinite, temperature >= 0,
                  temperature <= min(maximum, descriptor?.maxTemperature ?? maximum) else { throw AIError.parameters }
        }
    }
    // Conservative defaults for reasoning families; unknown models keep provider-side validation.
    var temperatureMaximum: Double? {
        let id = model.lowercased()
        if provider == .openAI && (id.hasPrefix("o1") || id.hasPrefix("o3") || id.hasPrefix("o4") || id.hasPrefix("gpt-5") || id.hasPrefix("gpt-6")) { return nil }
        if provider == .anthropic {
            let legacy = ["claude-3", "claude-sonnet-4-", "claude-opus-4-", "claude-haiku-4-", "claude-sonnet-4", "claude-opus-4"]
            if id.range(of: #"-4[-.][6-9](?:\D|$)"#, options: .regularExpression) != nil || !legacy.contains(where: { id.hasPrefix($0) }) { return nil }
            return 1
        }
        if provider == .deepSeek && (id.contains("reasoner") || id.contains("thinking")) { return nil }
        return 2
    }
}

struct AIConversationDestination: Codable, Equatable, Sendable {
    var provider: AIProviderID
    var baseURL: String
    var model: String
    func matches(_ profile: AIProviderProfile) -> Bool {
        provider == profile.provider && baseURL == (try? profile.validatedBaseURL().absoluteString)
    }
}

protocol AICredentialStore {
    func read(_ account: String) throws -> String
    func write(_ key: String, account: String) throws
    func delete(_ account: String) throws
}

struct AIProviderKeychain: AICredentialStore {
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.serverdash.ai.api-key",
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
    func read(_ account: String) throws -> String {
        var q = query(account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else { throw AIError.keychain }
        return key
    }
    func write(_ key: String, account: String) throws {
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8), kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemAdd(query(account).merging(attributes) { _, new in new } as CFDictionary, nil)
        guard status == errSecSuccess else { throw AIError.keychain }
    }
    func delete(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AIError.keychain }
    }
}

@MainActor
final class AISettings: ObservableObject {
    private struct Archive: Codable {
        var version = 2
        var defaultProvider: AIProviderID = .openAI
        var profiles: [AIProviderProfile] = AIProviderID.allCases.map { .init(provider: $0) }
        var legacyDestination: AIConversationDestination?
    }
    static let shared = AISettings()
    @Published private var archive = Archive()
    @Published private(set) var revision = UUID()
    @Published private(set) var notice: String?
    private var writable = true
    private let defaults: UserDefaults
    private let keys: any AICredentialStore
    private var observers: [UUID: (AIProviderID) -> Void] = [:]
    private var modelCache: [String: [AIModelDescriptor]] = [:]
    var defaultProvider: AIProviderID { archive.defaultProvider }
    var isReady: Bool { writable }
    // A v1 chat must bind to its original endpoint, not a subsequently edited Custom profile.
    var legacyDestination: AIConversationDestination {
        archive.legacyDestination ?? .init(provider: .custom, baseURL: "", model: "")
    }
    var configuration: AIConfiguration {
        let p = profile(defaultProvider)
        return .init(baseURL: p.baseURL, model: p.model, contextMessages: p.options.historyMessages)
    }
    init(defaults: UserDefaults = .standard, keys: any AICredentialStore = AIProviderKeychain()) {
        self.defaults = defaults; self.keys = keys
        if let data = defaults.data(forKey: "ai.configuration.v2") {
            do {
                let value = try JSONDecoder().decode(Archive.self, from: data)
                guard value.version == 2, value.profiles.count == AIProviderID.allCases.count,
                      Set(value.profiles.map(\.provider)).count == AIProviderID.allCases.count else { throw AIError.storage }
                for p in value.profiles { try p.validate(requireModel: false) }
                archive = value
            } catch { writable = false; notice = "AI 配置无法读取；不会覆盖原配置。请恢复配置后重试。" }
        } else if defaults.data(forKey: "ai.configuration.v1") != nil { migrateLegacy() }
    }
    func profile(_ provider: AIProviderID) -> AIProviderProfile { archive.profiles.first { $0.provider == provider } ?? .init(provider: provider) }
    func effectiveProfile(for chat: AIConversation?) throws -> AIProviderProfile {
        guard writable else { throw AIError.storage }
        guard let destination = chat?.destination else { return profile(defaultProvider) }
        var p = profile(destination.provider)
        guard destination.matches(p) else { throw AIError.destinationChanged }
        p.model = destination.model
        return p
    }
    func key(for profile: AIProviderProfile) throws -> String {
        guard let account = profile.credentialID else { return "" }
        guard account.hasPrefix(try credentialPrefix(profile)) else { throw AIError.keychain }
        return try keys.read(account)
    }
    private func credentialPrefix(_ profile: AIProviderProfile) throws -> String {
        let digest = SHA256.hash(data: Data(try profile.validatedBaseURL().absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return "v2.\(profile.provider.rawValue).\(digest)."
    }
    @discardableResult func observeSecurityChanges(_ action: @escaping (AIProviderID) -> Void) -> UUID {
        let id = UUID(); observers[id] = action; return id
    }
    func removeObserver(_ id: UUID) { observers[id] = nil }
    private func persist(_ value: Archive) throws {
        let data = try JSONEncoder().encode(value)
        let old = defaults.data(forKey: "ai.configuration.v2")
        defaults.set(data, forKey: "ai.configuration.v2")
        guard defaults.data(forKey: "ai.configuration.v2") == data else {
            defaults.set(old, forKey: "ai.configuration.v2"); throw AIError.storage
        }
    }
    func save(_ input: AIProviderProfile, key: String?, makeDefault: Bool = false) throws {
        guard writable else { throw AIError.storage }
        var p = input
        p.baseURL = try p.validatedBaseURL().absoluteString
        p.model = p.model.trimmingCharacters(in: .whitespacesAndNewlines)
        try p.validate(model: models(for: p).first { $0.id == p.model })
        let old = profile(p.provider)
        let moved = !old.destination.matches(p)
        let securityChanged = moved || key != nil
        p.credentialID = moved ? nil : old.credentialID
        p.authorizationRevision = securityChanged ? UUID() : old.authorizationRevision
        var inserted: String?
        do {
            if let key {
                guard !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw AIError.keychain }
                p.credentialID = nil
                if !key.isEmpty {
                    let account = try credentialPrefix(p) + UUID().uuidString
                    try keys.write(key, account: account); inserted = account
                    guard try keys.read(account) == key else { throw AIError.keychain }
                    p.credentialID = account
                }
            }
            var next = archive
            next.profiles.removeAll { $0.provider == p.provider }; next.profiles.append(p)
            if makeDefault { next.defaultProvider = p.provider }
            try persist(next)
            if securityChanged {
                for observer in observers.values { observer(p.provider) }
                modelCache = modelCache.filter { !$0.key.hasPrefix(p.provider.rawValue + "|") }
            }
            archive = next; revision = UUID()
        } catch {
            if let inserted { try? keys.delete(inserted) }
            throw error
        }
        if let account = old.credentialID, account != p.credentialID { try? keys.delete(account) }
    }
    // Kept for migration and existing integration callers, not used by the new settings form.
    func save(_ old: AIConfiguration, key: String?) throws {
        var p = profile(.custom); p.baseURL = old.baseURL; p.model = old.model
        p.options = .init(temperature: nil, maxTokens: nil, historyMessages: min(50, max(1, old.contextMessages)))
        try save(p, key: key, makeDefault: true)
    }
    func retryMigration() { if defaults.data(forKey: "ai.configuration.v2") == nil { migrateLegacy() } }
    private func migrateLegacy() {
        var inserted: String?
        do {
            guard let data = defaults.data(forKey: "ai.configuration.v1") else { return }
            let old = try JSONDecoder().decode(AIConfiguration.self, from: data)
            var p = AIProviderProfile(provider: .custom); p.baseURL = old.baseURL; p.model = old.model
            p.options = .init(temperature: nil, maxTokens: nil, historyMessages: min(50, max(1, old.contextMessages)))
            p.baseURL = try p.validatedBaseURL().absoluteString
            let key = try keys.read("active-provider")
            if !key.isEmpty {
                let account = try credentialPrefix(p) + UUID().uuidString
                try keys.write(key, account: account); inserted = account
                guard try keys.read(account) == key else { throw AIError.keychain }
                p.credentialID = account
            }
            var next = Archive(); next.defaultProvider = .custom; next.legacyDestination = p.destination
            next.profiles.removeAll { $0.provider == .custom }; next.profiles.append(p)
            try persist(next); archive = next; writable = true; revision = UUID()
            notice = old.contextMessages > 50 ? "旧配置已迁移到自定义 API，历史上限已调整为 50。" : "旧配置已迁移到自定义 API，地址、模型及凭据保持不变。"
            // Retain the v1 key as a rollback copy; it is never read by v2 requests.
        } catch {
            if let inserted { try? keys.delete(inserted) }
            writable = false; notice = "旧 AI 配置迁移失败，原数据与凭据已保留。请解锁 Keychain 后重试迁移。"
        }
    }
    private func cacheID(_ p: AIProviderProfile) -> String { "\(p.provider.rawValue)|\(p.baseURL)|\(p.authorizationRevision)" }
    func models(for p: AIProviderProfile) -> [AIModelDescriptor] { modelCache[cacheID(p)] ?? [] }
    func cache(_ models: [AIModelDescriptor], for p: AIProviderProfile) {
        // Form drafts may query before saving. The full destination/auth revision is the cache key.
        guard profile(p.provider).authorizationRevision == p.authorizationRevision,
              profile(p.provider).destination.matches(p) else { return }
        modelCache[cacheID(p)] = models; revision = UUID()
    }
}
