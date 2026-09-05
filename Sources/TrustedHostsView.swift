import SwiftData
import SwiftUI

struct TrustedHostsView: View {
    @AppStorage("hideIPInformation") private var hideIPInformation = false
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TrustedHostKey.host) private var hosts: [TrustedHostKey]
    @State private var errorMessage: String?
    @State private var hostPendingDeletion: TrustedHostKey?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppleDesign.Spacing.lg) {
                AppleWorkspaceHeader(
                    title: "可信主机", subtitle: "核验服务器指纹，管理已建立的信任。",
                    symbol: "checkmark.shield"
                ) {
                    Text("\(DisplayFormat.integer(hosts.count)) 条记录")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if hosts.isEmpty {
                    ContentUnavailableView {
                        Label("还没有可信主机", systemImage: "checkmark.shield")
                    } description: {
                        Text("首次连接服务器并确认指纹后，记录会显示在这里。")
                    }
                    .frame(maxWidth: .infinity, minHeight: 320)
                    .applePanel()
                } else {
                    AppleUnifiedPanel {
                        ForEach(Array(hosts.enumerated()), id: \.element.id) { index, host in
                            HStack(spacing: AppleDesign.Spacing.md) {
                                Image(systemName: "checkmark.shield")
                                    .font(.title3).foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(hideIPInformation ? "[IP]" : host.host):\(host.port)")
                                        .font(.headline.monospaced())
                                        .lineLimit(1).truncationMode(.middle)
                                    Text("\(host.algorithm) · \(host.fingerprint)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                        .lineLimit(1).truncationMode(.middle)
                                        .help("\(host.algorithm) · \(host.fingerprint)")
                                }
                                Spacer()
                                Button("重新扫描") {
                                    rescan(host)
                                }
                                Menu {
                                    Button("替换为扫描结果") { replace(host) }
                                    Divider()
                                    Button("删除", role: .destructive) { hostPendingDeletion = host }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                }
                                .fixedSize()
                                .accessibilityLabel("可信主机操作")
                            }
                            .padding(AppleDesign.Spacing.md)
                            if index < hosts.count - 1 { Divider() }
                        }
                    }
                }
            }
            .padding(AppleDesign.Spacing.lg)
            .frame(maxWidth: AppleDesign.Layout.readingWidth)
            .frame(maxWidth: .infinity)
        }
        .confirmationDialog(
            "删除可信主机？",
            isPresented: Binding(
                get: { hostPendingDeletion != nil },
                set: { if !$0 { hostPendingDeletion = nil } }
            )
        ) {
            Button("删除记录", role: .destructive) {
                guard let host = hostPendingDeletion else { return }
                try? TrustedHostStore.remove(host: host.host, port: host.port)
                modelContext.delete(host)
                try? modelContext.save()
                hostPendingDeletion = nil
            }
        }
        .alert("无法更新可信主机", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func rescan(_ host: TrustedHostKey) {
        do {
            let probe = try TrustedHostStore.scan(host: host.host, port: host.port)
            if probe.fingerprint != host.fingerprint {
                errorMessage = "指纹已变化。旧：\(host.fingerprint)\n新：\(probe.fingerprint)\n确认后请删除并重新信任。"
            } else {
                host.updatedAt = .now
                try modelContext.save()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func replace(_ host: TrustedHostKey) {
        do {
            let probe = try TrustedHostStore.scan(host: host.host, port: host.port)
            try TrustedHostStore.trust(probe, replacing: true)
            host.algorithm = probe.algorithm
            host.fingerprint = probe.fingerprint
            host.keyLine = probe.keyLine
            host.updatedAt = .now
            try modelContext.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

enum TrustedHostCatalog {
    static func upsert(probe: SSHHostKeyProbe, in context: ModelContext) {
        let existing = try? context.fetch(
            FetchDescriptor<TrustedHostKey>()
        ).first { $0.host == probe.host && $0.port == probe.port }
        if let existing {
            existing.algorithm = probe.algorithm
            existing.fingerprint = probe.fingerprint
            existing.keyLine = probe.keyLine
            existing.updatedAt = .now
        } else {
            context.insert(
                TrustedHostKey(
                    host: probe.host,
                    port: probe.port,
                    algorithm: probe.algorithm,
                    fingerprint: probe.fingerprint,
                    keyLine: probe.keyLine
                )
            )
        }
        try? context.save()
    }
}

struct EventLogView: View {
    @ObservedObject var store: EventLogStore
    let serverID: UUID?
    let onDismiss: () -> Void

    var body: some View {
        let rows = serverID.map { store.events(for: $0) } ?? store.events
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: AppleDesign.Spacing.xxs) {
                    Text("事件记录")
                        .font(.title2.weight(.bold))
                    Text("\(DisplayFormat.integer(rows.count)) 条事件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭", systemImage: "xmark", action: onDismiss)
                    .labelStyle(.iconOnly)
                    .help("关闭")
            }
            .padding(AppleDesign.Spacing.lg)

            Divider()

            Table(rows) {
                TableColumn("时间") {
                    Text($0.date.formatted(date: .omitted, time: .standard)).monospacedDigit()
                }
                .width(90)
                TableColumn("模块") { Text($0.module.title) }.width(70)
                TableColumn("事件") { Text($0.message).lineLimit(2) }
            }
        }
        .frame(width: 760, height: 500)
    }
}

struct DiagnosticsPreviewView: View {
    let text: String
    let onDismiss: () -> Void
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppleDesign.Spacing.md) {
            HStack {
                Text("连接诊断")
                    .font(.title2.weight(.bold))
                Spacer()
                Button("关闭", systemImage: "xmark", action: onDismiss)
                    .labelStyle(.iconOnly)
                    .help("关闭")
            }
            Text("复制前已脱敏：不包含密码、私钥、口令和终端正文。")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(text)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("复制", action: onCopy)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(AppleDesign.Spacing.lg)
        .frame(width: 560, height: 420)
    }
}
