import Foundation

enum AIFinishReason: Sendable { case complete, outputLimit, refused, unsupported }
enum AIStreamEvent: Sendable { case text(String), finished(AIFinishReason) }

/// Stateless protocol translation. Never retries, changes providers, or forwards redirects.
struct AIProviderAdapter: Sendable {
    let provider: AIProviderID

    func request(profile: AIProviderProfile, key: String, messages: [AIWireMessage], model: AIModelDescriptor? = nil) throws -> URLRequest {
        guard profile.provider == provider else { throw AIError.configuration }
        try profile.validate(model: model)
        var base = try profile.validatedBaseURL()
        let system = messages.filter { $0.role == "system" }.map(\.content).joined(separator: "\n")
        let conversation = messages.filter { $0.role != "system" }
        var payload: [String: Any]
        switch provider {
        case .anthropic:
            base.appendPathComponent("messages")
            payload = ["model": profile.model, "messages": conversation.map { ["role": $0.role, "content": $0.content] },
                       "stream": true, "max_tokens": profile.options.maxTokens ?? 4096]
            if !system.isEmpty { payload["system"] = system }
            if let value = profile.options.temperature { payload["temperature"] = value }
        case .gemini:
            let id = profile.model.hasPrefix("models/") ? String(profile.model.dropFirst(7)) : profile.model
            guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }) else { throw AIError.configuration }
            base.appendPathComponent("models/" + id + ":streamGenerateContent")
            var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)!
            parts.queryItems = [.init(name: "alt", value: "sse")]; base = parts.url!
            payload = ["contents": conversation.map { ["role": $0.role == "assistant" ? "model" : "user", "parts": [["text": $0.content]]] }]
            if !system.isEmpty { payload["systemInstruction"] = ["parts": [["text": system]]] }
            var options: [String: Any] = [:]
            if let value = profile.options.temperature { options["temperature"] = value }
            if let value = profile.options.maxTokens { options["maxOutputTokens"] = value }
            if !options.isEmpty { payload["generationConfig"] = options }
        case .ollama:
            base.appendPathComponent("api/chat")
            payload = ["model": profile.model, "messages": messages.map { ["role": $0.role, "content": $0.content] }, "stream": true]
            var options: [String: Any] = [:]
            if let value = profile.options.temperature { options["temperature"] = value }
            if let value = profile.options.maxTokens { options["num_predict"] = value }
            if !options.isEmpty { payload["options"] = options }
        default:
            base.appendPathComponent("chat/completions")
            let reasoning = provider == .openAI && profile.temperatureMaximum == nil
            payload = ["model": profile.model, "messages": messages.map { ["role": reasoning && $0.role == "system" ? "developer" : $0.role, "content": $0.content] }, "stream": true]
            if provider == .openAI { payload["store"] = false }
            if let value = profile.options.temperature { payload["temperature"] = value }
            if let value = profile.options.maxTokens { payload[provider == .openAI ? "max_completion_tokens" : "max_tokens"] = value }
        }
        var request = try authorizedRequest(url: base, key: key)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(provider == .ollama ? "application/x-ndjson" : "text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard (request.httpBody?.count ?? 0) <= 256 * 1024 else { throw AIError.tooLarge }
        return request
    }

    private func authorizedRequest(url: URL, key: String) throws -> URLRequest {
        guard !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), !provider.requiresKey || !key.isEmpty else { throw AIError.keychain }
        var request = URLRequest(url: url)
        if provider == .anthropic { request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }
        if !key.isEmpty {
            switch provider {
            case .anthropic: request.setValue(key, forHTTPHeaderField: "x-api-key")
            case .gemini: request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            default: request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            }
        }
        return request
    }

    func modelRequest(profile: AIProviderProfile, key: String, cursor: String? = nil) throws -> URLRequest {
        guard profile.provider == provider, provider.discoverySupported else { throw AIError.modelDiscovery }
        var base = try profile.validatedBaseURL()
        var items: [URLQueryItem] = []
        switch provider {
        case .ollama: base.appendPathComponent("api/tags")
        case .qwen:
            guard base.path.hasSuffix("/compatible-mode/v1") else { throw AIError.modelDiscovery }
            base.deleteLastPathComponent(); base.deleteLastPathComponent(); base.appendPathComponent("api/v1/models")
            items = [.init(name: "page_size", value: "100"), .init(name: "page_no", value: cursor ?? "1"), .init(name: "capabilities", value: "TG")]
        case .anthropic:
            base.appendPathComponent("models"); items = [.init(name: "limit", value: "100")]
            if let cursor { items.append(.init(name: "after_id", value: cursor)) }
        case .gemini:
            base.appendPathComponent("models"); items = [.init(name: "pageSize", value: "100")]
            if let cursor { items.append(.init(name: "pageToken", value: cursor)) }
        default: base.appendPathComponent("models")
        }
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        if !items.isEmpty { parts.queryItems = items }
        var request = try authorizedRequest(url: parts.url!, key: key)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    func decodeModels(_ data: Data) throws -> (models: [AIModelDescriptor], next: String?) {
        guard data.count <= 4 * 1024 * 1024, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIError.modelDiscovery }
        let output = json["output"] as? [String: Any]
        let records: [[String: Any]]?
        switch provider {
        case .ollama, .gemini: records = json["models"] as? [[String: Any]]
        case .qwen: records = output?["models"] as? [[String: Any]]
        default: records = json["data"] as? [[String: Any]]
        }
        guard let records, records.count <= 10_000 else { throw AIError.modelDiscovery }
        var models: [AIModelDescriptor] = []
        for item in records {
            if provider == .gemini, !(item["supportedGenerationMethods"] as? [String] ?? []).contains("generateContent") { continue }
            if provider == .qwen, let capabilities = item["capabilities"] as? [String], !capabilities.contains("TG") { continue }
            var id = (provider == .gemini || provider == .ollama ? item["name"] : provider == .qwen ? item["model"] : item["id"]) as? String ?? ""
            if provider == .gemini && id.hasPrefix("models/") { id = String(id.dropFirst(7)) }
            guard !id.isEmpty, id.utf8.count <= 256, !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { continue }
            let name = item["display_name"] as? String ?? item["displayName"] as? String ?? item["name"] as? String ?? id
            let limit = (item["max_tokens"] as? Int ?? item["outputTokenLimit"] as? Int).flatMap { $0 > 0 ? $0 : nil }
            models.append(.init(id: id, name: String(name.prefix(256)), maxOutputTokens: limit, maxTemperature: item["maxTemperature"] as? Double))
        }
        var next: String?
        if provider == .anthropic, json["has_more"] as? Bool == true { next = json["last_id"] as? String; if next == nil { throw AIError.modelDiscovery } }
        if provider == .gemini { next = json["nextPageToken"] as? String }
        if provider == .qwen, let page = output?["page_no"] as? Int, let size = output?["page_size"] as? Int,
           let total = output?["total"] as? Int, page > 0, size > 0, page < 100, size <= 10_000, total > page * size { next = String(page + 1) }
        return (models, next)
    }

    func listModels(profile: AIProviderProfile, key: String, protocolClasses: [AnyClass]? = nil) async throws -> [AIModelDescriptor] {
        var models: [String: AIModelDescriptor] = [:], cursor: String?, visited: Set<String> = []
        let delegate = AIBoundedResponseDelegate()
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 60; config.protocolClasses = protocolClasses
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        for _ in 0..<100 {
            try Task.checkCancellation()
            let request = try modelRequest(profile: profile, key: key, cursor: cursor)
            let (bytes, response) = try await session.bytes(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw AIError.network }
            guard (200..<300).contains(http.statusCode) else { throw AIError.http(http.statusCode) }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 4 * 1024 * 1024 else { throw AIError.tooLarge }
                data.append(byte)
            }
            let page = try decodeModels(data)
            for model in page.models { models[model.id] = model }
            guard models.count <= 10_000 else { throw AIError.tooLarge }
            guard let next = page.next, !next.isEmpty else { return models.values.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending } }
            guard next.utf8.count <= 2048, visited.insert(next).inserted else { throw AIError.modelDiscovery }
            cursor = next
        }
        throw AIError.modelDiscovery
    }
}

private final class AIBoundedResponseDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        completionHandler(response.expectedContentLength > 4 * 1024 * 1024 ? .cancel : .allow)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.performDefaultHandling, nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Byte-bounded parser; reasoning blocks are deliberately not displayed or persisted.
struct AIProviderStreamDecoder {
    var provider: AIProviderID
    init(provider: AIProviderID) { self.provider = provider }
    private var line = Data(), event = Data()
    private var total = 0
    private var reason: AIFinishReason?
    private var textReceived = false
    private(set) var done = false
    mutating func receive(_ bytes: Data, emit: (AIStreamEvent) -> Void) throws {
        total += bytes.count
        guard total <= AIStreamDecoder.responseLimit else { throw AIError.tooLarge }
        for byte in bytes {
            if done { break }
            if byte == 10 {
                if line.last == 13 { line.removeLast() }
                if provider == .ollama {
                    if !line.isEmpty { try consume(line, emit: emit) }
                } else if line.isEmpty {
                    if !event.isEmpty { let data = event; event.removeAll(keepingCapacity: true); try consume(data, emit: emit) }
                } else if line.starts(with: Data("data:".utf8)) {
                    var data = line.dropFirst(5); if data.first == 32 { data = data.dropFirst() }
                    if !event.isEmpty { event.append(10) }; event.append(contentsOf: data)
                    guard event.count <= AIStreamDecoder.eventLimit else { throw AIError.tooLarge }
                }
                line.removeAll(keepingCapacity: true)
            } else {
                line.append(byte); guard line.count <= AIStreamDecoder.eventLimit else { throw AIError.tooLarge }
            }
        }
    }
    mutating func validateEnd(emit: (AIStreamEvent) -> Void) throws {
        if provider == .ollama, !done, !line.isEmpty { let data = line; line.removeAll(); try consume(data, emit: emit) }
        guard done else { throw AIError.incompleteStream }
    }
    private mutating func finish(_ reason: AIFinishReason, emit: (AIStreamEvent) -> Void) throws {
        guard textReceived || reason != .complete else { throw AIError.incompleteStream }
        done = true; emit(.finished(reason))
    }
    private mutating func consume(_ data: Data, emit: (AIStreamEvent) -> Void) throws {
        if data == Data("[DONE]".utf8) {
            guard ![.anthropic, .gemini, .ollama].contains(provider), let reason else { throw AIError.incompleteStream }
            try finish(reason, emit: emit); return
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIError.malformedStream }
        guard json["error"] == nil else { throw AIError.malformedStream }
        func mapped(_ value: String) -> AIFinishReason {
            switch value {
            case "stop", "end_turn", "stop_sequence", "STOP": return .complete
            case "length", "max_tokens", "MAX_TOKENS": return .outputLimit
            case "content_filter", "refusal", "SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII": return .refused
            default: return .unsupported
            }
        }
        var text: String?
        var terminal = false
        switch provider {
        case .anthropic:
            guard let type = json["type"] as? String else { throw AIError.malformedStream }
            if type == "error" { throw AIError.malformedStream }
            if type == "content_block_delta", let delta = json["delta"] as? [String: Any], delta["type"] as? String == "text_delta" { text = delta["text"] as? String }
            if type == "message_delta", let delta = json["delta"] as? [String: Any], let stop = delta["stop_reason"] as? String { reason = mapped(stop) }
            terminal = type == "message_stop"
        case .gemini:
            if let feedback = json["promptFeedback"] as? [String: Any], feedback["blockReason"] != nil { reason = .refused; terminal = true }
            if let candidates = json["candidates"] as? [[String: Any]], let candidate = candidates.first(where: { ($0["index"] as? Int ?? 0) == 0 }) {
                let content = candidate["content"] as? [String: Any]
                let parts = content?["parts"] as? [[String: Any]] ?? []
                text = parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
                if let stop = candidate["finishReason"] as? String { reason = mapped(stop); terminal = true }
            }
        case .ollama:
            text = (json["message"] as? [String: Any])?["content"] as? String
            if json["done"] as? Bool == true { reason = mapped(json["done_reason"] as? String ?? "stop"); terminal = true }
        default:
            guard let choices = json["choices"] as? [[String: Any]] else { throw AIError.malformedStream }
            if let choice = choices.first(where: { $0["index"] as? Int == 0 }) {
                let delta = choice["delta"] as? [String: Any]
                text = delta?["content"] as? String
                if let refusal = delta?["refusal"] as? String, !refusal.isEmpty { text = refusal; reason = .refused }
                if let stop = choice["finish_reason"] as? String, reason != .refused { reason = mapped(stop) }
            }
        }
        if let text, !text.isEmpty { textReceived = true; emit(.text(text)) }
        if terminal { guard let reason else { throw AIError.incompleteStream }; try finish(reason, emit: emit) }
    }
}
