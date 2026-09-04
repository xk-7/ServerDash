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

enum TerminalFontShortcut: Equatable {
    case increase
    case decrease
    case reset

    static func resolve(_ event: NSEvent) -> Self? {
        guard event.type == .keyDown else { return nil }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        let key = event.charactersIgnoringModifiers ?? ""
        if modifiers == .command {
            switch key {
            case "=", "+": return .increase
            case "-": return .decrease
            case "0": return .reset
            default: return nil
            }
        }
        if modifiers == [.command, .shift], event.characters == "+" || key == "+" || key == "=" {
            return .increase
        }
        return nil
    }
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
        hostView.onFontShortcut = { [weak self] shortcut in
            self?.performFontShortcut(shortcut)
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
        let validated = profile == appearanceProfile ? appearanceProfile : profile.validated()
        if appearanceProfile != validated {
            appearanceProfile = validated
        }
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

    func performFontShortcut(_ shortcut: TerminalFontShortcut) {
        let dark = hostView.usesDarkAppearance
        switch shortcut {
        case .increase: changeFontSize(by: 1, dark: dark)
        case .decrease: changeFontSize(by: -1, dark: dark)
        case .reset: resetFontSize(dark: dark)
        }
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
    var onFontShortcut: ((TerminalFontShortcut) -> Void)?
    private var hostKeyFailureDetector = TerminalHostKeyFailureDetector()

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let window, window.isKeyWindow, window.attachedSheet == nil,
           window.firstResponder === self,
           let shortcut = TerminalFontShortcut.resolve(event),
           let onFontShortcut {
            onFontShortcut(shortcut)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

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
    private struct Matcher {
        let transitions: [UInt8]
        let matches: [Bool]
    }

    private static let alphabetSize = 128
    private static let matcher: Matcher = {
        let warnings = [
            "remote host identification has changed",
            "offending ed25519 key",
            "offending ecdsa key",
            "offending rsa key"
        ]
        var transitions = [Array(repeating: UInt8(0), count: alphabetSize)]
        var matches = [false]

        // Share warning prefixes, then fill missing edges with suffix fallbacks.
        // UInt8 states keep this immutable, process-wide ASCII table small.
        for warning in warnings {
            var state = 0
            for byte in warning.utf8 {
                let symbol = Int(byte)
                if transitions[state][symbol] == 0 {
                    precondition(transitions.count < 256)
                    transitions[state][symbol] = UInt8(transitions.count)
                    transitions.append(Array(repeating: 0, count: alphabetSize))
                    matches.append(false)
                }
                state = Int(transitions[state][symbol])
            }
            matches[state] = true
        }

        var fallback = Array(repeating: UInt8(0), count: transitions.count)
        var pending = transitions[0].filter { $0 != 0 }
        var next = 0
        while next < pending.count {
            let state = Int(pending[next])
            next += 1
            for symbol in 0..<alphabetSize {
                let child = transitions[state][symbol]
                if child == 0 {
                    transitions[state][symbol] = transitions[Int(fallback[state])][symbol]
                } else {
                    let suffix = transitions[Int(fallback[state])][symbol]
                    fallback[Int(child)] = suffix
                    matches[Int(child)] = matches[Int(child)] || matches[Int(suffix)]
                    pending.append(child)
                }
            }
        }
        return Matcher(transitions: transitions.flatMap { $0 }, matches: matches)
    }()

    private var state: UInt8 = 0
    private var reported = false

    mutating func ingest(_ bytes: ArraySlice<UInt8>) -> Bool {
        guard !reported else { return false }
        let matcher = Self.matcher
        for byte in bytes {
            // OpenSSH warnings are ASCII; unrelated UTF-8 bytes break a match.
            let symbol = (65...90).contains(byte) ? byte + 32 : byte
            guard symbol < 128 else {
                state = 0
                continue
            }
            state = matcher.transitions[Int(state) * Self.alphabetSize + Int(symbol)]
            if matcher.matches[Int(state)] {
                reported = true
                return true
            }
        }
        return false
    }

    mutating func reset() {
        state = 0
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
    private var appliedDarkAppearance: Bool?
    private var appliedReduceMotion: Bool?
    var onTerminated: ((Int32?) -> Void)?
    var onHostKeyFailure: (() -> Void)?
    var onFontShortcut: ((TerminalFontShortcut) -> Void)?

    var usesDarkAppearance: Bool {
        appliedDarkAppearance ?? (effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }

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
        terminalView.onTerminated = { [weak self] code in
            self?.onTerminated?(code)
        }
        terminalView.onHostKeyFailure = { [weak self] in
            self?.onHostKeyFailure?()
        }
        terminalView.onFontShortcut = { [weak self] shortcut in
            self?.onFontShortcut?(shortcut)
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
            self.focusTerminal()
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
        let terminalFrame = NSRect(
            x: AppleDesign.Spacing.sm,
            y: AppleDesign.Spacing.xs,
            width: max(0, bounds.width - AppleDesign.Spacing.sm * 2),
            height: max(0, bounds.height - AppleDesign.Spacing.xs * 2)
        )
        if terminalView.frame != terminalFrame {
            terminalView.frame = terminalFrame
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        needsLayout = true
        terminalView.needsDisplay = true
        DispatchQueue.main.async { [weak self] in
            self?.focusTerminal()
        }
    }

    func focusTerminal() {
        guard let window, window.isKeyWindow, window.attachedSheet == nil else { return }
        window.makeFirstResponder(terminalView)
    }

    func showFindPanel() {
        focusTerminal()
        let action = NSMenuItem()
        action.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        terminalView.performFindPanelAction(action)
    }

    func applyAppearance(_ profile: TerminalAppearanceProfile, dark: Bool) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard profile != appearanceProfile ||
                appliedDarkAppearance != dark ||
                appliedReduceMotion != reduceMotion else { return }
        let profile = profile.validated()
        let previous = appearanceProfile
        let initial = appliedDarkAppearance == nil
        let previousThemeID = appliedDarkAppearance == true ? previous.darkThemeID : previous.lightThemeID
        let themeID = dark ? profile.darkThemeID : profile.lightThemeID
        let reduceMotionChanged = appliedReduceMotion != reduceMotion
        appearanceProfile = profile
        appliedDarkAppearance = dark
        appliedReduceMotion = reduceMotion

        // SwiftTerm's text-metric setters each rebuild fonts and resize the terminal.
        if initial || profile.fontPostScriptName != previous.fontPostScriptName || profile.fontSize != previous.fontSize {
            terminalView.font = TerminalFontCatalog.font(name: profile.fontPostScriptName, size: profile.fontSize)
        }
        if initial || profile.lineHeight != previous.lineHeight {
            terminalView.lineHeightMultiplier = profile.lineHeight
        }
        if initial || profile.letterSpacing != previous.letterSpacing {
            terminalView.characterSpacing = profile.letterSpacing
        }
        if initial || profile.scrollbarMode != previous.scrollbarMode {
            terminalView.scrollbarVisibility = Self.scrollbarVisibility(profile.scrollbarMode)
        }
        if initial || themeID != previousThemeID {
            let theme = TerminalThemeCatalog.shared.theme(id: themeID, dark: dark)
            terminalView.nativeForegroundColor = theme.foreground.nsColor
            terminalView.nativeBackgroundColor = theme.background.nsColor
            terminalView.caretColor = theme.cursor.nsColor
            terminalView.caretTextColor = theme.background.nsColor
            terminalView.selectedTextBackgroundColor = theme.selectionBackground.nsColor
            terminalView.selectedTextForegroundColor = theme.selectionForeground.nsColor
            terminalView.installColors(theme.ansiColors.map(Self.swiftTermColor))
            layer?.backgroundColor = theme.background.nsColor.cgColor
        }
        if initial || profile.activeCursorStyle != previous.activeCursorStyle ||
            profile.cursorBlinkEnabled != previous.cursorBlinkEnabled || reduceMotionChanged {
            terminalView.applyCursorStyle(Self.cursorStyle(
                shape: profile.activeCursorStyle,
                blinking: profile.cursorBlinkEnabled && !reduceMotion
            ))
        }
        if initial || profile.inactiveCursorStyle != previous.inactiveCursorStyle {
            terminalView.inactiveCursorStyle = Self.inactiveCursorStyle(profile.inactiveCursorStyle)
        }
        if initial || profile.terminalBellEnabled != previous.terminalBellEnabled {
            terminalView.bellEnabled = profile.terminalBellEnabled
        }
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
        do {
            let plan = try SystemOpenSSHConnectionProvider().launchPlan(
                for: config,
                purpose: .interactiveShell
            )
            let environment = plan.environment
                .map { "\($0.key)=\($0.value)" }
                .sorted()
            terminalView.startProcess(
                executable: plan.executable,
                args: plan.arguments,
                environment: environment,
                execName: "ssh"
            )
        } catch {
            EventLogStore.shared.append(
                serverID: config.id,
                module: .terminal,
                level: "error",
                message: "终端连接路线准备失败"
            )
            onTerminated?(-1)
        }
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
