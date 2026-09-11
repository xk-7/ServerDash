import AppKit
import SwiftData
import SwiftUI

@main
struct ServerDashApp: App {
    @NSApplicationDelegateAdaptor(MacTerminationDelegate.self) private var terminationDelegate
    @StateObject private var appState: AppState
    @StateObject private var monitorLayoutStore: MonitorLayoutStore
    @StateObject private var persistence: PersistenceSession
    @AppStorage("appAppearance") private var appAppearanceRawValue = AppAppearance.system.rawValue

    init() {
        MacUIFixture.prepareEnvironment()
        LaunchPerformanceTracker.shared.start()
        let state = MacUIFixture.isEnabled ? MacUIFixture.makeAppState() : AppState()
        let session = PersistenceSession()
        if MacUIFixture.isEnabled, let container = session.container {
            do { try MacUIFixture.populate(container, app: state) }
            catch { session.openError = error; session.container = nil }
        }
        _appState = StateObject(wrappedValue: state)
        _monitorLayoutStore = StateObject(wrappedValue: MonitorLayoutStore())
        _persistence = StateObject(wrappedValue: session)
        terminationDelegate.appState = state
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            Group {
                if let container = persistence.container {
                    ContentView()
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
                } else {
                    ProgressView("正在打开数据库")
                }
            }
            .onAppear {
                LaunchPerformanceTracker.shared.markFirstFrame()
            }
            .onReceive(
                NSWorkspace.shared.notificationCenter.publisher(
                    for: NSWorkspace.willSleepNotification
                )
            ) { _ in
                appState.terminalRegistry.controllers.forEach { $0.recording.stop(reason: "sleep") }
                AIWorkspace.shared.stopAll()
                appState.rdpControllers.values.forEach { $0.sleep() }
                appState.setMonitoringSleeping(true)
            }
            .onReceive(
                NSWorkspace.shared.notificationCenter.publisher(
                    for: NSWorkspace.didWakeNotification
                )
            ) { _ in
                appState.setMonitoringSleeping(false)
                appState.rdpControllers.values.forEach { $0.wake() }
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: .NSProcessInfoPowerStateDidChange
                )
            ) { _ in
                appState.refreshMonitoringPowerMode()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                AIWorkspace.shared.stopAll()
            }
            .preferredColorScheme(appAppearance.colorScheme)
            .frame(minWidth: 900, minHeight: 620)
            .background(MacFixtureWindowSetup())
        }
        .defaultSize(width: 1080, height: 760)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            SidebarCommands()
            TerminalCommands()
            WorkbenchHostCommands()
            CommandMenu("服务器") {
                Button("切换到监控") {
                    appState.showDetailMode(.monitor)
                }
                .keyboardShortcut("1", modifiers: [.command])
                Button("切换到终端") {
                    appState.showDetailMode(.terminal)
                }
                .keyboardShortcut("2", modifiers: [.command])
                Button("切换到 SFTP") {
                    appState.showDetailMode(.sftp)
                }
                .keyboardShortcut("3", modifiers: [.command])
            }
            CommandMenu("外观") {
                Picker("外观模式", selection: $appAppearanceRawValue) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Label(appearance.title, systemImage: appearance.symbol)
                            .tag(appearance.rawValue)
                    }
                }
            }
            AIAssistantCommands()
        }

        Window("AI 通用对话", id: "ai-general") {
            AIGeneralWindow().preferredColorScheme(appAppearance.colorScheme)
        }.defaultSize(width: 640, height: 760)

        Settings {
            if let container = persistence.container {
                SettingsView()
                    .environmentObject(appState)
                    .environmentObject(monitorLayoutStore)
                    .modelContainer(container)
            } else {
                Text("请先完成数据库恢复。").padding()
            }
        }
    }

    private var appAppearance: AppAppearance {
        AppAppearance(rawValue: appAppearanceRawValue) ?? .system
    }
}

private struct AIAssistantCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandMenu("AI") {
            Button("打开通用对话") { openWindow(id: "ai-general") }
        }
    }
}
