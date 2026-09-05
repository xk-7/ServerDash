import SwiftData
import SwiftTerm
import SwiftUI
import UIKit

struct MobileSessionsView: View {
    @EnvironmentObject private var runtime: MobileRuntime

    private var controllers: [MobileTerminalController] {
        runtime.terminalControllers.values.sorted {
            $0.config.name.localizedStandardCompare($1.config.name) == .orderedAscending
        }
    }

    var body: some View {
        List {
            ForEach(controllers) { controller in
                NavigationLink {
                    MobileTerminalScreen(controller: controller)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "terminal")
                            .frame(width: 44, height: 44)
                            .background(Color.appAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(controller.config.name).font(.headline)
                            Text(controller.status.title)
                                .font(.caption)
                                .foregroundStyle(controller.status == .connected ? Color.appLive : .secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .swipeActions {
                    Button("关闭", role: .destructive) {
                        runtime.closeTerminal(serverID: controller.config.id)
                    }
                }
            }
        }
        .navigationTitle("终端会话")
        .overlay {
            if controllers.isEmpty {
                ContentUnavailableView(
                    "没有终端会话",
                    systemImage: "terminal",
                    description: Text("从机器详情打开一个远程终端。")
                )
            }
        }
    }
}

struct MobileTerminalScreen: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ObservedObject var controller: MobileTerminalController
    @Query(sort: \CommandSnippetRecord.title) private var snippets: [CommandSnippetRecord]
    @State private var showingInspector = false
    @State private var showingSnippets = false

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Color.black.ignoresSafeArea()
                MobileTerminalRepresentable(controller: controller)
                    .ignoresSafeArea(.container, edges: .bottom)
                if controller.status != .connected {
                    statusOverlay
                }
            }
            if horizontalSizeClass == .regular && showingInspector {
                Divider()
                inspector
                    .frame(width: 310)
                    .background(.regularMaterial)
            }
        }
        .navigationTitle(controller.config.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.black, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showingSnippets = true } label: {
                    Image(systemName: "curlybraces")
                }
                Button { showingInspector.toggle() } label: {
                    Image(systemName: "info.circle")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            terminalKeyboardBar
        }
        .task {
            if controller.status == .connecting || controller.status == .disconnected {
                await controller.connect()
            }
        }
        .sheet(isPresented: Binding(
            get: { horizontalSizeClass != .regular && showingInspector },
            set: { showingInspector = $0 }
        )) {
            NavigationStack {
                inspector
                    .navigationTitle("会话信息")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showingInspector = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingSnippets) {
            NavigationStack {
                List(snippets) { snippet in
                    Button {
                        controller.send(Data((snippet.command + "\n").utf8))
                        snippet.lastUsedAt = .now
                        showingSnippets = false
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(snippet.title).font(.headline)
                            Text(snippet.command)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
                .navigationTitle("发送命令片段")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { showingSnippets = false }
                    }
                }
            }
        }
    }

    private var statusOverlay: some View {
        VStack(spacing: 14) {
            if controller.status == .connecting {
                ProgressView().tint(.white)
            } else {
                Image(systemName: controller.status == .interrupted ? "pause.circle" : "exclamationmark.triangle")
                    .font(.largeTitle)
            }
            Text(controller.status.title).font(.headline)
            if let error = controller.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if controller.status == .failed || controller.status == .interrupted || controller.status == .disconnected {
                Button("重新连接") { Task { await controller.connect() } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: 360)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding()
    }

    private var inspector: some View {
        List {
            Section("状态") {
                LabeledContent("会话", value: controller.status.title)
                LabeledContent("服务器", value: controller.config.name)
                LabeledContent("地址", value: "\(controller.config.host):\(controller.config.port)")
                LabeledContent("用户", value: controller.config.username)
            }
            if let error = controller.lastError {
                Section("最近错误") { Text(error).foregroundStyle(Color.appError) }
            }
            if !snippets.isEmpty {
                Section("命令片段") {
                    ForEach(snippets.prefix(8)) { snippet in
                        Button {
                            send(snippet)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(snippet.title)
                                Text(snippet.command)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                    }
                }
            }
            Section {
                Button("重新连接") { Task { await controller.connect() } }
                Button("关闭连接", role: .destructive) { Task { await controller.close() } }
            }
            Section {
                Text("进入后台时终端会安全关闭；返回后需手动重新连接，远程进程不会被恢复。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var terminalKeyboardBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                terminalKey("Esc", data: Data([0x1B]))
                terminalKey("Tab", data: Data([0x09]))
                terminalKey("Ctrl-C", data: Data([0x03]))
                terminalKey("↑", data: Data("\u{1B}[A".utf8))
                terminalKey("↓", data: Data("\u{1B}[B".utf8))
                terminalKey("←", data: Data("\u{1B}[D".utf8))
                terminalKey("→", data: Data("\u{1B}[C".utf8))
                Button("粘贴") {
                    guard let value = UIPasteboard.general.string else { return }
                    controller.send(Data(value.utf8))
                }
                .frame(minWidth: 58, minHeight: 44)
                .disabled(controller.status != .connected)
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 50)
        .background(.bar)
    }

    private func terminalKey(_ title: String, data: Data) -> some View {
        Button(title) { controller.send(data) }
            .font(.callout.monospaced().weight(.medium))
            .frame(minWidth: 48, minHeight: 44)
            .disabled(controller.status != .connected)
    }

    private func send(_ snippet: CommandSnippetRecord) {
        controller.send(Data((snippet.command + "\n").utf8))
        snippet.lastUsedAt = .now
    }
}

private struct MobileTerminalRepresentable: UIViewRepresentable {
    @ObservedObject var controller: MobileTerminalController

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let terminal = SwiftTerm.TerminalView(frame: .zero)
        terminal.terminalDelegate = context.coordinator
        terminal.nativeBackgroundColor = .black
        terminal.nativeForegroundColor = UIColor(white: 0.9, alpha: 1)
        terminal.optionAsMetaKey = true
        terminal.allowMouseReporting = true
        terminal.accessibilityLabel = "远程终端"
        return terminal
    }

    func updateUIView(_ terminal: SwiftTerm.TerminalView, context: Context) {
        context.coordinator.controller = controller
        for data in controller.drainOutput() {
            terminal.feed(byteArray: Array(data)[...])
        }
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        var controller: MobileTerminalController

        init(controller: MobileTerminalController) {
            self.controller = controller
        }

        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            MainActor.assumeIsolated {
                controller.send(Data(data))
            }
        }

        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated {
                controller.resize(
                    RemoteShellDimensions(
                        columns: newCols,
                        rows: newRows,
                        pixelWidth: Int(source.bounds.width),
                        pixelHeight: Int(source.bounds.height)
                    )
                )
            }
        }

        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(
            source: SwiftTerm.TerminalView,
            directory: String?
        ) {}

        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}

        func requestOpenLink(
            source: SwiftTerm.TerminalView,
            link: String,
            params: [String: String]
        ) {
            guard let url = URL(string: link),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http" else { return }
            MainActor.assumeIsolated {
                UIApplication.shared.open(url)
            }
        }

        func bell(source: SwiftTerm.TerminalView) {
            MainActor.assumeIsolated {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
        }

        func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
            guard let text = String(data: content, encoding: .utf8) else { return }
            MainActor.assumeIsolated {
                UIPasteboard.general.string = text
            }
        }

        func iTermContent(
            source: SwiftTerm.TerminalView,
            content: ArraySlice<UInt8>
        ) {}

        func rangeChanged(
            source: SwiftTerm.TerminalView,
            startY: Int,
            endY: Int
        ) {}
    }
}
