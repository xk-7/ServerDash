import AppKit
import Foundation
import SwiftTerm

enum TerminalConnectionStatus: String, Sendable {
    case connecting
    case connected
    case disconnected
    case failed

    var title: String {
        switch self {
        case .connecting: "连接中"
        case .connected: "已连接"
        case .disconnected: "已断开"
        case .failed: "失败"
        }
    }

    var color: ColorToken {
        switch self {
        case .connecting: .warning
        case .connected: .live
        case .disconnected: .secondary
        case .failed: .error
        }
    }
}

enum ColorToken {
    case live, warning, error, secondary
}

@MainActor
final class TerminalSessionController: ObservableObject, Identifiable {
    let id: UUID
    let serverID: UUID
    let serverName: String
    let config: ServerConnectionConfig
    let createdAt: Date
    let hostView: TerminalHostView
    private let attachProcess: Bool
    private let initialAppearanceProfile: TerminalAppearanceProfile

    @Published var status: TerminalConnectionStatus = .connecting
    @Published var lastError: String?
    @Published var appearanceProfile: TerminalAppearanceProfile
    var onHostKeyFailure: ((UUID) -> Void)?

    var session: TerminalSession {
        TerminalSession(
            id: id,
            serverID: serverID,
            serverName: serverName,
            config: config,
            createdAt: createdAt,
            status: status,
            lastError: lastError
        )
    }

    init(
        server: ServerRecord,
        config: ServerConnectionConfig? = nil,
        attachProcess: Bool = true
    ) {
        let sessionID = UUID()
        id = sessionID
        serverID = server.id
        serverName = server.displayName
        self.config = config ?? server.connectionConfig
        createdAt = .now
        self.attachProcess = attachProcess
        let appearance = TerminalAppearanceStore.shared.profile.validated()
        initialAppearanceProfile = appearance
        appearanceProfile = appearance
        hostView = TerminalHostView(
            sessionID: sessionID,
            config: self.config,
            appearanceProfile: appearance
        )
        hostView.onTerminated = { [weak self] code in
            guard let self else { return }
            self.status = code == 0 ? .disconnected : .failed
            self.lastError = code == 0 ? "会话已结束" : "SSH 进程退出，代码 \(code ?? -1)"
            EventLogStore.shared.append(
                serverID: self.serverID,
                module: .terminal,
                level: "warn",
                message: self.lastError ?? "终端已断开"
            )
        }
        hostView.onHostKeyFailure = { [weak self] in
            guard let self else { return }
            self.onHostKeyFailure?(self.id)
        }
    }

    func start() {
        status = .connecting
        lastError = nil
        guard attachProcess else { return }
        hostView.startIfNeeded()
        status = .connected
        EventLogStore.shared.append(
            serverID: serverID,
            module: .terminal,
            message: "终端会话已启动"
        )
    }

    func reconnect() {
        status = .connecting
        lastError = "重连会建立新的 Shell，不会恢复远端前台进程。"
        guard attachProcess else { return }
        hostView.restart()
        status = .connected
    }

    func terminate() {
        if attachProcess {
            hostView.stop()
        }
        status = .disconnected
    }

    func applyAppearance(_ profile: TerminalAppearanceProfile, dark: Bool) {
        let validated = profile.validated()
        appearanceProfile = validated
        hostView.applyAppearance(validated, dark: dark)
    }

    func applyGlobalAppearance(dark: Bool) {
        applyAppearance(TerminalAppearanceStore.shared.profile, dark: dark)
    }

    func resetAppearance(dark: Bool) {
        applyAppearance(initialAppearanceProfile, dark: dark)
    }

    func changeFontSize(by delta: Double, dark: Bool) {
        var updated = appearanceProfile
        updated.fontSize = min(48, max(8, updated.fontSize + delta))
        applyAppearance(updated, dark: dark)
    }

    func resetFontSize(dark: Bool) {
        var updated = appearanceProfile
        updated.fontSize = initialAppearanceProfile.fontSize
        applyAppearance(updated, dark: dark)
    }
}

@MainActor
final class TerminalSessionRegistry: ObservableObject {
    @Published private(set) var controllers: [TerminalSessionController] = []

    var sessions: [TerminalSession] {
        controllers.map(\.session)
    }

    func controller(for id: UUID) -> TerminalSessionController? {
        controllers.first { $0.id == id }
    }

    func open(
        for server: ServerRecord,
        forceNew: Bool,
        config: ServerConnectionConfig? = nil,
        onHostKeyFailure: ((UUID) -> Void)? = nil
    ) -> TerminalSessionController {
        let interval = PerformanceTrace.begin(.terminalOpen)
        defer { PerformanceTrace.end(interval) }
        if !forceNew, let existing = controllers.first(where: { $0.serverID == server.id }) {
            existing.onHostKeyFailure = onHostKeyFailure
            return existing
        }
        let controller = TerminalSessionController(server: server, config: config)
        controller.onHostKeyFailure = onHostKeyFailure
        controllers.append(controller)
        controller.start()
        return controller
    }

    func close(_ id: UUID) {
        guard let index = controllers.firstIndex(where: { $0.id == id }) else { return }
        controllers[index].terminate()
        controllers.remove(at: index)
    }

    func closeAll(for serverID: UUID) {
        for controller in controllers where controller.serverID == serverID {
            controller.terminate()
        }
        controllers.removeAll { $0.serverID == serverID }
    }

    func terminateAll() {
        controllers.forEach { $0.terminate() }
        controllers.removeAll()
    }

    func registerForTesting(_ controller: TerminalSessionController) {
        controllers.append(controller)
    }
}

final class ServerDashTerminalView: LocalProcessTerminalView {
    var onTerminated: ((Int32?) -> Void)?
    var onHostKeyFailure: (() -> Void)?
    private var hostKeyFailureDetector = TerminalHostKeyFailureDetector()

    override func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        super.processTerminated(source, exitCode: exitCode)
        onTerminated?(exitCode)
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        if hostKeyFailureDetector.ingest(slice) {
            onHostKeyFailure?()
        }
    }

    func resetHostKeyFailureDetection() {
        hostKeyFailureDetector.reset()
    }
}

struct TerminalHostKeyFailureDetector {
    private static let maximumTailBytes = 4_096
    private var tail = Data()
    private var reported = false

    mutating func ingest(_ bytes: ArraySlice<UInt8>) -> Bool {
        guard !reported else { return false }
        tail.append(contentsOf: bytes)
        if tail.count > Self.maximumTailBytes {
            tail.removeFirst(tail.count - Self.maximumTailBytes)
        }
        let text = String(decoding: tail, as: UTF8.self).lowercased()
        guard text.contains("remote host identification has changed") ||
                text.contains("offending ed25519 key") ||
                text.contains("offending ecdsa key") ||
                text.contains("offending rsa key") else {
            return false
        }
        reported = true
        tail.removeAll(keepingCapacity: false)
        return true
    }

    mutating func reset() {
        tail.removeAll(keepingCapacity: false)
        reported = false
    }
}

final class TerminalHostView: NSView {
    private let terminalView = ServerDashTerminalView(frame: .zero)
    private let sessionID: UUID
    private let config: ServerConnectionConfig
    private var didStart = false
    private var commandObserver: NSObjectProtocol?
    private var appearanceProfile: TerminalAppearanceProfile
    var onTerminated: ((Int32?) -> Void)?
    var onHostKeyFailure: (() -> Void)?

    init(
        sessionID: UUID,
        config: ServerConnectionConfig,
        appearanceProfile: TerminalAppearanceProfile
    ) {
        self.sessionID = sessionID
        self.config = config
        self.appearanceProfile = appearanceProfile
        super.init(frame: .zero)
        wantsLayer = true
        terminalView.autoresizingMask = [.width, .height]
        terminalView.onTerminated = { [weak self] code in
            self?.onTerminated?(code)
        }
        terminalView.onHostKeyFailure = { [weak self] in
            self?.onHostKeyFailure?()
        }
        addSubview(terminalView)
        applyAppearance(
            appearanceProfile,
            dark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        )
        commandObserver = NotificationCenter.default.addObserver(
            forName: TerminalCommandBus.notification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  notification.userInfo?["sessionID"] as? UUID == self.sessionID,
                  let command = notification.userInfo?["command"] as? String else {
                return
            }
            self.terminalView.send(txt: command)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let commandObserver {
            NotificationCenter.default.removeObserver(commandObserver)
        }
    }

    override func layout() {
        super.layout()
        terminalView.frame = bounds
    }

    func applyAppearance(_ profile: TerminalAppearanceProfile, dark: Bool) {
        let profile = profile.validated()
        appearanceProfile = profile
        let theme = TerminalThemeCatalog.shared.theme(
            id: dark ? profile.darkThemeID : profile.lightThemeID,
            dark: dark
        )
        terminalView.font = TerminalFontCatalog.font(
            name: profile.fontPostScriptName,
            size: profile.fontSize
        )
        terminalView.lineHeightMultiplier = profile.lineHeight
        terminalView.characterSpacing = profile.letterSpacing
        terminalView.nativeForegroundColor = theme.foreground.nsColor
        terminalView.nativeBackgroundColor = theme.background.nsColor
        terminalView.caretColor = theme.cursor.nsColor
        terminalView.caretTextColor = theme.background.nsColor
        terminalView.selectedTextBackgroundColor = theme.selectionBackground.nsColor
        terminalView.selectedTextForegroundColor = theme.selectionForeground.nsColor
        terminalView.installColors(theme.ansiColors.map(Self.swiftTermColor))
        terminalView.applyCursorStyle(
            Self.cursorStyle(
                shape: profile.activeCursorStyle,
                blinking: profile.cursorBlinkEnabled &&
                    !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            )
        )
        terminalView.inactiveCursorStyle = Self.inactiveCursorStyle(
            profile.inactiveCursorStyle
        )
        terminalView.scrollbarVisibility = Self.scrollbarVisibility(
            profile.scrollbarMode
        )
        terminalView.bellEnabled = profile.terminalBellEnabled
        layer?.backgroundColor = theme.background.nsColor.cgColor
        terminalView.needsDisplay = true
    }

    func startIfNeeded() {
        guard !didStart else { return }
        didStart = true
        startSSH()
    }

    func restart() {
        stop()
        didStart = true
        startSSH()
    }

    func stop() {
        if didStart {
            terminalView.terminate()
        }
        didStart = false
    }

    private func startSSH() {
        terminalView.resetHostKeyFailureDetection()
        let arguments = SSHSupport.arguments(
            for: config,
            strictHostChecking: "yes"
        )
        let environment = SSHSupport.environment(for: config)
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        terminalView.startProcess(
            executable: "/usr/bin/ssh",
            args: arguments,
            environment: environment,
            execName: "ssh"
        )
    }

    private static func swiftTermColor(_ color: TerminalColor) -> SwiftTerm.Color {
        let rgb = color.nsColor.usingColorSpace(.sRGB) ?? color.nsColor
        return SwiftTerm.Color(
            red: UInt16(max(0, min(65_535, rgb.redComponent * 65_535))),
            green: UInt16(max(0, min(65_535, rgb.greenComponent * 65_535))),
            blue: UInt16(max(0, min(65_535, rgb.blueComponent * 65_535)))
        )
    }

    private static func cursorStyle(
        shape: TerminalCursorShape,
        blinking: Bool
    ) -> SwiftTerm.CursorStyle {
        switch (shape, blinking) {
        case (.block, true): .blinkBlock
        case (.block, false): .steadyBlock
        case (.underline, true): .blinkUnderline
        case (.underline, false): .steadyUnderline
        case (.bar, true): .blinkBar
        case (.bar, false): .steadyBar
        }
    }

    private static func inactiveCursorStyle(
        _ style: TerminalInactiveCursorStyle
    ) -> SwiftTerm.InactiveCursorStyle {
        switch style {
        case .outline: .outline
        case .block: .block
        case .bar: .bar
        case .underline: .underline
        case .hidden: .hidden
        }
    }

    private static func scrollbarVisibility(
        _ mode: TerminalScrollbarMode
    ) -> SwiftTerm.ScrollbarVisibility {
        switch mode {
        case .automatic: .automatic
        case .visible: .visible
        case .hidden: .hidden
        }
    }
}
