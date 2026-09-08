import AppKit
import SwiftUI
import XCTest
@testable import ServerDash

private let sentinelKey = "FAKE-KEY-DO-NOT-LOG"
private func fixtureProfile(_ provider: AIProviderID) -> AIProviderProfile {
    var p = AIProviderProfile(provider: provider)
    p.model = provider == .anthropic ? "claude-3-5-sonnet-latest" : "fixture-model"
    return p
}
private func sse(_ object: [String: Any]) throws -> Data {
    Data("data: ".utf8) + (try JSONSerialization.data(withJSONObject: object)) + Data("\n\n".utf8)
}
private func providerFixture(_ provider: AIProviderID, text: String = "中文 👩🏽‍💻 é", reason: String? = nil) throws -> Data {
    switch provider {
    case .anthropic:
        return try sse(["type": "message_start", "message": ["role": "assistant"]]) +
            sse(["type": "content_block_delta", "delta": ["type": "text_delta", "text": text]]) +
            sse(["type": "message_delta", "delta": ["stop_reason": reason ?? "end_turn"]]) + sse(["type": "message_stop"])
    case .gemini:
        return try sse(["candidates": [["index": 0, "content": ["parts": [["text": text]]]]]]) +
            sse(["candidates": [["index": 0, "finishReason": reason ?? "STOP"]]])
    case .ollama:
        return try JSONSerialization.data(withJSONObject: ["message": ["content": text], "done": false]) + Data("\n".utf8) +
            JSONSerialization.data(withJSONObject: ["done": true, "done_reason": reason ?? "stop"]) + Data("\n".utf8)
    default:
        return try sse(["choices": [["index": 0, "delta": ["content": text]]]]) +
            sse(["choices": [["index": 0, "delta": [:], "finish_reason": reason ?? "stop"]]]) + Data("data: [DONE]\n\n".utf8)
    }
}

final class AIProviderProtocolTests: XCTestCase {
    func testEightProvidersHaveIndependentProtocolsAndAuth() throws {
        XCTAssertEqual(AIProviderID.allCases.count, 8)
        for provider in AIProviderID.allCases {
            var p = fixtureProfile(provider); p.options.temperature = 0.2
            let request = try AIProviderAdapter(provider: provider).request(profile: p, key: sentinelKey,
                messages: [.init(role: "system", content: "SAFETY"), .init(role: "user", content: "你好"), .init(role: "assistant", content: "Hi"), .init(role: "user", content: "问题")])
            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertFalse(String(decoding: body, as: UTF8.self).contains(sentinelKey))
            XCTAssertFalse(request.url!.absoluteString.contains(sentinelKey))
            XCTAssertNil(json["tools"])
            switch provider {
            case .anthropic:
                XCTAssertEqual(request.url?.path, "/v1/messages")
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), sentinelKey)
                XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
                XCTAssertEqual(json["system"] as? String, "SAFETY")
                XCTAssertEqual((json["messages"] as? [[String: Any]])?.count, 3)
                XCTAssertEqual(json["max_tokens"] as? Int, 4096)
            case .gemini:
                XCTAssertTrue(request.url!.path.hasSuffix(":streamGenerateContent"))
                XCTAssertEqual(request.url?.query, "alt=sse")
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), sentinelKey)
                XCTAssertNotNil(json["systemInstruction"])
                XCTAssertEqual((json["contents"] as? [[String: Any]])?[1]["role"] as? String, "model")
                XCTAssertEqual((json["generationConfig"] as? [String: Any])?["maxOutputTokens"] as? Int, 4096)
            case .ollama:
                XCTAssertEqual(request.url?.path, "/api/chat")
                XCTAssertEqual((json["options"] as? [String: Any])?["num_predict"] as? Int, 4096)
            default:
                XCTAssertTrue(request.url!.path.hasSuffix("/chat/completions"))
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + sentinelKey)
                XCTAssertEqual(json[provider == .openAI ? "max_completion_tokens" : "max_tokens"] as? Int, 4096)
                if provider == .openAI { XCTAssertEqual(json["store"] as? Bool, false) } else { XCTAssertNil(json["store"]) }
            }
        }
    }
    func testNativeAndCompatibleStreamsEveryByteFragmentation() throws {
        for provider in AIProviderID.allCases {
            var decoder = AIProviderStreamDecoder(provider: provider), text = "", finished = false
            for byte in try providerFixture(provider) {
                try decoder.receive(Data([byte])) { event in
                    if case .text(let value) = event { text += value }
                    if case .finished(.complete) = event { finished = true }
                }
            }
            try decoder.validateEnd { _ in }
            XCTAssertTrue(finished, provider.rawValue); XCTAssertEqual(text, "中文 👩🏽‍💻 é", provider.rawValue)
        }
    }
    func testLimitsRefusalsAndToolsAreNeverCompleted() throws {
        for provider in AIProviderID.allCases {
            let limit = provider == .gemini ? "MAX_TOKENS" : provider == .anthropic ? "max_tokens" : "length"
            let denied = provider == .gemini ? "SAFETY" : provider == .anthropic ? "refusal" : "content_filter"
            for (wire, expected) in [(limit, AIFinishReason.outputLimit), (denied, .refused), ("tool_calls", .unsupported)] {
                var decoder = AIProviderStreamDecoder(provider: provider), text = "", reason: AIFinishReason?
                try decoder.receive(providerFixture(provider, reason: wire)) {
                    if case .text(let value) = $0 { text += value }
                    if case .finished(let value) = $0 { reason = value }
                }
                XCTAssertEqual(reason, expected); XCTAssertFalse(text.isEmpty)
            }
        }
    }
    func testReasoningIsNotDisplayedAndPromptBlockingIsRecognized() throws {
        var claude = AIProviderStreamDecoder(provider: .anthropic), text = ""
        try claude.receive(sse(["type": "content_block_delta", "delta": ["type": "thinking_delta", "thinking": "PRIVATE-REASONING"]])) { if case .text(let value) = $0 { text += value } }
        try claude.receive(providerFixture(.anthropic, text: "answer")) { if case .text(let value) = $0 { text += value } }
        XCTAssertEqual(text, "answer")
        var gemini = AIProviderStreamDecoder(provider: .gemini), reason: AIFinishReason?
        try gemini.receive(sse(["promptFeedback": ["blockReason": "SAFETY"]])) { if case .finished(let value) = $0 { reason = value } }
        XCTAssertEqual(reason, .refused)
    }
    func testMalformedTruncatedOversizedAndPartialEvents() throws {
        for provider in AIProviderID.allCases {
            var decoder = AIProviderStreamDecoder(provider: provider)
            XCTAssertThrowsError(try decoder.validateEnd { _ in })
            let bad = provider == .ollama ? "SECRET\n" : "data: SECRET\n\n"
            XCTAssertThrowsError(try decoder.receive(Data(bad.utf8)) { _ in }) { XCTAssertFalse(AIError.safeDescription($0).contains("SECRET")) }
            var large = AIProviderStreamDecoder(provider: provider)
            XCTAssertThrowsError(try large.receive(Data(repeating: 65, count: AIStreamDecoder.eventLimit + 1)) { _ in })
        }
        var decoder = AIProviderStreamDecoder(provider: .anthropic), text = ""
        let good = try sse(["type": "content_block_delta", "delta": ["type": "text_delta", "text": "preserved"]])
        XCTAssertThrowsError(try decoder.receive(good + Data("data: BAD\n\n".utf8)) { if case .text(let t) = $0 { text += t } })
        XCTAssertEqual(text, "preserved")
        var ollama = AIProviderStreamDecoder(provider: .ollama)
        let final = try JSONSerialization.data(withJSONObject: ["done": true, "done_reason": "stop", "message": ["content": "ok"]])
        try ollama.receive(final) { _ in }; try ollama.validateEnd { _ in }; XCTAssertTrue(ollama.done)
    }
    func testTemperatureAndTokenValidation() throws {
        for provider in AIProviderID.allCases {
            var p = fixtureProfile(provider)
            try p.validate()
            for value in [-0.1, 2.1, Double.nan, Double.infinity] { p.options.temperature = value; XCTAssertThrowsError(try p.validate()) }
            p.options.temperature = nil
            for value in [0, -1, Int.max] { p.options.maxTokens = value; XCTAssertThrowsError(try p.validate()) }
            p.options.maxTokens = 500
            XCTAssertThrowsError(try p.validate(model: .init(id: p.model, name: p.model, maxOutputTokens: 100)))
            p.options.maxTokens = 100; try p.validate(model: .init(id: p.model, name: p.model, maxOutputTokens: 100))
        }
        for model in ["o1", "o3-mini", "gpt-5"] {
            var p = fixtureProfile(.openAI); p.model = model; XCTAssertNil(p.temperatureMaximum)
            p.options.temperature = 0; XCTAssertThrowsError(try p.validate())
            p.options.temperature = nil
            let request = try AIProviderAdapter(provider: .openAI).request(profile: p, key: sentinelKey, messages: [.init(role: "system", content: "safe")])
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            XCTAssertNil(json["temperature"])
            XCTAssertEqual((json["messages"] as? [[String: String]])?.first?["role"], "developer")
        }
        var claude = fixtureProfile(.anthropic); claude.options.temperature = 1.1
        XCTAssertThrowsError(try claude.validate()); claude.options.temperature = 1; try claude.validate()
        claude.model = "claude-sonnet-4-6"; XCTAssertNil(claude.temperatureMaximum)
    }
    func testEndpointAndCredentialRestrictionsAcrossProviders() throws {
        for provider in AIProviderID.allCases {
            for base in ["http://example.com", "file:///etc/passwd", "https://user:key@example.com", "https://example.com?key=x", "https://example.com/#secret", "https://example.com\n"] {
                var p = fixtureProfile(provider); p.baseURL = base
                // Leading/trailing whitespace is allowed; embedded control bytes are not.
                if base.hasSuffix("\n") { p.baseURL = "https://exa\nmple.com" }
                XCTAssertThrowsError(try p.validatedBaseURL())
            }
            var p = fixtureProfile(provider); p.baseURL = "http://[::1]:11434/"
            XCTAssertEqual(try p.validatedBaseURL().absoluteString, "http://[::1]:11434")
            XCTAssertThrowsError(try AIProviderAdapter(provider: provider).request(profile: p, key: "bad\r\nheader", messages: []))
            if provider.requiresKey { XCTAssertThrowsError(try AIProviderAdapter(provider: provider).request(profile: p, key: "", messages: [])) }
            else { XCTAssertNoThrow(try AIProviderAdapter(provider: provider).request(profile: p, key: "", messages: [])) }
        }
        var p = fixtureProfile(.gemini); p.model = "../../stolen?key=x"
        XCTAssertThrowsError(try AIProviderAdapter(provider: .gemini).request(profile: p, key: sentinelKey, messages: []))
    }
    func testModelDiscoveryMappingAndSafePagination() throws {
        for provider in AIProviderID.allCases where provider.discoverySupported {
            let adapter = AIProviderAdapter(provider: provider), p = fixtureProfile(provider)
            let request = try adapter.modelRequest(profile: p, key: sentinelKey, cursor: "cursor&key=attacker")
            XCTAssertFalse(request.url!.absoluteString.contains(sentinelKey))
            var object: [String: Any]
            switch provider {
            case .anthropic: object = ["data": [["id": "claude-fixture", "display_name": "Claude", "max_tokens": 2048]], "has_more": true, "last_id": "cursor"]
            case .gemini: object = ["models": [["name": "models/gemini-fixture", "supportedGenerationMethods": ["generateContent"], "outputTokenLimit": 2048], ["name": "models/embedding", "supportedGenerationMethods": ["embedContent"]]], "nextPageToken": "cursor"]
            case .ollama: object = ["models": [["name": "qwen:local", "model": "qwen:local"]]]
            case .qwen: object = ["output": ["models": [["model": "qwen-fixture"]], "page_no": 1, "page_size": 100, "total": 101]]
            default: object = ["data": [["id": "fixture"]]]
            }
            let page = try adapter.decodeModels(JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(page.models.count, 1)
            if [.anthropic, .gemini, .qwen].contains(provider) { XCTAssertNotNil(page.next) }
            XCTAssertThrowsError(try adapter.decodeModels(Data("SECRET-invalid".utf8)))
        }
        XCTAssertThrowsError(try AIProviderAdapter(provider: .volcengine).modelRequest(profile: fixtureProfile(.volcengine), key: sentinelKey))
    }
    func testHistoryOneTwentyFiftyExcludesSystemAndCurrentQuestion() throws {
        var chat = AIConversation(mode: .ops, title: "fixture")
        for n in 0..<100 { chat.messages.append(.init(role: n % 2 == 0 ? .user : .assistant, text: "history-\(n)")) }
        chat.messages.append(.init(role: .assistant, text: "DO-NOT-SEND", state: .interrupted))
        chat.messages.append(.init(role: .user, text: "CURRENT"))
        for count in [1, 20, 50] {
            let messages = try AIRequestBuilder.messages(conversation: chat, count: count, context: .init(text: "ATTACHMENT"))
            XCTAssertEqual(messages.first?.role, "system"); XCTAssertEqual(messages.dropFirst().first?.role, "user")
            XCTAssertLessThanOrEqual(messages.count, count + 2)
            XCTAssertTrue(messages.last!.content.hasPrefix("CURRENT")); XCTAssertTrue(messages.last!.content.contains("ATTACHMENT"))
            XCTAssertFalse(messages.contains { $0.content == "DO-NOT-SEND" })
        }
    }
}

private final class AIFakeCredentials: AICredentialStore {
    var entries: [String: String] = [:]
    var failWrite = false
    var failVerify = false
    func read(_ account: String) throws -> String { if failVerify && account != "active-provider" { throw AIError.keychain }; return entries[account] ?? "" }
    func write(_ key: String, account: String) throws { if failWrite { throw AIError.keychain }; entries[account] = key }
    func delete(_ account: String) throws { entries[account] = nil }
}

@MainActor
final class AIProviderSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    override func setUp() { suite = "serverdash.ai.providers.tests.\(UUID())"; defaults = UserDefaults(suiteName: suite)! }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }
    func testLegacyMigrationPreservesCredentialsAndNoParameterOverrides() throws {
        let old = AIConfiguration(baseURL: "https://fixture.invalid/v1", model: "old-model", contextMessages: 100)
        defaults.set(try JSONEncoder().encode(old), forKey: "ai.configuration.v1")
        let keys = AIFakeCredentials(); keys.entries["active-provider"] = sentinelKey
        let settings = AISettings(defaults: defaults, keys: keys), profile = settings.profile(.custom)
        XCTAssertEqual(settings.defaultProvider, .custom); XCTAssertEqual(profile.baseURL, old.baseURL); XCTAssertEqual(profile.model, old.model)
        XCTAssertEqual(profile.options.historyMessages, 50); XCTAssertNil(profile.options.maxTokens); XCTAssertNil(profile.options.temperature)
        XCTAssertEqual(try settings.key(for: profile), sentinelKey)
        XCTAssertNotNil(keys.entries["active-provider"])
        XCTAssertFalse(String(decoding: defaults.data(forKey: "ai.configuration.v2")!, as: UTF8.self).contains(sentinelKey))
        let reload = AISettings(defaults: defaults, keys: keys)
        XCTAssertEqual(try reload.key(for: reload.profile(.custom)), sentinelKey)
    }
    func testFailedMigrationCanRetryWithoutDiscardingOldKey() throws {
        defaults.set(try JSONEncoder().encode(AIConfiguration(model: "old")), forKey: "ai.configuration.v1")
        let keys = AIFakeCredentials(); keys.entries["active-provider"] = sentinelKey; keys.failVerify = true
        let settings = AISettings(defaults: defaults, keys: keys)
        XCTAssertFalse(settings.isReady); XCTAssertNil(defaults.data(forKey: "ai.configuration.v2")); XCTAssertEqual(keys.entries.count, 1)
        keys.failVerify = false; settings.retryMigration()
        XCTAssertTrue(settings.isReady); XCTAssertEqual(try settings.key(for: settings.profile(.custom)), sentinelKey)
    }
    func testKeysAreIsolatedAndURLChangesDoNotReuseThem() throws {
        let keys = AIFakeCredentials(), settings = AISettings(defaults: defaults, keys: keys)
        for provider in AIProviderID.allCases { try settings.save(fixtureProfile(provider), key: "fake-\(provider.rawValue)") }
        for provider in AIProviderID.allCases { XCTAssertEqual(try settings.key(for: settings.profile(provider)), "fake-\(provider.rawValue)") }
        var changed = settings.profile(.openAI), borrowed = settings.profile(.gemini)
        borrowed.credentialID = changed.credentialID
        XCTAssertThrowsError(try settings.key(for: borrowed))
        let oldRevision = changed.authorizationRevision; changed.baseURL = "https://another.invalid/v1"
        try settings.save(changed, key: nil)
        XCTAssertEqual(try settings.key(for: settings.profile(.openAI)), "")
        XCTAssertNotEqual(oldRevision, settings.profile(.openAI).authorizationRevision)
        XCTAssertEqual(try settings.key(for: settings.profile(.gemini)), "fake-gemini")
    }
    func testSaveFailureRollsBackAndParameterOnlySaveKeepsAuthorization() throws {
        let keys = AIFakeCredentials(), settings = AISettings(defaults: defaults, keys: keys)
        try settings.save(fixtureProfile(.openAI), key: "ORIGINAL")
        let original = settings.profile(.openAI), persisted = defaults.data(forKey: "ai.configuration.v2")
        keys.failVerify = true
        XCTAssertThrowsError(try settings.save(original, key: "REPLACEMENT"))
        XCTAssertEqual(keys.entries.count, 1); XCTAssertEqual(defaults.data(forKey: "ai.configuration.v2"), persisted)
        keys.failVerify = false
        XCTAssertEqual(try settings.key(for: settings.profile(.openAI)), "ORIGINAL")
        var changed = original; changed.options.maxTokens = 1000
        try settings.save(changed, key: nil)
        XCTAssertEqual(settings.profile(.openAI).authorizationRevision, original.authorizationRevision)
        XCTAssertEqual(settings.profile(.openAI).options.maxTokens, 1000)
    }
    func testUnreadableConfigNotOverwrittenAndStaleModelCacheRejected() throws {
        let bad = Data("{\"version\":999}".utf8); defaults.set(bad, forKey: "ai.configuration.v2")
        let keys = AIFakeCredentials(), blocked = AISettings(defaults: defaults, keys: keys)
        XCTAssertFalse(blocked.isReady); XCTAssertThrowsError(try blocked.save(fixtureProfile(.custom), key: nil))
        XCTAssertEqual(defaults.data(forKey: "ai.configuration.v2"), bad)
        defaults.removeObject(forKey: "ai.configuration.v2")
        let settings = AISettings(defaults: defaults, keys: keys)
        try settings.save(fixtureProfile(.openAI), key: "OLD")
        let before = settings.profile(.openAI)
        try settings.save(before, key: "NEW")
        settings.cache([.init(id: "stale", name: "stale")], for: before)
        XCTAssertTrue(settings.models(for: settings.profile(.openAI)).isEmpty)
    }
    func testProviderSwitchNewChatAndOldHistoryNeverCrossesDestination() async throws {
        let keys = AIFakeCredentials(), settings = AISettings(defaults: defaults, keys: keys)
        try settings.save(fixtureProfile(.custom), key: nil, makeDefault: true)
        try settings.save(fixtureProfile(.ollama), key: nil)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("serverdash-provider-workspace-\(UUID())")
        let workspace = AIWorkspace(disk: .init(directory: dir), settings: settings)
        await workspace.load()
        let old = try XCTUnwrap(workspace.create(mode: .general))
        workspace.selectModel("original-chat-model", in: old)
        let next = try XCTUnwrap(workspace.selectProvider(.ollama, in: old))
        XCTAssertNotEqual(old, next); XCTAssertEqual(workspace.conversations.count, 2)
        XCTAssertEqual(workspace.conversation(old)?.destination?.model, "original-chat-model")
        XCTAssertEqual(workspace.conversation(next)?.destination?.provider, .ollama)
        XCTAssertTrue(workspace.conversation(next)!.messages.isEmpty)
        var changed = settings.profile(.custom); changed.baseURL = "https://changed.invalid/v1"
        try settings.save(changed, key: nil)
        XCTAssertThrowsError(try settings.effectiveProfile(for: workspace.conversation(old)))
        XCTAssertFalse(workspace.send(id: old, prompt: "NEVER SEND", profile: changed, context: nil, target: nil))
        XCTAssertTrue(workspace.conversation(old)!.messages.isEmpty)
        for _ in 0..<48 { _ = workspace.create(mode: .general) }
        XCTAssertNil(workspace.selectProvider(.custom, in: next))
        XCTAssertEqual(workspace.conversations.count, 50)
        await workspace.flushWrites(); try FileManager.default.removeItem(at: dir)
    }
    func testLegacyConversationLoadsIntoCustomDestination() async throws {
        defaults.set(try JSONEncoder().encode(AIConfiguration(baseURL: "https://legacy.invalid/v1", model: "legacy-model")), forKey: "ai.configuration.v1")
        let keys = AIFakeCredentials(), settings = AISettings(defaults: defaults, keys: keys)
        try settings.save(fixtureProfile(.custom), key: nil, makeDefault: true)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("serverdash-provider-legacy-\(UUID())")
        let disk = AIConversationDisk(directory: dir)
        let chat = AIConversation(mode: .general, title: "legacy", messages: [.init(role: .user, text: "old history")])
        try await disk.save(chat, revision: 0)
        let workspace = AIWorkspace(disk: disk, settings: settings); await workspace.load(); await workspace.flushWrites()
        XCTAssertEqual(workspace.conversation(chat.id)?.destination?.provider, .custom)
        XCTAssertEqual(workspace.conversation(chat.id)?.destination?.baseURL, "https://legacy.invalid/v1")
        XCTAssertThrowsError(try settings.effectiveProfile(for: workspace.conversation(chat.id)))
        XCTAssertEqual(workspace.conversation(chat.id)?.messages.first?.text, "old history")
        let loaded = try await disk.load(); XCTAssertEqual(loaded.first?.version, 2)
        try FileManager.default.removeItem(at: dir)
    }
    func testSettingsLightDarkLayouts() async throws {
        let settings = AISettings(defaults: defaults, keys: AIFakeCredentials())
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("serverdash-ai-provider-qa")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for scheme in [ColorScheme.light, .dark] {
            let root = NSHostingView(rootView: AISettingsView(settings: settings).environment(\.colorScheme, scheme))
            root.frame = NSRect(x: 0, y: 0, width: 680, height: 780)
            let window = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = root; window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
            window.orderFront(nil); root.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(200))
            let rep = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds)); root.cacheDisplay(in: root.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(scheme == .light ? "settings-light.png" : "settings-dark.png"))
            window.orderOut(nil); window.contentView = nil
        }
    }
    func testHiddenPaneSecurityChangesCancelOnlyAffectedProvider() async throws {
        let keys = AIFakeCredentials(), settings = AISettings(defaults: defaults, keys: keys)
        try settings.save(fixtureProfile(.custom), key: "custom-key", makeDefault: true)
        try settings.save(fixtureProfile(.ollama), key: nil)
        let client = AIProviderControlledClient()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("serverdash-provider-isolation-\(UUID())")
        let workspace = AIWorkspace(disk: .init(directory: dir), client: client, settings: settings)
        await workspace.load()
        let server = ServerRecord(name: "fixture", host: "example.invalid", username: "demo")
        let first = TerminalSessionController(server: server, attachProcess: false)
        let second = TerminalSessionController(server: server, attachProcess: false)
        first.status = .connected; second.status = .connected
        workspace.prepare(first); workspace.prepare(second)
        let firstID = try XCTUnwrap(first.ai.conversationID)
        let oldSecond = try XCTUnwrap(second.ai.conversationID)
        second.ai.conversationID = try XCTUnwrap(workspace.selectProvider(.ollama, in: oldSecond)); workspace.prepare(second)
        let secondID = try XCTUnwrap(second.ai.conversationID)
        let firstProfile = settings.profile(.custom), secondProfile = settings.profile(.ollama)
        first.ai.authorize(generation: first.connectionGeneration, settings: firstProfile.authorizationRevision)
        second.ai.authorize(generation: second.connectionGeneration, settings: secondProfile.authorizationRevision)
        XCTAssertTrue(workspace.send(id: firstID, prompt: "first", profile: firstProfile, context: nil, target: nil))
        XCTAssertTrue(workspace.send(id: secondID, prompt: "second", profile: secondProfile, context: nil, target: nil))
        for _ in 0..<300 { if client.count == 2 { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(client.count, 2)
        var changed = firstProfile; changed.options.maxTokens = 100
        try settings.save(changed, key: nil)
        XCTAssertTrue(workspace.running.contains(firstID)); XCTAssertTrue(workspace.running.contains(secondID))
        XCTAssertTrue(first.ai.isAuthorized(generation: first.connectionGeneration, settings: firstProfile.authorizationRevision))
        changed.baseURL = "https://changed.invalid/v1"; try settings.save(changed, key: nil)
        XCTAssertFalse(workspace.running.contains(firstID)); XCTAssertTrue(workspace.running.contains(secondID))
        XCTAssertFalse(first.ai.isAuthorized(generation: first.connectionGeneration, settings: firstProfile.authorizationRevision))
        XCTAssertTrue(second.ai.isAuthorized(generation: second.connectionGeneration, settings: secondProfile.authorizationRevision))
        XCTAssertFalse(workspace.send(id: firstID, prompt: "stale", profile: firstProfile, context: nil, target: nil))
        client.completeAll("LATE")
        for _ in 0..<300 { if workspace.running.isEmpty { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(workspace.conversation(firstID)?.messages.last?.state, .interrupted)
        XCTAssertFalse(workspace.conversation(firstID)!.messages.contains { $0.text == "LATE" })
        XCTAssertEqual(workspace.conversation(secondID)?.messages.last?.state, .complete)
        XCTAssertEqual(workspace.conversation(secondID)?.messages.last?.provider, .ollama)
        workspace.stopAll(); await workspace.flushWrites(); try FileManager.default.removeItem(at: dir)
    }
}

private final class AIProviderControlledClient: AIStreamingClient, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncThrowingStream<String, Error>.Continuation] = []
    var count: Int { lock.withLock { continuations.count } }
    func stream(request: URLRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in lock.withLock { continuations.append(continuation) } }
    }
    func completeAll(_ text: String) { lock.withLock { for c in continuations { c.yield(text); c.finish() } } }
}

private final class AIProviderURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let provider = AIProviderID(rawValue: url.pathComponents.dropFirst().first ?? "") ?? .custom
        if url.lastPathComponent == "timeout" { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return }
        if url.lastPathComponent == "waiting" { return }
        let status = Int(url.lastPathComponent) ?? 200
        let mime = provider == .ollama ? "application/x-ndjson" : "text/event-stream"
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let reason = url.lastPathComponent == "limit" ? (provider == .gemini ? "MAX_TOKENS" : provider == .anthropic ? "max_tokens" : "length") : nil
        let data = (try? providerFixture(provider, text: "NETWORK 中文", reason: reason)) ?? Data()
        for byte in data { client?.urlProtocol(self, didLoad: Data([byte])) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class AIProviderTransportTests: XCTestCase {
    func testAllEightProtocolsThroughURLSessionWithoutNetwork() async throws {
        let client = OpenAICompatibleClient(protocolClasses: [AIProviderURLProtocol.self])
        for provider in AIProviderID.allCases {
            let request = URLRequest(url: URL(string: "https://fixture.invalid/\(provider.rawValue)/success")!)
            var text = ""
            for try await delta in client.stream(request: request, provider: provider) { text += delta }
            XCTAssertEqual(text, "NETWORK 中文", provider.rawValue)
        }
    }
    func testHTTPFailuresTimeoutAndLimitsKeepPartialText() async throws {
        let client = OpenAICompatibleClient(protocolClasses: [AIProviderURLProtocol.self])
        for provider in AIProviderID.allCases {
            for status in [401, 403, 429, 500] {
                let request = URLRequest(url: URL(string: "https://fixture.invalid/\(provider.rawValue)/\(status)")!)
                do { for try await _ in client.stream(request: request, provider: provider) {}; XCTFail("must fail") }
                catch { XCTAssertEqual(AIError.safeDescription(error), AIError.http(status).localizedDescription) }
            }
            var text = ""
            let request = URLRequest(url: URL(string: "https://fixture.invalid/\(provider.rawValue)/limit")!)
            do { for try await delta in client.stream(request: request, provider: provider) { text += delta }; XCTFail("must fail") }
            catch { XCTAssertEqual(AIError.safeDescription(error), AIError.outputLimit.localizedDescription) }
            XCTAssertEqual(text, "NETWORK 中文")
        }
        let request = URLRequest(url: URL(string: "https://fixture.invalid/custom/timeout")!)
        do { for try await _ in client.stream(request: request, provider: .custom) {}; XCTFail("must time out") }
        catch { XCTAssertEqual(AIError.safeDescription(error), AIError.network.localizedDescription) }
    }
    func testCancellationStopsWaitingNativeStream() async throws {
        let client = OpenAICompatibleClient(protocolClasses: [AIProviderURLProtocol.self])
        let task = Task {
            for try await _ in client.stream(request: URLRequest(url: URL(string: "https://fixture.invalid/ollama/waiting")!), provider: .ollama) { try Task.checkCancellation() }
        }
        try await Task.sleep(for: .milliseconds(30)); task.cancel()
        _ = await task.result
    }
}
