import AppKit
import Foundation

struct RDPFrame: Sendable {
    let width: Int
    let height: Int
    let pixels: Data
    var sequence: UInt64 = 0
    var dirtyRect: CGRect = .zero
    var colorDepth: Int = 32
    var connectionID: UUID = UUID()
}

enum RDPConnectionEvent: Sendable {
    case connected
    case ended(RDPFailure)
    case displayCapabilities(Int)
    case displayResizeRejected
}

struct RDPFailure: Error, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case transport, authentication, certificate, protocolError, cancelled, loggedOff }
    var kind: Kind
    var message: String
    static func native(_ code: UInt32) -> Self {
        switch code {
        case 0x00020006, 0x0002000D: .init(kind: .transport, message: "网络连接中断。")
        case 0x00020009, 0x00020014...0x0002001B, 0x0002000E...0x00020013:
            .init(kind: .authentication, message: "Windows 拒绝了身份验证，请核对用户名、域、密码及远程登录权限。")
        case 0x00020008, 0x0002000C, 0x0002001E:
            .init(kind: .certificate, message: "安全握手失败；需要 NLA/CredSSP 和 TLS 1.2 以上，不会降级连接。")
        case 0x0002000B: .init(kind: .cancelled, message: "连接已取消。")
        case 0, 0x0001000C, 0x00010001, 0x00010002:
            .init(kind: .loggedOff, message: "远程桌面已结束，请手动重新连接。")
        default: .init(kind: .protocolError, message: "RDP 连接失败（代码 \(String(code, radix: 16))）。未自动重试。")
        }
    }
}

protocol RDPConnectionEngine: AnyObject, Sendable {
    var hasActiveFileTransfers: Bool { get }
    func start(configuration: RDPConnectionConfiguration, password: String,
               trust: @escaping @Sendable (RDPCertificateEvidence) -> Bool,
               event: @escaping @Sendable (RDPConnectionEvent) -> Void)
    func cancel()
    func copyFrame() -> RDPFrame?
    func key(_ code: UInt16, down: Bool)
    func unicode(_ code: UInt16, down: Bool)
    func pointer(flags: UInt16, x: UInt16, y: UInt16)
    func monitors(_ values: [RDPMonitor])
}

extension RDPConnectionEngine { var hasActiveFileTransfers: Bool { false } }

final class NativeRDPConnectionEngine: RDPConnectionEngine, @unchecked Sendable {
    private let connectionID = UUID()
    private let lock = NSLock()
    private var client: SDRDPClient?
    private var cancelled = false
    var clipboard: RDPClipboardSession?
    private let worker = DispatchQueue(label: "com.serverdash.rdp.connection", qos: .userInitiated)

    func start(configuration: RDPConnectionConfiguration, password: String,
               trust: @escaping @Sendable (RDPCertificateEvidence) -> Bool,
               event: @escaping @Sendable (RDPConnectionEvent) -> Void) {
        worker.async { self.prepare(configuration: configuration, password: password, trust: trust, event: event) }
    }
    private func prepare(configuration: RDPConnectionConfiguration, password: String,
                         trust: @escaping @Sendable (RDPCertificateEvidence) -> Bool,
                         event: @escaping @Sendable (RDPConnectionEvent) -> Void) {
        lock.lock(); let shouldCancel = cancelled; lock.unlock()
        if shouldCancel { event(.ended(.init(kind: .cancelled, message: "连接已取消。"))); return }
        let settings = configuration.settings
        var scopedDirectories: [URL] = []
        var directories: [[String: Any]] = []
        do {
            for (index, share) in settings.shares.enumerated() {
                var stale = false
                let url = try URL(resolvingBookmarkData: share.bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
                guard !stale, url.startAccessingSecurityScopedResource() else { throw RDPValidationError.invalidShare }
                scopedDirectories.append(url)
                directories.append(["name": String(format: "SD%02d", index + 1), "url": url, "readOnly": share.readOnly])
            }
        } catch {
            scopedDirectories.forEach { $0.stopAccessingSecurityScopedResource() }; scopedDirectories = []
            event(.ended(.init(kind: .protocolError, message: "目录授权已失效，请编辑机器重新选择映射目录。"))); return
        }
        let config: [String: Any] = ["host": configuration.host, "port": configuration.port,
            "username": configuration.login.username, "domain": configuration.login.domain,
            "width": settings.width, "height": settings.height, "colorDepth": settings.colorDepth,
            "textClipboard": settings.textClipboard, "fileClipboard": settings.fileClipboard,
            "audio": settings.audio.rawValue, "bitmapCache": settings.bitmapCache,
            "disableWallpaper": settings.disableWallpaper, "disableWindowDrag": settings.disableWindowDrag,
            "disableMenuAnimations": settings.disableMenuAnimations, "disableThemes": settings.disableThemes, "shares": directories,
            "monitors": configuration.initialMonitors.map { ["x": $0.x, "y": $0.y, "width": $0.width, "height": $0.height, "primary": $0.primary] }]
        let native = SDRDPClient(configuration: config, password: password)
        native.verifyCertificate = { pem, host, port in
            guard host.lowercased() == configuration.host.lowercased(), port == configuration.port else { return false }
            do { return trust(try RDPCertificateVerifier.inspect(pem: pem, host: host)) }
            catch { event(.ended(.init(kind: .certificate, message: error.localizedDescription))); return false }
        }
        native.stateChanged = { state, code in
            if state == 1 { event(.connected) }
            else { event(.ended(state == 2 ? .init(kind: .cancelled, message: "连接已取消。") : .native(code))) }
        }
        native.displayCapabilities = { event(.displayCapabilities(Int($0))) }
        native.displayResizeRejected = { event(.displayResizeRejected) }
        clipboard?.attach(native)
        lock.lock()
        guard !cancelled, client == nil else {
            lock.unlock(); native.cancel()
            scopedDirectories.forEach { $0.stopAccessingSecurityScopedResource() }
            return
        }
        client = native
        lock.unlock()
        let leases = scopedDirectories; scopedDirectories = []
        worker.async {
            native.run()
            leases.forEach { $0.stopAccessingSecurityScopedResource() }
        }
    }
    func cancel() {
        lock.lock(); cancelled = true; let native = client; lock.unlock()
        clipboard?.cancel()
        native?.cancel()
    }
    var hasActiveFileTransfers: Bool { current()?.hasActiveFileTransfers() == true }
    private func current() -> SDRDPClient? { lock.lock(); defer { lock.unlock() }; return client }
    func copyFrame() -> RDPFrame? {
        guard let raw = current()?.copyFrame(), let width = raw["width"] as? Int,
              let height = raw["height"] as? Int, let pixels = raw["data"] as? Data,
              width > 0, height > 0, width <= 32766, height <= 32766,
              width * height <= RDPDisplayLayout.maximumPixels, pixels.count == width * height * 4 else { return nil }
        let rectangle = CGRect(x: raw["x"] as? Int ?? 0, y: raw["y"] as? Int ?? 0,
            width: raw["w"] as? Int ?? width, height: raw["h"] as? Int ?? height)
        return RDPFrame(width: width, height: height, pixels: pixels, sequence: raw["sequence"] as? UInt64 ?? 0,
            dirtyRect: rectangle.intersection(CGRect(x: 0, y: 0, width: width, height: height)), colorDepth: raw["colorDepth"] as? Int ?? 32,
            connectionID: connectionID)
    }
    func key(_ code: UInt16, down: Bool) { _ = current()?.sendKey(code, down: down) }
    func unicode(_ code: UInt16, down: Bool) { _ = current()?.sendUnicode(code, down: down) }
    func pointer(flags: UInt16, x: UInt16, y: UInt16) { _ = current()?.sendPointer(flags, x: x, y: y) }
    func monitors(_ values: [RDPMonitor]) {
        guard (try? RDPDisplayLayout.validate(values)) != nil else { return }
        _ = current()?.setMonitors(values.map { ["x": $0.x, "y": $0.y, "width": $0.width, "height": $0.height, "primary": $0.primary] })
    }
}

struct RDPTrustPrompt: Identifiable {
    let id = UUID()
    let evidence: RDPCertificateEvidence
    let previousFingerprint: String?
}

@MainActor
final class RDPSessionController: ObservableObject, Identifiable {
    enum State: String { case disconnected = "未连接", connecting = "连接中", connected = "已连接", reconnecting = "等待重连", failed = "连接失败" }
    let id: UUID
    let machineID: UUID
    @Published private(set) var state: State = .disconnected
    @Published private(set) var message = ""
    @Published private(set) var configuration: RDPConnectionConfiguration
    @Published private(set) var frame: RDPFrame?
    @Published private(set) var trustPrompt: RDPTrustPrompt?
    @Published private(set) var supportsResize = false
    @Published private(set) var needsPassword = false
    @Published var showingFullscreen = false
    @Published var keyboardCaptured = true
    let clipboard: RDPClipboardSession
    private var engine: (any RDPConnectionEngine)?
    private let factory: () -> any RDPConnectionEngine
    private let retrySleep: @Sendable (Int) async throws -> Void
    private var configurationProvider: () throws -> RDPConnectionConfiguration
    private var generation = UUID()
    private var retryTask: Task<Void, Never>?
    private var frameTask: Task<Void, Never>?
    private var trustGate: RDPTrustGate?
    private var password: String?
    private var passwordDestination: String?
    private var attempts = 0
    private var established = false
    private var closed = false
    private var resumeAfterSleep = false
    private var visible = false
    private var inputFocus: UUID?
    private var pressedKeys: Set<UInt16> = []
    private var fullscreenWindows: RDPFullscreenWindows?
    var hasActiveTransfer: Bool { clipboard.hasActiveTransfer || engine?.hasActiveFileTransfers == true }

    init(id: UUID = UUID(), configuration: RDPConnectionConfiguration, password: String? = nil,
         configurationProvider: @escaping () throws -> RDPConnectionConfiguration,
         factory: @escaping () -> any RDPConnectionEngine = { NativeRDPConnectionEngine() },
         retrySleep: @escaping @Sendable (Int) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.id = id; self.machineID = configuration.id; self.configuration = configuration
        self.password = password; self.passwordDestination = Self.credentialScope(configuration)
        self.configurationProvider = configurationProvider; self.factory = factory
        self.retrySleep = retrySleep
        self.clipboard = RDPClipboardSession(settings: configuration.settings)
    }
    private static func credentialScope(_ config: RDPConnectionConfiguration) -> String {
        config.destination + "|" + config.username + "|" + config.domain
    }
    func connect(password supplied: String? = nil, automatic: Bool = false) {
        guard !closed else { return }
        retire()
        if !automatic { attempts = 0; established = false }
        do {
            var latest = try configurationProvider()
            if latest.settings.screenIDs.count > 1 { latest.initialMonitors = try RDPScreenCatalog.layout(ids: latest.settings.screenIDs) }
            try latest.validate()
            if passwordDestination != Self.credentialScope(latest) { password = nil; established = false }
            if latest.credentialReference != configuration.credentialReference { password = nil }
            configuration = latest
            passwordDestination = Self.credentialScope(latest)
            if let supplied { password = supplied }
            if supplied == nil, let credential = latest.credentialReference { password = try RDPCredentials.read(credential) }
            guard let password else { state = .disconnected; needsPassword = true; message = "请输入 Windows 密码。"; return }
            needsPassword = false; state = .connecting; message = "正在建立 NLA/CredSSP 安全连接…"
            supportsResize = false; keyboardCaptured = true
            let requestID = generation
            let next = factory(); engine = next
            if let native = next as? NativeRDPConnectionEngine { native.clipboard = clipboard }
            clipboard.reset(settings: latest.settings)
            let gate = RDPTrustGate(); trustGate = gate
            next.start(configuration: latest, password: password, trust: { [weak self] evidence in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == requestID, !self.closed else { gate.resolve(false); return }
                    let previous = RDPCertificatePins.shared.fingerprint(host: latest.host, port: latest.port)
                    if previous == evidence.fingerprint && latest.settings.certificatePolicy != .strict {
                        gate.resolve(true); return
                    }
                    if (previous == nil || previous == evidence.fingerprint) && evidence.systemTrusted {
                        RDPCertificatePins.shared.save(evidence.fingerprint, host: latest.host, port: latest.port)
                        gate.resolve(true); return
                    }
                    if latest.settings.certificatePolicy == .strict { gate.resolve(false); return }
                    self.trustPrompt = RDPTrustPrompt(evidence: evidence, previousFingerprint: previous)
                    self.message = "请核对 RDP 证书指纹。"
                }
                return gate.wait()
            }, event: { [weak self] event in
                Task { @MainActor [weak self] in self?.receive(event, requestID: requestID) }
            })
            startFrames(engine: next, requestID: requestID)
        } catch {
            state = .failed; message = error.localizedDescription
        }
    }
    func resolveTrust(accept: Bool) {
        guard let prompt = trustPrompt else { return }
        trustPrompt = nil
        if accept {
            RDPCertificatePins.shared.save(prompt.evidence.fingerprint, host: configuration.host, port: configuration.port)
            trustGate?.resolve(true)
        } else {
            trustGate?.resolve(false)
            retire(); state = .disconnected; message = "证书确认已取消；可手动重试。"
        }
    }
    private func receive(_ event: RDPConnectionEvent, requestID: UUID) {
        guard !closed, generation == requestID else { return }
        switch event {
        case .connected:
            state = .connected; established = true; attempts = 0; message = "NLA/CredSSP · TLS 1.2+"
            clipboard.setActive(inputFocus != nil && NSApp.isActive)
            trustPrompt = nil
        case .displayCapabilities(let maximum):
            supportsResize = maximum > 0
        case .displayResizeRejected:
            message = "显示布局超出服务端能力或协商失败，保留原画面。"
        case .ended(let failure):
            let retry = established && configuration.settings.autoReconnect && failure.kind == .transport && attempts < 5
            retire()
            message = failure.message
            state = failure.kind == .cancelled || failure.kind == .loggedOff ? .disconnected : .failed
            if retry {
                let delay = 1 << attempts; attempts += 1; state = .reconnecting
                let nextID = generation
                message += " \(delay) 秒后重连（\(attempts)/5）。"
                retryTask = Task { [weak self, retrySleep] in
                    do { try await retrySleep(delay) } catch { return }
                    guard let self, self.generation == nextID, !self.closed else { return }
                    self.connect(automatic: true)
                }
            }
        }
    }
    private func startFrames(engine: any RDPConnectionEngine, requestID: UUID) {
        frameTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == requestID, !self.closed else { return }
                if self.visible {
                    let frame = await Task.detached(priority: .userInitiated) { engine.copyFrame() }.value
                    if self.generation == requestID, let frame { self.frame = frame }
                }
                do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
            }
        }
    }
    func setVisible(_ value: Bool) {
        visible = value
        clipboard.setActive(value && inputFocus != nil && state == .connected && NSApp.isActive)
        if !value { releaseKeys() }
    }
    func setInputFocus(_ id: UUID, focused: Bool) {
        if focused { inputFocus = id; visible = true }
        else if inputFocus == id { inputFocus = nil }
        clipboard.setActive(inputFocus != nil && state == .connected && NSApp.isActive)
    }
    func sendKey(_ code: UInt16, down: Bool) {
        guard state == .connected else { return }
        if down { pressedKeys.insert(code) } else { pressedKeys.remove(code) }
        engine?.key(code, down: down)
    }
    func sendText(_ text: String) {
        guard state == .connected, text.utf16.count <= 65536 else { return }
        for code in text.utf16 { engine?.unicode(code, down: true); engine?.unicode(code, down: false) }
    }
    func releaseKeys() {
        for key in pressedKeys { engine?.key(key, down: false) }
        pressedKeys.removeAll()
    }
    func sendSpecial(_ codes: [UInt16]) { codes.forEach { sendKey($0, down: true) }; codes.reversed().forEach { sendKey($0, down: false) } }
    func pointer(flags: UInt16, x: Int, y: Int) {
        guard state == .connected, (0...32765).contains(x), (0...32765).contains(y) else { return }
        engine?.pointer(flags: flags, x: UInt16(x), y: UInt16(y))
    }
    func resize(_ monitors: [RDPMonitor]) {
        do { try RDPDisplayLayout.validate(monitors) } catch { message = error.localizedDescription; return }
        guard supportsResize else { message = "服务端未提供动态分辨率通道，保留原画面尺寸。"; return }
        engine?.monitors(monitors)
    }
    func sleep() {
        resumeAfterSleep = state == .connected && configuration.settings.autoReconnect
        retire(); state = .disconnected; message = "电脑睡眠，连接及传输已中断。"
    }
    func wake() {
        guard resumeAfterSleep, !closed else { return }
        resumeAfterSleep = false; connect(automatic: true)
    }
    func disconnect() { resumeAfterSleep = false; established = false; retire(); state = .disconnected; message = "已断开；需要手动重连。" }
    func openFullscreen() {
        do {
            if fullscreenWindows == nil { fullscreenWindows = RDPFullscreenWindows(controller: self) }
            try fullscreenWindows?.open()
        } catch { message = error.localizedDescription }
    }
    func close() { closed = true; fullscreenWindows?.close(); fullscreenWindows = nil; disconnect(); password = nil; frame = nil }
    private func retire() {
        generation = UUID(); retryTask?.cancel(); retryTask = nil; frameTask?.cancel(); frameTask = nil
        trustGate?.resolve(false); trustGate = nil; trustPrompt = nil
        releaseKeys(); engine?.cancel(); engine = nil; clipboard.cancel()
    }
}
