import AppKit

@MainActor final class MacTerminationDelegate: NSObject, NSApplicationDelegate {
    weak var appState: AppState?
    private var waiting = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !waiting else { return .terminateLater }
        waiting = true
        Task {
            while !(await RemoteEditorStore.shared.shutdownAndFlush()) {
                let alert = NSAlert()
                alert.messageText = "尚未保存最新编辑草稿"
                alert.informativeText = "请检查磁盘空间和目录权限。重试保存，或取消退出以继续编辑。"
                alert.addButton(withTitle: "重试保存")
                alert.addButton(withTitle: "取消退出")
                if alert.runModal() != .alertFirstButtonReturn {
                    waiting = false; sender.reply(toApplicationShouldTerminate: false); return
                }
            }
            appState?.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
