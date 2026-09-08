import Foundation
import SwiftUI

actor AIConversationDisk {
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ServerDash/AI", isDirectory: true)
    }
    let directory: URL
    private var revisions: [UUID: Int] = [:]
    init(directory: URL = AIConversationDisk.defaultDirectory) { self.directory = directory }

    func load() throws -> [AIConversation] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }
        do {
            let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                .filter { $0.pathExtension == "json" }
            guard files.count <= 50 else { throw AIError.storage }
            var conversations: [AIConversation] = []
            for file in files {
                let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                      let size = attributes.fileSize, size <= 4 * 1024 * 1024 else { throw AIError.storage }
                var chat = try JSONDecoder().decode(AIConversation.self, from: Data(contentsOf: file))
                guard (1...2).contains(chat.version), file.deletingPathExtension().lastPathComponent == chat.id.uuidString,
                      chat.messages.count <= 512, chat.messages.allSatisfy({ $0.text.utf8.count <= AIStreamDecoder.responseLimit }),
                      Set(chat.messages.map(\.id)).count == chat.messages.count else { throw AIError.storage }
                for index in chat.messages.indices where chat.messages[index].state == .streaming {
                    chat.messages[index].state = .interrupted
                }
                conversations.append(chat)
            }
            return conversations.sorted { $0.updatedAt > $1.updatedAt }
        } catch { throw AIError.storage }
    }

    func save(_ chat: AIConversation, revision: Int) throws {
        guard revision > (revisions[chat.id] ?? -1) else { return }
        do {
            let data = try JSONEncoder().encode(chat)
            guard data.count <= 4 * 1024 * 1024, chat.messages.count <= 512 else { throw AIError.tooLarge }
            let fm = FileManager.default
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw AIError.storage }
            let url = directory.appendingPathComponent(chat.id.uuidString + ".json")
            // The enclosing directory is private, including atomic-write temporary files.
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try data.write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            revisions[chat.id] = revision
        } catch let error as AIError { throw error }
        catch { throw AIError.storage }
    }
    func delete(_ id: UUID, revision: Int) throws {
        guard revision > (revisions[id] ?? -1) else { return }
        do {
            let url = directory.appendingPathComponent(id.uuidString + ".json")
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            revisions[id] = revision // A late streaming save must not resurrect deleted data.
        } catch { throw AIError.storage }
    }
}

@MainActor
final class AIPaneState: ObservableObject {
    @Published var conversationID: UUID?
    @Published var draft = ""
    @Published var selectedText: String?
    @Published private(set) var authorizedGeneration: UUID?
    private var authorizedSettings: UUID?
    var onInvalidate: (() -> Void)?
    func authorize(generation: UUID, settings: UUID) {
        authorizedGeneration = generation; authorizedSettings = settings
    }
    func isAuthorized(generation: UUID, settings: UUID) -> Bool {
        authorizedGeneration == generation && authorizedSettings == settings
    }
    func revoke() { authorizedGeneration = nil; authorizedSettings = nil }
    func invalidate() { revoke(); selectedText = nil; onInvalidate?() }
}

@MainActor
final class AIWorkspace: ObservableObject {
    private struct Owner { let paneID: UUID; weak var state: AIPaneState? }
    static let shared = AIWorkspace()
    @Published private(set) var conversations: [AIConversation] = []
    @Published private(set) var loaded = false
    @Published private(set) var running: Set<UUID> = []
    @Published private(set) var errors: [UUID: String] = [:]
    @Published var storageError: String?
    @Published var generalConversationID: UUID?
    @Published var generalDraft = ""
    @Published private(set) var commandTargets: [UUID: AICommandTarget] = [:]
    private let disk: AIConversationDisk
    private let client: any AIStreamingClient
    private let keyProvider: (() throws -> String)?
    let settings: AISettings
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var requests: [UUID: UUID] = [:]
    private var revision = 0
    private var loadTask: Task<[AIConversation], Error>?
    private var pendingText: [UUID: String] = [:]
    private var owners: [UUID: Owner] = [:]
    private var deleting: Set<UUID> = []
    private var writes: [UUID: Task<Void, Never>] = [:]

    init(disk: AIConversationDisk = AIConversationDisk(), client: any AIStreamingClient = OpenAICompatibleClient(),
         keyProvider: (() throws -> String)? = nil, settings: AISettings? = nil) {
        self.disk = disk; self.client = client; self.keyProvider = keyProvider
        self.settings = settings ?? .shared
        self.settings.observeSecurityChanges { [weak self] provider in
            guard let self else { return }
            for chat in self.conversations where chat.destination?.provider == provider {
                self.stop(chat.id); self.owners[chat.id]?.state?.revoke()
                self.owners[chat.id]?.state?.selectedText = nil
            }
        }
    }
    func load() async {
        guard !loaded else { return }
        if loadTask == nil { loadTask = Task { [disk] in try await disk.load() } }
        do {
            let result = try await loadTask!.value
            guard !loaded else { return }
            guard settings.isReady else { throw AIError.storage }
            conversations = result.map { value in
                var chat = value
                if chat.destination == nil {
                    chat.destination = settings.legacyDestination; chat.version = 2
                }
                return chat
            }
            loaded = true; storageError = nil; loadTask = nil
            for chat in conversations where result.first(where: { $0.id == chat.id })?.destination == nil { persist(chat) }
        } catch { storageError = AIError.storage.localizedDescription; loadTask = nil }
    }
    func conversation(_ id: UUID?) -> AIConversation? { conversations.first { $0.id == id } }

    @discardableResult func create(mode: AIMode, serverID: UUID? = nil, name: String? = nil, profile: AIProviderProfile? = nil) -> UUID? {
        guard loaded else { return nil }
        guard conversations.count < 50 else { storageError = AIError.limit.localizedDescription; return nil }
        if storageError == AIError.limit.localizedDescription { storageError = nil }
        let chat = AIConversation(version: 2, mode: mode, title: name ?? "新对话", serverID: serverID,
                                  destination: (profile ?? settings.profile(settings.defaultProvider)).destination)
        conversations.insert(chat, at: 0)
        persist(chat)
        return chat.id
    }
    func prepare(_ controller: TerminalSessionController) {
        guard loaded else { return }
        let state = controller.ai
        if conversation(state.conversationID) == nil || state.conversationID.map({ isOwnedByAnotherPane($0, paneID: controller.id) }) == true {
            state.conversationID = create(mode: .ops, serverID: controller.serverID, name: controller.serverName)
        }
        if let id = state.conversationID { owners[id] = Owner(paneID: controller.id, state: state) }
        state.onInvalidate = { [weak self, weak state] in
            if let id = state?.conversationID { self?.stop(id) }
        }
    }
    func isOwnedByAnotherPane(_ id: UUID, paneID: UUID?) -> Bool {
        guard let owner = owners[id], owner.state?.conversationID == id else { return false }
        return owner.paneID != paneID
    }

    func send(id: UUID, prompt: String, configuration: AIConfiguration, context: AITerminalContext?, target: AICommandTarget?) -> Bool {
        var profile = AIProviderProfile(provider: .custom)
        profile.baseURL = configuration.baseURL; profile.model = configuration.model
        profile.options = .init(temperature: nil, maxTokens: nil, historyMessages: min(50, max(1, configuration.contextMessages)))
        if let index = conversations.firstIndex(where: { $0.id == id }), conversations[index].messages.isEmpty {
            conversations[index].destination = profile.destination
        }
        return send(id: id, prompt: prompt, profile: profile, context: context, target: target)
    }

    /// Selection is owned by the conversation, never by a global current-provider variable.
    @discardableResult func selectProvider(_ provider: AIProviderID, in id: UUID) -> UUID? {
        guard let chat = conversation(id) else { return nil }
        let profile = settings.profile(provider)
        if chat.destination?.matches(profile) == true { return id }
        guard let next = create(mode: chat.mode, serverID: chat.serverID, profile: profile) else { return nil }
        stop(id)
        owners[id]?.state?.revoke(); owners[id]?.state?.selectedText = nil
        return next
    }
    func selectModel(_ model: String, in id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        stop(id); conversations[index].destination?.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        persist(conversations[index])
    }

    func send(id: UUID, prompt: String, profile: AIProviderProfile, context: AITerminalContext?, target: AICommandTarget?) -> Bool {
        guard loaded, !running.contains(id), !deleting.contains(id), let index = conversations.firstIndex(where: { $0.id == id }) else { return false }
        if keyProvider == nil {
            let current = settings.profile(profile.provider)
            guard settings.isReady, current.destination.matches(profile), current.authorizationRevision == profile.authorizationRevision else {
                errors[id] = AIError.destinationChanged.localizedDescription; return false
            }
        }
        guard conversations[index].destination?.matches(profile) == true, conversations[index].destination?.model == profile.model else {
            errors[id] = AIError.destinationChanged.localizedDescription; return false
        }
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return false }
        guard prompt.utf8.count <= 32 * 1024, conversations[index].messages.count <= 510 else {
            errors[id] = AIError.tooLarge.localizedDescription; return false
        }
        var chat = conversations[index]
        chat.messages.append(.init(role: .user, text: prompt))
        let request: URLRequest
        do {
            request = try AIProviderAdapter(provider: profile.provider).request(profile: profile, key: keyProvider?() ?? settings.key(for: profile),
                messages: AIRequestBuilder.messages(conversation: chat, count: profile.options.historyMessages, context: context),
                model: settings.models(for: profile).first { $0.id == profile.model })
            guard try JSONEncoder().encode(chat).count < 2 * 1024 * 1024 else { throw AIError.tooLarge }
        } catch { errors[id] = AIError.safeDescription(error); return false }
        let response = AIMessage(role: .assistant, text: "", state: .streaming, provider: profile.provider, model: profile.model)
        chat.messages.append(response)
        chat.updatedAt = .now
        if chat.messages.count == 2 { chat.title = String(prompt.prefix(40)) }
        conversations[index] = chat
        if chat.mode == .ops { commandTargets[response.id] = target }
        let requestID = UUID()
        requests[id] = requestID; running.insert(id); errors[id] = nil
        revision += 1
        let initialRevision = revision
        tasks[id] = Task { [weak self, disk, client] in
            do {
                try await disk.save(chat, revision: initialRevision)
                guard let self, self.requests[id] == requestID else { return }
                var lastFlush = ContinuousClock.now
                for try await delta in client.stream(request: request, provider: profile.provider) {
                    try Task.checkCancellation()
                    guard self.requests[id] == requestID else { return }
                    self.pendingText[id, default: ""] += delta
                    if lastFlush.duration(to: .now) >= .milliseconds(50) || (self.pendingText[id]?.utf8.count ?? 0) > 4096 {
                        self.flush(id, messageID: response.id); lastFlush = .now
                    }
                }
                guard self.requests[id] == requestID else { return }
                self.flush(id, messageID: response.id)
                self.finish(id, messageID: response.id, state: .complete)
            } catch {
                guard let self, self.requests[id] == requestID else { return }
                self.flush(id, messageID: response.id)
                self.errors[id] = AIError.safeDescription(error)
                self.finish(id, messageID: response.id, state: .interrupted)
            }
        }
        return true
    }
    private func append(_ text: String, chatID: UUID, messageID: UUID) {
        guard let chat = conversations.firstIndex(where: { $0.id == chatID }),
              let message = conversations[chat].messages.firstIndex(where: { $0.id == messageID }) else { return }
        conversations[chat].messages[message].text += text
    }
    private func flush(_ id: UUID, messageID: UUID) {
        append(pendingText.removeValue(forKey: id) ?? "", chatID: id, messageID: messageID)
    }
    private func finish(_ id: UUID, messageID: UUID, state: AIMessage.State) {
        running.remove(id); tasks[id] = nil; requests[id] = nil
        guard let chat = conversations.firstIndex(where: { $0.id == id }),
              let message = conversations[chat].messages.firstIndex(where: { $0.id == messageID }) else { return }
        conversations[chat].messages[message].state = state
        if state != .complete { commandTargets[messageID] = nil }
        persist(conversations[chat])
    }
    func stop(_ id: UUID) {
        guard running.contains(id) else { return }
        if let message = conversation(id)?.messages.last { flush(id, messageID: message.id) }
        tasks[id]?.cancel(); tasks[id] = nil; requests[id] = nil; running.remove(id)
        if let index = conversations.firstIndex(where: { $0.id == id }) {
            for message in conversations[index].messages.indices where conversations[index].messages[message].state == .streaming {
                conversations[index].messages[message].state = .interrupted
                commandTargets[conversations[index].messages[message].id] = nil
            }
            errors[id] = AIError.cancelled.localizedDescription
            persist(conversations[index])
        }
    }
    func stopAll() { for id in running { stop(id) } }
    func deleteMessage(_ messageID: UUID, in id: UUID) {
        stop(id)
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].messages.removeAll { $0.id == messageID }
        commandTargets[messageID] = nil
        persist(conversations[index])
    }
    func clear(_ id: UUID) {
        stop(id)
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        for message in conversations[index].messages { commandTargets[message.id] = nil }
        conversations[index].messages = []; errors[id] = nil
        persist(conversations[index])
    }
    func delete(_ id: UUID) async {
        guard !deleting.contains(id) else { return }
        deleting.insert(id)
        defer { deleting.remove(id) }
        stop(id)
        revision += 1
        do {
            try await disk.delete(id, revision: revision)
            if let chat = conversation(id) { for message in chat.messages { commandTargets[message.id] = nil } }
            conversations.removeAll { $0.id == id }; errors[id] = nil
            if storageError == AIError.limit.localizedDescription { storageError = nil }
            if generalConversationID == id { generalConversationID = nil }
        } catch { storageError = AIError.storage.localizedDescription }
    }
    private func persist(_ chat: AIConversation) {
        revision += 1
        let revision = revision
        let writeID = UUID()
        writes[writeID] = Task { [weak self, disk] in
            defer { self?.writes[writeID] = nil }
            do { try await disk.save(chat, revision: revision) }
            catch { self?.storageError = AIError.safeDescription(error is AIError ? error : AIError.storage) }
        }
    }
    func flushWrites() async { while let write = writes.values.first { await write.value } }
}
