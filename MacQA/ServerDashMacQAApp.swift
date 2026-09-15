import AppKit
import SwiftData
import SwiftUI

/// The QA executable deliberately has no SwiftUI WindowGroup. Handle the one
/// app-wide shortcut that normally belongs to a Settings scene in the actual
/// AppKit window responder chain instead of opening a second window.
@MainActor
private final class MacQAFixtureWindow: NSWindow {
    var onOpenSettings: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isComma = event.keyCode == 43 || event.charactersIgnoringModifiers == ","
        if modifiers.contains(.command), isComma {
            onOpenSettings?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// A separately identified, always-isolated executable for real-window macOS UI review.
@main
struct ServerDashMacQAApp: App {
    @NSApplicationDelegateAdaptor(MacTerminationDelegate.self) private var terminationDelegate
    @StateObject private var appState: AppState
    @StateObject private var monitorLayoutStore: MonitorLayoutStore
    @StateObject private var persistence: PersistenceSession

    init() {
        precondition(MacUIFixture.isEnabled, "ServerDashMacQA must be compiled with SERVERDASH_MAC_QA")
        AppTypography.registerBundledFonts()
        MacUIFixture.prepareEnvironment()
        let state = MacUIFixture.makeAppState()
        let session = PersistenceSession()
        let layoutStore = MonitorLayoutStore()
        let fixture = MacUIFixture.configuration
        if let container = session.container {
            do {
                try MacUIFixture.populate(container, app: state)
            } catch {
                session.openError = error
                session.container = nil
            }
        }
        _appState = StateObject(wrappedValue: state)
        _monitorLayoutStore = StateObject(wrappedValue: layoutStore)
        _persistence = StateObject(wrappedValue: session)
        terminationDelegate.appState = state
        terminationDelegate.fixtureWindowFactory = {
            let controller = NSHostingController(rootView: MacQAFixtureRootView(
                appState: state,
                monitorLayoutStore: layoutStore,
                persistence: session,
                fixture: fixture
            ))
            let window = MacQAFixtureWindow(
                contentRect: NSRect(
                    x: 0,
                    y: 0,
                    width: fixture.width,
                    height: fixture.height
                ),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.onOpenSettings = { state.showQASettings() }
            window.contentViewController = controller
            window.isReleasedWhenClosed = false
            return window
        }
    }

    var body: some Scene {
        // XCTest does not reliably materialize a SwiftUI window scene for this
        // dedicated executable. The delegate owns the one AppKit review window;
        // keeping only an inert Settings scene prevents a competing second root.
        Settings { EmptyView() }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { appState.showQASettings() }
                    .keyboardShortcut(",", modifiers: [.command])
            }
            CommandGroup(replacing: .newItem) {}
            SidebarCommands()
            TerminalCommands()
            WorkbenchHostCommands()
            CommandMenu("服务器") {
                Button("切换到监控") { appState.showDetailMode(.monitor) }
                    .keyboardShortcut("1", modifiers: [.command])
                Button("切换到终端") { appState.showDetailMode(.terminal) }
                    .keyboardShortcut("2", modifiers: [.command])
                Button("切换到 SFTP") { appState.showDetailMode(.sftp) }
                    .keyboardShortcut("3", modifiers: [.command])
            }
        }
    }
}

@MainActor
private struct MacQAFixtureRootView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var monitorLayoutStore: MonitorLayoutStore
    @ObservedObject var persistence: PersistenceSession
    let fixture: MacUIFixtureConfiguration

    var body: some View {
        ZStack {
            ServerDashBackdrop()

            Group {
                if let container = persistence.container {
                    fixtureContent
                        .environmentObject(appState)
                        .environmentObject(monitorLayoutStore)
                        .modelContainer(container)
                } else if let error = persistence.openError {
                    DatabaseRecoveryView(
                        error: error,
                        backupURL: persistence.lastBackupURL,
                        onRetry: persistence.open,
                        onRebuild: persistence.rebuild
                    )
                    .padding(AppleDesign.Spacing.lg)
                    .applePanel(padding: 0, radius: AppleDesign.Radius.card)
                    .padding(AppleDesign.Spacing.lg)
                } else {
                    ProgressView("正在准备隔离验收数据")
                }
            }
        }
        .font(AppTypography.body)
        .macGlassAccessibilityOverrides(
            reduceMotion: fixture.accessibility.reduceMotion,
            reduceTransparency: fixture.accessibility.reduceTransparency,
            contrast: fixture.accessibility.increaseContrast ? .increased : .standard
        )
        .preferredColorScheme(fixture.theme.colorScheme)
        .frame(minWidth: 900, minHeight: 620)
        .background(MacFixtureWindowSetup())
    }

    @ViewBuilder private var fixtureContent: some View {
        if fixture.page == .settings || appState.qaShowsSettings {
            ZStack(alignment: .topTrailing) {
                SettingsView()
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("macqa.settings.root")

                if fixture.page != .settings {
                    Button("返回工作台", systemImage: "xmark") {
                        appState.hideQASettings()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("macqa.settings.back")
                    .padding(AppleDesign.Spacing.md)
                }
            }
        } else if fixture.page == .rdp {
            MacUIFixtureRDPDesktopView()
        } else if fixture.page == .dialog {
            MonitorLayoutEditorView(
                serverID: UUID(uuidString: "B69D70E7-5A18-4B6F-9EC0-0012B4024001")!,
                snapshot: .empty
            )
        } else {
            ContentView()
        }
    }
}
