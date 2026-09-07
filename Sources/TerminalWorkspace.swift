import Foundation
import SwiftUI

/// Opening is a user action, never a side effect of constructing a destination view.
struct SessionOpenRequest: Equatable {
    enum Policy: Equatable {
        case reuseRecent
        case newTab
        case split(pane: UUID, axis: TerminalSplitAxis)
    }
    let serverID: UUID
    var policy: Policy = .reuseRecent
}

enum TerminalSplitAxis: String, Codable, Sendable { case right, below }
enum WorkspaceTabKind: String, Codable, CaseIterable, Sendable {
    case terminal, sftp, monitor
    var title: String { switch self { case .terminal: "SSH"; case .sftp: "SFTP"; case .monitor: "监控" } }
    var icon: String { switch self { case .terminal: "terminal"; case .sftp: "folder"; case .monitor: "chart.xyaxis.line" } }
}

/// A tree, not a grid: each divider owns a stable ratio and each leaf owns one session.
indirect enum TerminalSplitNode: Equatable {
    case pane(UUID)
    case split(id: UUID, axis: TerminalSplitAxis, ratio: Double, first: TerminalSplitNode, second: TerminalSplitNode)

    var panes: [UUID] {
        switch self { case .pane(let id): [id]; case .split(_, _, _, let a, let b): a.panes + b.panes }
    }
    func splitting(_ pane: UUID, with newID: UUID, axis: TerminalSplitAxis) -> Self {
        switch self {
        case .pane(let id):
            return id == pane ? .split(id: UUID(), axis: axis, ratio: 0.5, first: self, second: .pane(newID)) : self
        case .split(let id, let direction, let ratio, let a, let b):
            return .split(id: id, axis: direction, ratio: ratio,
                          first: a.splitting(pane, with: newID, axis: axis), second: b.splitting(pane, with: newID, axis: axis))
        }
    }
    func removing(_ pane: UUID) -> Self? {
        switch self {
        case .pane(let id): return id == pane ? nil : self
        case .split(let id, let axis, let ratio, let a, let b):
            let first = a.removing(pane), second = b.removing(pane)
            guard let first else { return second }
            guard let second else { return first }
            return .split(id: id, axis: axis, ratio: ratio, first: first, second: second)
        }
    }
    func resizing(_ divider: UUID, ratio newRatio: Double) -> Self {
        guard newRatio.isFinite else { return self }
        switch self {
        case .pane: return self
        case .split(let id, let axis, let ratio, let a, let b):
            return .split(id: id, axis: axis, ratio: id == divider ? min(0.9, max(0.1, newRatio)) : ratio,
                          first: a.resizing(divider, ratio: newRatio), second: b.resizing(divider, ratio: newRatio))
        }
    }
}

extension TerminalSplitNode {
    static func balanced(_ nodes: [Self], axis: TerminalSplitAxis) -> Self? {
        guard let first = nodes.first else { return nil }
        guard nodes.count > 1 else { return first }
        let middle = nodes.count / 2
        return .split(id: UUID(), axis: axis, ratio: Double(middle) / Double(nodes.count),
                      first: balanced(Array(nodes[..<middle]), axis: axis)!,
                      second: balanced(Array(nodes[middle...]), axis: axis)!)
    }
}

struct WorkspaceTab: Identifiable {
    let id: UUID
    let kind: WorkspaceTabKind
    let serverID: UUID
    var title: String
    var layout: TerminalSplitNode
    var activePane: UUID
}

@MainActor
final class TerminalWorkspace: ObservableObject {
    static let maximumPanes = 16
    @Published private(set) var tabs: [WorkspaceTab] = []
    @Published private(set) var selectedTabID: UUID?
    @Published private(set) var zoomedPane: UUID?
    private var paneServers: [UUID: UUID] = [:]
    private var recentPanes: [UUID] = []
    func mostRecentTerminal(for serverID: UUID) -> UUID? {
        recentPanes.first { paneServers[$0] == serverID }
    }
    private func recordUse(_ pane: UUID) {
        guard paneServers[pane] != nil else { return }
        recentPanes.removeAll { $0 == pane }
        recentPanes.insert(pane, at: 0)
    }
    private func forget(_ panes: [UUID]) {
        for pane in panes { paneServers[pane] = nil }
        recentPanes.removeAll { panes.contains($0) }
    }
    var selectedTab: WorkspaceTab? { tabs.first { $0.id == selectedTabID } }
    var activePane: UUID? { selectedTab?.activePane }
    var renderedLayout: TerminalSplitNode? {
        guard let tab = selectedTab else { return nil }
        if let zoomedPane, tab.layout.panes.contains(zoomedPane) { return .pane(zoomedPane) }
        return tab.layout
    }
    func toggleZoom(pane: UUID) {
        guard tabs.contains(where: { $0.kind == .terminal && $0.layout.panes.contains(pane) }) else { return }
        let maximize = zoomedPane != pane
        select(pane: pane)
        zoomedPane = maximize ? pane : nil
    }
    func arrangeGrid() {
        guard let index = tabs.firstIndex(where: { $0.id == selectedTabID && $0.kind == .terminal }) else { return }
        let panes = tabs[index].layout.panes
        let columns = min(4, Int(ceil(sqrt(Double(panes.count)))))
        let rows = stride(from: 0, to: panes.count, by: columns).compactMap { start in
            TerminalSplitNode.balanced(panes[start..<min(start + columns, panes.count)].map(TerminalSplitNode.pane), axis: .right)
        }
        if let layout = TerminalSplitNode.balanced(rows, axis: .below) { tabs[index].layout = layout }
        zoomedPane = nil
    }

    func add(sessionID: UUID = UUID(), serverID: UUID, title: String, kind: WorkspaceTabKind = .terminal) {
        guard !tabs.contains(where: { $0.layout.panes.contains(sessionID) }) else { select(pane: sessionID); return }
        var label = title, number = 2
        while tabs.contains(where: { $0.kind == kind && $0.title == label }) { label = "\(title) · \(number)"; number += 1 }
        let tab = WorkspaceTab(id: UUID(), kind: kind, serverID: serverID, title: label,
                               layout: .pane(sessionID), activePane: sessionID)
        tabs.append(tab)
        if kind == .terminal { paneServers[sessionID] = serverID }
        select(tab: tab.id)
    }
    func select(tab id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        if selectedTabID != id { zoomedPane = nil; selectedTabID = id }
        recordUse(tab.activePane)
    }
    func select(pane id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.layout.panes.contains(id) }) else { return }
        recordUse(id)
        if tabs[index].activePane != id { tabs[index].activePane = id }
        if zoomedPane != nil, zoomedPane != id { zoomedPane = id }
        if selectedTabID != tabs[index].id { selectedTabID = tabs[index].id }
    }
    func canSplit(_ pane: UUID) -> Bool {
        tabs.contains { $0.kind == .terminal && $0.layout.panes.contains(pane) && $0.layout.panes.count < Self.maximumPanes }
    }
    /// Moves a newly allocated standalone session into the captured target. No existing pane is replaced.
    @discardableResult
    func split(_ pane: UUID, inserting newID: UUID, axis: TerminalSplitAxis) -> Bool {
        guard pane != newID, canSplit(pane),
              let source = tabs.first(where: { $0.layout.panes.contains(newID) }),
              source.kind == .terminal, source.layout.panes == [newID] else { return false }
        tabs.removeAll { $0.id == source.id }
        guard let index = tabs.firstIndex(where: { $0.layout.panes.contains(pane) }) else { return false }
        tabs[index].layout = tabs[index].layout.splitting(pane, with: newID, axis: axis)
        zoomedPane = nil
        tabs[index].activePane = newID
        selectedTabID = tabs[index].id
        recordUse(newID)
        return true
    }
    func remove(pane id: UUID) {
        if zoomedPane == id { zoomedPane = nil }
        guard let index = tabs.firstIndex(where: { $0.layout.panes.contains(id) }) else { return }
        forget([id])
        if let tree = tabs[index].layout.removing(id) {
            tabs[index].layout = tree
            if tabs[index].activePane == id { tabs[index].activePane = tree.panes[0] }
            if tabs[index].id == selectedTabID { recordUse(tabs[index].activePane) }
        } else { remove(tab: tabs[index].id) }
    }
    func remove(tab id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        forget(tabs[index].layout.panes)
        tabs.remove(at: index)
        if selectedTabID == id {
            zoomedPane = nil
            selectedTabID = nil
            if !tabs.isEmpty { select(tab: tabs[min(index, tabs.count - 1)].id) }
        }
    }
    func resize(divider: UUID, ratio: Double) {
        guard let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        tabs[index].layout = tabs[index].layout.resizing(divider, ratio: ratio)
    }
    func move(_ id: UUID, before target: UUID) {
        guard id != target, let from = tabs.firstIndex(where: { $0.id == id }), tabs.contains(where: { $0.id == target }) else { return }
        let item = tabs.remove(at: from)
        if let to = tabs.firstIndex(where: { $0.id == target }) { tabs.insert(item, at: to) }
    }
    func advance(_ offset: Int) {
        guard !tabs.isEmpty, let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        select(tab: tabs[((index + offset) % tabs.count + tabs.count) % tabs.count].id)
    }
}

struct WorkspaceTabStrip: View {
    @ObservedObject var workspace: TerminalWorkspace
    var onSelect: (WorkspaceTab) -> Void
    var onClose: (WorkspaceTab) -> Void
    var onCloseMultiple: (([WorkspaceTab]) -> Void)? = nil
    var recordingPaneIDs: Set<UUID> = []

    var body: some View {
        HStack(spacing: 0) {
            Button { switchTab(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                .accessibilityLabel("上一个标签").disabled(workspace.tabs.count < 2)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 4) {
                        ForEach(workspace.tabs) { tab in
                            HStack(spacing: 0) {
                                if tab.layout.panes.contains(where: recordingPaneIDs.contains) {
                                    Image(systemName: "record.circle.fill").foregroundStyle(.red)
                                        .accessibilityLabel("正在录制").padding(.trailing, 4)
                                }
                                Button { onSelect(tab) } label: {
                                    Label(tab.title + (tab.layout.panes.count > 1 ? " · \(tab.layout.panes.count)" : ""), systemImage: tab.kind.icon)
                                        .lineLimit(1).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                }
                                .accessibilityAddTraits(workspace.selectedTabID == tab.id ? .isSelected : [])
                                Button { onClose(tab) } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                                    .accessibilityLabel("关闭 \(tab.title)")
                            }
                            .padding(.leading, 12).frame(width: 210)
                            .background(workspace.selectedTabID == tab.id ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                            .draggable(tab.id.uuidString)
                            .dropDestination(for: String.self) { items, _ in
                                guard let text = items.first, let id = UUID(uuidString: text), workspace.tabs.contains(where: { $0.id == id }) else { return false }
                                workspace.move(id, before: tab.id); return true
                            }
                            .contextMenu {
                                Button("关闭当前标签", role: .destructive) { onClose(tab) }
                                Button("关闭其他标签") { closeMany(workspace.tabs.filter { $0.id != tab.id }) }
                                Button("关闭全部标签", role: .destructive) { closeMany(workspace.tabs) }
                                Divider()
                                Button("向左移动") {
                                    if let index = workspace.tabs.firstIndex(where: { $0.id == tab.id }), index > 0 {
                                        workspace.move(tab.id, before: workspace.tabs[index - 1].id)
                                    }
                                }
                            }
                            .id(tab.id)
                        }
                    }
                }
                .onChange(of: workspace.selectedTabID, initial: true) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
            }
            Button { switchTab(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                .accessibilityLabel("下一个标签").disabled(workspace.tabs.count < 2)
        }
        .buttonStyle(.plain).frame(height: 50)
    }
    private func closeMany(_ tabs: [WorkspaceTab]) {
        if let onCloseMultiple { onCloseMultiple(tabs) } else { tabs.forEach(onClose) }
    }
    private func switchTab(_ offset: Int) {
        workspace.advance(offset)
        if let tab = workspace.selectedTab { onSelect(tab) }
    }
}

struct TerminalSplitLayout<Pane: View>: View {
    let node: TerminalSplitNode
    let resize: (UUID, Double) -> Void
    @ViewBuilder let pane: (UUID) -> Pane
    var body: some View {
        switch node {
        case .pane(let id): pane(id).id(id).clipped()
        case .split(let id, let axis, let ratio, let first, let second):
            GeometryReader { geometry in
                let length = max(1, (axis == .right ? geometry.size.width : geometry.size.height) - 8)
                let layout = axis == .right ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
                layout {
                    AnyView(TerminalSplitLayout(node: first, resize: resize, pane: pane))
                        .frame(width: axis == .right ? length * ratio : nil, height: axis == .below ? length * ratio : nil)
                    WorkspaceDivider(axis: axis, ratio: ratio) { resize(id, $0) }
                        .frame(width: axis == .right ? 8 : nil, height: axis == .below ? 8 : nil)
                        .gesture(DragGesture(coordinateSpace: .named(id)).onChanged { value in
                            resize(id, (axis == .right ? value.location.x : value.location.y) / length)
                        })
                    AnyView(TerminalSplitLayout(node: second, resize: resize, pane: pane))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }.coordinateSpace(name: id)
            }
        }
    }
}

private struct WorkspaceDivider: View {
    let axis: TerminalSplitAxis
    let ratio: Double
    let resize: (Double) -> Void
    var body: some View {
        Rectangle().fill(Color.secondary.opacity(0.25))
            .overlay { Capsule().fill(.secondary).frame(width: axis == .right ? 3 : 28, height: axis == .right ? 28 : 3) }
            .contentShape(Rectangle())
            .accessibilityLabel(axis == .right ? "左右面板分隔线" : "上下面板分隔线")
            .accessibilityValue("\(Int(ratio * 100))%")
            .accessibilityAdjustableAction { resize(ratio + ($0 == .increment ? 0.05 : -0.05)) }
    }
}

struct SessionServerPicker: View {
    @Environment(\.dismiss) private var dismiss
    let servers: [ServerRecord]
    let onSelect: (ServerRecord) -> Void
    @State private var search = ""
    var body: some View {
        NavigationStack {
            List(servers.filter { search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search) || $0.host.localizedCaseInsensitiveContains(search) }) { server in
                Button {
                    dismiss()
                    onSelect(server)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(server.displayName).font(.headline)
                        Text("\(server.username)@\(server.host):\(server.port)").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.buttonStyle(.plain)
            }
            .searchable(text: $search, prompt: "搜索机器")
            .navigationTitle("选择终端服务器")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 500, minHeight: 380)
        #endif
    }
}
