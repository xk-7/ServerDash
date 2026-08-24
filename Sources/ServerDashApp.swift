import AppKit
import SwiftData
import SwiftUI

@main
struct ServerDashApp: App {
    @StateObject private var appState: AppState
    @StateObject private var monitorLayoutStore: MonitorLayoutStore
    @StateObject private var persistence: PersistenceSession
    @AppStorage("appAppearance") private var appAppearanceRawValue = AppAppearance.system.rawValue

    init() {
        LaunchPerformanceTracker.shared.start()
        _appState = StateObject(wrappedValue: AppState())
        _monitorLayoutStore = StateObject(wrappedValue: MonitorLayoutStore())
        _persistence = StateObject(wrappedValue: PersistenceSession())
    }

    var body: some Scene {
        WindowGroup {
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
                appState.setMonitoringSleeping(true)
            }
            .onReceive(
                NSWorkspace.shared.notificationCenter.publisher(
                    for: NSWorkspace.didWakeNotification
                )
            ) { _ in
                appState.setMonitoringSleeping(false)
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: .NSProcessInfoPowerStateDidChange
                )
            ) { _ in
                appState.refreshMonitoringPowerMode()
            }
            .preferredColorScheme(appAppearance.colorScheme)
            .frame(minWidth: 900, minHeight: 620)
        }
        .defaultSize(width: 1080, height: 760)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            SidebarCommands()
            CommandMenu("服务器") {
                Button("切换到监控") {
                    appState.detailMode = .monitor
                }
                .keyboardShortcut("1", modifiers: [.command])
                Button("切换到终端") {
                    appState.detailMode = .terminal
                }
                .keyboardShortcut("2", modifiers: [.command])
                Button("切换到 SFTP") {
                    appState.detailMode = .sftp
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
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(monitorLayoutStore)
        }
    }

    private var appAppearance: AppAppearance {
        AppAppearance(rawValue: appAppearanceRawValue) ?? .system
    }
}
