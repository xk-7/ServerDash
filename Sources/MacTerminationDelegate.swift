import AppKit
import SwiftUI

private struct ShutdownProgressGlassBackground: View {
    var body: some View {
        ZStack {
            ServerDashBackdrop()
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .macGlassSurface(role: .overlay, cornerRadius: MacGlassTokens.cornerRadius)
                .padding(8)
        }
        .accessibilityHidden(true)
    }
}

@MainActor
final class ShutdownProgressPanel {
    private let panel: NSPanel
    private let label: NSTextField
    private weak var sheetParent: NSWindow?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 112),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = "正在退出 ServerDash"
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.standardWindowButton(.closeButton)?.isEnabled = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let progress = NSProgressIndicator()
        progress.style = .spinning
        progress.controlSize = .regular
        progress.appearance = NSAppearance(named: .darkAqua)
        progress.startAnimation(nil)
        progress.setAccessibilityLabel("退出进度")

        label = NSTextField(labelWithString: "正在保存编辑草稿…")
        label.font = NSFont(name: "PlusJakartaSans-Medium", size: NSFont.systemFontSize)
            ?? .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        label.textColor = .white
        label.setAccessibilityElement(true)
        label.setAccessibilityRole(.staticText)
        label.setAccessibilityLabel("退出状态")

        let stack = NSStackView(views: [progress, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.clear.cgColor
        let background = NSHostingView(rootView: ShutdownProgressGlassBackground())
        background.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(background)
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            background.topAnchor.constraint(equalTo: content.topAnchor),
            background.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])
        panel.contentView = content
    }

    func update(_ message: String) {
        label.stringValue = message
    }

    func present(relativeTo preferredParent: NSWindow? = nil) {
        guard !panel.isVisible else { return }
        if let parent = preferredParent ?? NSApp.keyWindow ?? NSApp.mainWindow, parent !== panel {
            sheetParent = parent
            parent.beginSheet(panel)
        } else {
            panel.center()
            panel.level = .floating
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func dismiss() {
        if let sheetParent, panel.sheetParent === sheetParent {
            sheetParent.endSheet(panel)
        }
        self.sheetParent = nil
        panel.orderOut(nil)
    }

    #if DEBUG
    var inspectionPanel: NSPanel { panel }
    #endif
}

struct ShutdownProgressScheduler: Sendable {
    typealias Start = @MainActor @Sendable (
        _ action: @escaping @MainActor @Sendable () -> Void
    ) -> Task<Void, Never>

    let start: Start
    static let delay: Duration = .milliseconds(300)

    static let production = ShutdownProgressScheduler { action in
        Task { @MainActor in
            do { try await Task.sleep(for: delay) }
            catch { return }
            guard !Task.isCancelled else { return }
            action()
        }
    }
}

@MainActor
final class ShutdownProgressDelayController {
    private let scheduler: ShutdownProgressScheduler
    private var task: Task<Void, Never>?
    private var generation: UUID?

    init(scheduler: ShutdownProgressScheduler = .production) {
        self.scheduler = scheduler
    }

    func schedule(_ action: @escaping @MainActor @Sendable () -> Void) {
        cancel()
        let token = UUID()
        generation = token
        task = scheduler.start { [weak self] in
            guard self?.generation == token else { return }
            action()
        }
    }

    func cancel() {
        generation = nil
        task?.cancel()
        task = nil
    }
}

@MainActor final class MacTerminationDelegate: NSObject, NSApplicationDelegate {
    weak var appState: AppState?
    private var waiting = false
    private var progressPanel: ShutdownProgressPanel?
    private let progressDelay = ShutdownProgressDelayController()

    #if SERVERDASH_MAC_QA
    var fixtureWindowFactory: (() -> NSWindow)?
    private var retainedFixtureWindow: NSWindow?

    /// XCTest can launch a second macOS process without issuing the normal
    /// reopen event. The QA app declares no window scene, so this delegate is the
    /// sole owner of its one deterministic, isolated review window.
    /// This code is not compiled into the shipping ServerDash application.
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard retainedFixtureWindow == nil, let factory = fixtureWindowFactory else { return }
        let window = factory()
        retainedFixtureWindow = window
        MacUIFixture.configureWindow(window)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }
    #endif

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        #if SERVERDASH_MAC_QA
        // The isolated fixture owns no user drafts, transfers, recordings, or
        // live connections. Exit synchronously so a screenshot matrix cannot
        // overlap two QA processes with different route arguments.
        return .terminateNow
        #else
        guard !waiting else { return .terminateLater }
        waiting = true
        scheduleProgress(message: "正在保存编辑草稿…")

        Task {
            while !(await RemoteEditorStore.shared.prepareForApplicationTermination()) {
                dismissProgress()
                let alert = NSAlert()
                alert.messageText = "尚未保存最新编辑草稿"
                alert.informativeText = "请检查磁盘空间和目录权限。重试保存，或取消退出以继续编辑。"
                alert.addButton(withTitle: "重试保存")
                alert.addButton(withTitle: "取消退出")
                if alert.runModal() != .alertFirstButtonReturn {
                    RemoteEditorStore.shared.cancelApplicationTermination()
                    waiting = false
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
                scheduleProgress(message: "正在保存编辑草稿…")
            }

            updateProgress(message: "正在安全关闭 ServerDash…")
            if let appState {
                _ = await appState.shutdownAndDrain()
            } else {
                RemoteEditorStore.shared.commitApplicationTermination()
            }
            dismissProgress()
            waiting = false
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
        #endif
    }

    private func scheduleProgress(message: String) {
        let panel = progressPanel ?? ShutdownProgressPanel()
        progressPanel = panel
        panel.update(message)
        progressDelay.schedule { [weak self, weak panel] in
            guard self?.waiting == true else { return }
            panel?.present()
        }
    }

    private func updateProgress(message: String) {
        progressPanel?.update(message)
    }

    private func dismissProgress() {
        progressDelay.cancel()
        progressPanel?.dismiss()
        progressPanel = nil
    }
}
