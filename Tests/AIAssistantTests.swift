import AppKit
import SwiftUI
import XCTest
@testable import ServerDash

private func aiEvent(_ text: String) -> Data {
    let object: [String: Any] = ["choices": [["index": 0, "delta": ["content": text]]]]
    return Data("data: ".utf8) + (try! JSONSerialization.data(withJSONObject: object)) + Data("\n\n".utf8)
}
private let aiEnd = Data("data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".utf8)

final class AIProtocolTests: XCTestCase {
    func testEndpointValidationAndNormalization() throws {
        for base in ["https://example.com/v1", "https://example.com/v1/", "http://127.0.0.1:8000/v1", "http://[::1]:8000/v1"] {
            XCTAssertTrue(try AIConfiguration(baseURL: base, model: "model").endpoint().path.hasSuffix("/v1/chat/completions"))
        }
        for base in ["http://example.com/v1", "file:///etc/passwd", "https://user:key@example.com/v1", "https://example.com/v1?key=SECRET", "https://example.com/#SECRET", "invalid"] {
            XCTAssertThrowsError(try AIConfiguration(baseURL: base, model: "model").endpoint())
        }
        XCTAssertThrowsError(try AIConfiguration().endpoint())
    }
    func testRequestContractKeepsKeyOutOfJSONAndDisablesStorage() throws {
        let config = AIConfiguration(baseURL: "https://example.com/v1", model: "custom")
        let request = try AIRequestBuilder.request(configuration: config, key: "FAKE-API-KEY", messages: [.init(role: "user", content: "hello")])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer FAKE-API-KEY")
        let data = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["stream"] as? Bool, true); XCTAssertEqual(json["store"] as? Bool, false)
        XCTAssertNil(json["tools"]); XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("FAKE-API-KEY"))
        XCTAssertThrowsError(try AIRequestBuilder.request(configuration: config, key: "bad\r\nheader", messages: []))
    }
    func testEveryByteFragmentationHandlesChineseEmojiAndCRLF() throws {
        var decoder = AIStreamDecoder()
        let stream = Data(": keepalive\r\n\r\n".utf8) + aiEvent("中文 👩🏽‍💻 é") + aiEnd
        var text = ""
        for byte in stream { text += try decoder.receive(Data([byte])).joined() }
        XCTAssertEqual(text, "中文 👩🏽‍💻 é"); XCTAssertTrue(decoder.done)
        try decoder.validateEnd()
    }
    func testRoleOnlyUsageAndUnknownFieldsAreAccepted() throws {
        var decoder = AIStreamDecoder()
        let role = Data("data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\"}}],\"obfuscation\":\"x\"}\n\n".utf8)
        let usage = Data("data: {\"choices\":[],\"usage\":{\"total_tokens\":5}}\n\n".utf8)
        XCTAssertEqual(try decoder.receive(role + aiEvent("ok") + usage + aiEnd).joined(), "ok")
    }
    func testIncompleteMalformedAndOversizedStreamsFailWithoutEchoingBody() throws {
        var decoder = AIStreamDecoder()
        _ = try decoder.receive(aiEvent("partial"))
        XCTAssertThrowsError(try decoder.validateEnd())
        XCTAssertThrowsError(try decoder.receive(Data("data: SECRET-invalid\n\n".utf8))) { error in
            XCTAssertFalse(AIError.safeDescription(error).contains("SECRET"))
        }
        var large = AIStreamDecoder()
        XCTAssertThrowsError(try large.receive(Data(repeating: 65, count: AIStreamDecoder.eventLimit + 1)))
        var bomb = AIStreamDecoder()
        XCTAssertThrowsError(try bomb.receive(Data(repeating: 10, count: AIStreamDecoder.responseLimit + 1)))
    }
    func testTokenLimitAndToolCallsNeverBecomeCompletedCommands() throws {
        for reason in ["length", "content_filter", "tool_calls"] {
            var decoder = AIStreamDecoder()
            _ = try decoder.receive(aiEvent("partial"))
            let event = "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"\(reason)\"}]}\n\ndata: [DONE]\n\n"
            XCTAssertThrowsError(try decoder.receive(Data(event.utf8)))
        }
    }
    func testAutomaticAttachmentIsEphemeralAndGeneralNeverIncludesIt() throws {
        let user = AIMessage(role: .user, text: "analyze")
        let chat = AIConversation(mode: .ops, title: "test", messages: [user])
        let context = AITerminalContext(text: "PRIVATE-OUTPUT")
        let wire = try AIRequestBuilder.messages(conversation: chat, count: 20, context: context)
        XCTAssertTrue(wire.last!.content.contains("PRIVATE-OUTPUT"))
        XCTAssertEqual(wire.last!.role, "user")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(chat), as: UTF8.self).contains("PRIVATE-OUTPUT"))
        var general = chat; general.mode = .general
        XCTAssertFalse(try AIRequestBuilder.messages(conversation: general, count: 20, context: context).contains { $0.content.contains("PRIVATE-OUTPUT") })
    }
    func testHistoryUsesLastTwentyAndExcludesInterruptedReplies() throws {
        var chat = AIConversation(mode: .general, title: "test")
        for index in 0..<30 { chat.messages.append(.init(role: index.isMultiple(of: 2) ? .user : .assistant, text: "message\(index)")) }
        chat.messages.append(.init(role: .assistant, text: "NOT-COMPLETE", state: .interrupted))
        let wire = try AIRequestBuilder.messages(conversation: chat, count: 20, context: nil)
        XCTAssertEqual(wire.count, 21); XCTAssertEqual(wire[1].content, "message10")
        XCTAssertFalse(wire.contains { $0.content == "NOT-COMPLETE" })
    }
    func testContextIsBoundedOnUTF8AndStripsControlCharacters() {
        let value = AITerminalContext.bounded("\u{1b}\u{07}中文\n👩🏽‍💻" + String(repeating: "文", count: 20_000))
        XCTAssertLessThanOrEqual(value.utf8.count, AITerminalContext.byteLimit)
        XCTAssertTrue(value.hasPrefix("中文\n👩🏽‍💻")); XCTAssertFalse(value.contains("\u{1b}"))
    }
    func testCommandTargetAndNonShellBlocksCannotCrossConnections() {
        let pane = UUID(), generation = UUID()
        let target = AICommandTarget(paneID: pane, generation: generation, serverName: "fixture")
        XCTAssertTrue(target.matches(paneID: pane, generation: generation, connected: true))
        XCTAssertFalse(target.matches(paneID: UUID(), generation: generation, connected: true))
        XCTAssertFalse(target.matches(paneID: pane, generation: UUID(), connected: true))
        XCTAssertFalse(target.matches(paneID: pane, generation: generation, connected: false))
        for command in ["ls\r", "ls\nrm", "\u{1b}[200~ls", "ls\u{2028}rm", ""] { XCTAssertFalse(AICommandTarget.isSingleCommand(command)) }
        XCTAssertTrue(AICommandTarget.isSingleCommand("find /var/log -mtime -3 -size +100M -type f"))
        let blocks = AICodeBlock.parse("```bash\nls\n```\n```python\nprint('hi')\n```\n```cron\n0 2 * * * backup\n```\n```sh\nunfinished")
        XCTAssertEqual(blocks.count, 3); XCTAssertTrue(blocks[0].isShell); XCTAssertFalse(blocks[1].isShell); XCTAssertFalse(blocks[2].isShell)
    }
    func testValidDeltasSurviveLaterMalformedEventInSameNetworkChunk() {
        var decoder = AIStreamDecoder()
        var received = ""
        XCTAssertThrowsError(try decoder.receive(aiEvent("preserved") + Data("data: invalid\n\n".utf8), onDelta: { received += $0 }))
        XCTAssertEqual(received, "preserved")
    }
    func testErrorsDoNotExposeProviderBodiesOrCredentials() {
        XCTAssertEqual(AIError.safeDescription(NSError(domain: "KEY-SENTINEL", code: 1, userInfo: [NSLocalizedDescriptionKey: "PASSWORD-SENTINEL"])), AIError.network.localizedDescription)
        for code in [401, 403, 429, 500] { XCTAssertTrue(AIError.http(code).localizedDescription.contains(String(code))) }
    }
}

final class AIStorageTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("serverdash-ai-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    func testRoundTripRecoveryAndPrivatePermissions() async throws {
        let disk = AIConversationDisk(directory: directory)
        let chat = AIConversation(mode: .general, title: "中文", messages: [.init(role: .assistant, text: "partial", state: .streaming)])
        try await disk.save(chat, revision: 1)
        let loaded = try await disk.load()
        XCTAssertEqual(loaded.first?.messages.first?.state, .interrupted)
        let attrs = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(chat.id.uuidString + ".json").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testOutOfOrderWritesAndDeletedConversationCannotResurrect() async throws {
        let disk = AIConversationDisk(directory: directory)
        var chat = AIConversation(mode: .general, title: "new")
        try await disk.save(chat, revision: 2)
        chat.title = "old"; try await disk.save(chat, revision: 1)
        let loaded = try await disk.load(); XCTAssertEqual(loaded.first?.title, "new")
        try await disk.delete(chat.id, revision: 4)
        try await disk.save(chat, revision: 3)
        let empty = try await disk.load(); XCTAssertTrue(empty.isEmpty)
    }
    func testMalformedVersionAndSymlinkAreNotOverwritten() async throws {
        let disk = AIConversationDisk(directory: directory)
        var chat = AIConversation(mode: .general, title: "unsupported"); chat.version = 999
        let file = directory.appendingPathComponent(chat.id.uuidString + ".json")
        try JSONEncoder().encode(chat).write(to: file)
        do { _ = try await disk.load(); XCTFail("must reject version") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: directory)
        do { _ = try await disk.load(); XCTFail("must reject symlink") } catch {}
    }
    func testDirectoryFailureReportsStorageWithoutFileContents() async throws {
        let path = directory.appendingPathComponent("not-a-directory")
        try Data("PRIVATE".utf8).write(to: path)
        let disk = AIConversationDisk(directory: path)
        do { try await disk.save(.init(mode: .general, title: "test"), revision: 1); XCTFail("must fail") }
        catch { XCTAssertEqual(error.localizedDescription, AIError.storage.localizedDescription) }
    }
}

private final class AIControlledClient: AIStreamingClient, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncThrowingStream<String, Error>.Continuation] = []
    var count: Int { lock.withLock { continuations.count } }
    func stream(request: URLRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in lock.withLock { continuations.append(continuation) } }
    }
    func yield(_ text: String, at index: Int = 0) { lock.withLock { _ = continuations[index].yield(text) } }
    func finish(at index: Int = 0) { lock.withLock { continuations[index].finish() } }
    func fail() { lock.withLock { continuations[0].finish(throwing: AIError.network) } }
}

@MainActor
final class AIWorkspaceTests: XCTestCase {
    private func fixture() async throws -> (AIWorkspace, AIControlledClient, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("serverdash-ai-workspace-\(UUID())")
        let client = AIControlledClient()
        let workspace = AIWorkspace(disk: .init(directory: directory), client: client, keyProvider: { "FAKE" })
        await workspace.load()
        return (workspace, client, directory)
    }
    private let configuration = AIConfiguration(baseURL: "https://fixture.invalid/v1", model: "fixture")
    private func waitFor(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 { if predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Timed out waiting for controlled AI request")
    }
    private func clean(_ workspace: AIWorkspace, directory: URL) async throws {
        workspace.stopAll(); await workspace.flushWrites()
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    func testFiftyConversationsNoAutomaticEviction() async throws {
        let (workspace, _, directory) = try await fixture()
        for _ in 0..<50 { XCTAssertNotNil(workspace.create(mode: .general)) }
        let first = workspace.conversations.last?.id
        XCTAssertNil(workspace.create(mode: .general)); XCTAssertEqual(workspace.conversations.count, 50)
        XCTAssertEqual(workspace.conversations.last?.id, first)
        await workspace.delete(try XCTUnwrap(first))
        XCTAssertNil(workspace.storageError)
        XCTAssertNotNil(workspace.create(mode: .general))
        try await clean(workspace, directory: directory)
    }
    func testDuplicateSendBlockedAndPartialReplyRetainedOnFailure() async throws {
        let (workspace, client, directory) = try await fixture()
        let id = try XCTUnwrap(workspace.create(mode: .general))
        XCTAssertTrue(workspace.send(id: id, prompt: "hello", configuration: configuration, context: nil, target: nil))
        XCTAssertFalse(workspace.send(id: id, prompt: "duplicate", configuration: configuration, context: nil, target: nil))
        try await waitFor { client.count == 1 }
        client.yield("partial"); client.fail()
        try await waitFor { !workspace.running.contains(id) }
        XCTAssertEqual(workspace.conversation(id)?.messages.last?.text, "partial")
        XCTAssertEqual(workspace.conversation(id)?.messages.last?.state, .interrupted)
        try await clean(workspace, directory: directory)
    }
    func testCancelAndLateResponseCannotMutateNewRequest() async throws {
        let (workspace, client, directory) = try await fixture()
        let id = try XCTUnwrap(workspace.create(mode: .general))
        _ = workspace.send(id: id, prompt: "first", configuration: configuration, context: nil, target: nil)
        try await waitFor { client.count == 1 }; workspace.stop(id)
        _ = workspace.send(id: id, prompt: "second", configuration: configuration, context: nil, target: nil)
        try await waitFor { client.count == 2 }
        client.yield("STALE", at: 0); client.finish(at: 0)
        client.yield("LATEST", at: 1); client.finish(at: 1)
        try await waitFor { !workspace.running.contains(id) }
        XCTAssertEqual(workspace.conversation(id)?.messages.last?.text, "LATEST")
        XCTAssertFalse(workspace.conversation(id)!.messages.contains { $0.text.contains("STALE") })
        try await clean(workspace, directory: directory)
    }
    func testSixteenPaneConsentAndConnectionIsolation() async throws {
        let (workspace, client, directory) = try await fixture()
        let server = ServerRecord(name: "fixture", host: "example.invalid", username: "tester")
        let controllers = (0..<16).map { _ in TerminalSessionController(server: server, attachProcess: false) }
        let settings = UUID()
        for controller in controllers {
            controller.status = .connected; workspace.prepare(controller)
            controller.ai.authorize(generation: controller.connectionGeneration, settings: settings)
        }
        XCTAssertEqual(Set(controllers.compactMap { $0.ai.conversationID }).count, 16)
        XCTAssertTrue(workspace.isOwnedByAnotherPane(controllers[0].ai.conversationID!, paneID: controllers[1].id))
        let id = controllers[0].ai.conversationID!
        _ = workspace.send(id: id, prompt: "command", configuration: configuration, context: nil, target: .init(paneID: controllers[0].id, generation: controllers[0].connectionGeneration, serverName: server.name))
        try await waitFor { client.count == 1 }
        controllers[0].connectionGeneration = UUID()
        XCTAssertFalse(workspace.running.contains(id))
        XCTAssertFalse(controllers[0].ai.isAuthorized(generation: controllers[0].connectionGeneration, settings: settings))
        XCTAssertTrue(controllers[1].ai.isAuthorized(generation: controllers[1].connectionGeneration, settings: settings))
        XCTAssertFalse(controllers[1].ai.isAuthorized(generation: controllers[1].connectionGeneration, settings: UUID()))
        client.yield("LATE"); client.finish()
        try await clean(workspace, directory: directory)
    }
    func testDeleteDuringStreamAndReloadDoesNotRestoreConversation() async throws {
        let (workspace, client, directory) = try await fixture()
        let id = try XCTUnwrap(workspace.create(mode: .general))
        _ = workspace.send(id: id, prompt: "hello", configuration: configuration, context: nil, target: nil)
        try await waitFor { client.count == 1 }
        await workspace.delete(id); client.yield("LATE"); client.finish()
        await workspace.flushWrites()
        let loaded = try await AIConversationDisk(directory: directory).load()
        XCTAssertNil(workspace.conversation(id)); XCTAssertTrue(loaded.isEmpty)
        try await clean(workspace, directory: directory)
    }
    func testVisibleCaptureUsesParsedUnicodeAndExcludesHiddenScrollback() throws {
        let controller = TerminalSessionController(server: .init(name: "fixture", host: "example.invalid", username: "tester"), attachProcess: false)
        controller.hostView.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        controller.hostView.layoutSubtreeIfNeeded()
        let terminal = try XCTUnwrap(controller.hostView.tools.terminal)
        terminal.feed(text: "HIDDEN-OLD-OUTPUT\r\n")
        for _ in 0..<100 { terminal.feed(text: "new line\r\n") }
        terminal.feed(text: "\u{1b}[31m中文 👩🏽‍💻\u{1b}[0m")
        let capture = controller.hostView.aiVisibleText()
        XCTAssertFalse(capture.contains("HIDDEN-OLD-OUTPUT")); XCTAssertFalse(capture.contains("\u{1b}"))
        XCTAssertTrue(capture.contains("中文"), capture); XCTAssertTrue(capture.contains("👩🏽‍💻"), capture)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let noSelection = try XCTUnwrap(terminal.menu(for: event))
        XCTAssertFalse(try XCTUnwrap(noSelection.item(withTitle: "发送给 AI…")).isEnabled)
        terminal.selectAll()
        let selectedMenu = try XCTUnwrap(terminal.menu(for: event))
        XCTAssertTrue(try XCTUnwrap(selectedMenu.item(withTitle: "AI 解释…")).isEnabled)
    }
    func testAIPanelLightDarkAndGeneralLayoutFixtures() async throws {
        let (workspace, client, directory) = try await fixture()
        let server = ServerRecord(name: "Web Gateway · 演示", host: "example.invalid", username: "demo")
        let controller = TerminalSessionController(server: server, attachProcess: false)
        controller.status = .connected; workspace.prepare(controller)
        let id = try XCTUnwrap(controller.ai.conversationID)
        _ = workspace.send(id: id, prompt: "查找 /var/log 下最近 3 天修改过的大于 100MB 的文件", configuration: configuration, context: nil,
            target: .init(paneID: controller.id, generation: controller.connectionGeneration, serverName: server.name))
        try await waitFor { client.count == 1 }
        client.yield("可以使用以下只读查找命令：\n```bash\nfind /var/log -mtime -3 -size +100M -type f\n```\n-mtime -3：最近 3 天修改；-size +100M：大于 100 MiB。权限不足时只会报告无法读取的目录，请先核实需要搜索的范围。")
        client.finish(); try await waitFor { !workspace.running.contains(id) }
        let suite = "serverdash.ai.fixture.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let settings = AISettings(defaults: defaults)
        try settings.save(configuration, key: nil)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("serverdash-ai-qa", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (scheme, name, width) in [(ColorScheme.light, "ops-light", 390.0), (.dark, "ops-dark", 390.0), (.light, "ops-narrow", 340.0), (.light, "general-light", 640.0)] {
            let general = name == "general-light"
            let root = NSHostingView(rootView: AIChatView(mode: general ? .general : .ops, controller: general ? nil : controller, pane: controller.ai, workspace: workspace, settings: settings).environment(\.colorScheme, scheme))
            root.frame = NSRect(x: 0, y: 0, width: width, height: 760)
            let window = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = root; window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.orderFront(nil); root.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            let rep = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(name + ".png"))
            window.orderOut(nil); window.contentView = nil
        }
        defaults.removePersistentDomain(forName: suite)
        print("AI layout fixtures: \(folder.path)")
        try await clean(workspace, directory: directory)
    }
}

private final class AIMockURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = request.url!.path.contains("unauthorized") ? 401 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for byte in aiEvent("NETWORK-FIXTURE 中文") + aiEnd { client?.urlProtocol(self, didLoad: Data([byte])) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class AITransportTests: XCTestCase {
    func testURLSessionStreamsWithoutExternalNetwork() async throws {
        let client = OpenAICompatibleClient(protocolClasses: [AIMockURLProtocol.self])
        var text = ""
        for try await delta in client.stream(request: URLRequest(url: URL(string: "https://fixture.invalid/success")!)) { text += delta }
        XCTAssertEqual(text, "NETWORK-FIXTURE 中文")
    }
    func testHTTPAuthenticationFailureIsSanitized() async throws {
        let client = OpenAICompatibleClient(protocolClasses: [AIMockURLProtocol.self])
        do {
            for try await _ in client.stream(request: URLRequest(url: URL(string: "https://fixture.invalid/unauthorized")!)) {}
            XCTFail("must fail")
        } catch { XCTAssertEqual(error.localizedDescription, AIError.http(401).localizedDescription) }
    }
}
