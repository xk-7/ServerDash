#if os(macOS)
import AppKit
import SwiftUI

struct DesktopFileSettingsView: View {
    @AppStorage("sftpPromptDirectorySync") private var promptSync = true
    @AppStorage("sftpDownloadDirectory") private var downloadDirectory = ""
    @AppStorage("sftpEditorFileLimit") private var fileLimit = 5
    @AppStorage("sftpEditorTotalMB") private var totalMB = 10
    @ObservedObject private var sync = DirectorySyncStore.shared
    var body: some View {
        Form {
            Section("SFTP 下载") {
                HStack {
                    TextField("默认下载目录（留空时每次询问）", text: $downloadDirectory)
                    Button("选择…") {
                        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
                        if panel.runModal() == .OK, let url = panel.url { downloadDirectory = url.path }
                    }
                    Button("每次询问") { downloadDirectory = "" }
                }
            }
            Section("远程文件编辑器") {
                Stepper("最多打开 \(fileLimit) 个文件", value: $fileLimit, in: 1...32)
                Stepper("文件总大小上限 \(totalMB) MB", value: $totalMB, in: 1...100)
                Text("正文通过 SFTP 传输；保存前检查远端版本。本地草稿存放在此 Mac，不参与配置同步。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("打开编辑器与恢复草稿") { showingEditor = true }
                Button("本地副本与上传修改"){showingLocalCopies=true}
            }
            Section("目录同步") {
                Toggle("打开文件面板时提示配置目录同步", isOn: $promptSync)
                Text("在主机文件面板中配对本地与远端目录。默认手动双向同步，删除需选择并确认；自动模式只上传本地更改，绝不删除。")
                    .font(.caption).foregroundStyle(.secondary)
                if sync.pairs.isEmpty { Text("尚无目录配对。").foregroundStyle(.secondary) }
                ForEach(sync.pairs) { pair in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(pair.serverName).font(.headline)
                        Text("\(pair.localPath.isEmpty ? "尚未绑定本机目录" : pair.localPath) ↔ \(pair.remotePath)").font(.caption.monospaced())
                        Toggle("自动上传本地更改", isOn: Binding(get: { pair.automaticUpload }, set: { sync.setAutomatic($0, id: pair.id) }))
                            .disabled(pair.localPath.isEmpty)
                    }
                }
            }
        }.formStyle(.grouped)
        .sheet(isPresented: $showingEditor) { RemoteEditorView() }
        .sheet(isPresented:$showingLocalCopies){LocalFileCopiesView()}
    }
    @State private var showingEditor = false
    @State private var showingLocalCopies = false
}
#endif
