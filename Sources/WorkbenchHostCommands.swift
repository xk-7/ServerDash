import SwiftUI

struct WorkbenchHostActions {
    let canRefresh: Bool
    let add: () -> Void
    let refresh: () -> Void
    let retryFailed: () -> Void
}

private struct WorkbenchHostActionsKey: FocusedValueKey {
    typealias Value = WorkbenchHostActions
}

extension FocusedValues {
    var workbenchHostActions: WorkbenchHostActions? {
        get { self[WorkbenchHostActionsKey.self] }
        set { self[WorkbenchHostActionsKey.self] = newValue }
    }
}

struct WorkbenchHostCommands: Commands {
    @FocusedValue(\.workbenchHostActions) private var actions
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建主机…") { actions?.add() }
                .keyboardShortcut("n", modifiers: .command).disabled(actions == nil)
            Button("新建窗口") { openWindow(id: "main") }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(after: .toolbar) {
            Divider()
            Button("刷新全部服务器") { actions?.refresh() }
                .keyboardShortcut("r", modifiers: .command).disabled(actions?.canRefresh != true)
            Button("仅重试失败的监控") { actions?.retryFailed() }
                .keyboardShortcut("r", modifiers: [.command, .shift]).disabled(actions?.canRefresh != true)
        }
    }
}
