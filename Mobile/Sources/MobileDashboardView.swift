import SwiftData
import SwiftUI

struct MobileDashboardView: View {
    @EnvironmentObject private var runtime: MobileRuntime
    @Query(sort: \ServerRecord.name) private var servers: [ServerRecord]
    @Query private var identities: [IdentityRecord]
    @Query private var keys: [SSHKeyRecord]
    @Query private var routes: [ConnectionRouteRecord]

    private var onlineCount: Int {
        servers.lazy.filter { runtime.statuses[$0.id] == .online }.count
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("服务器概览")
                                .font(.title2.bold())
                            Text("\(onlineCount) 台在线 · 共 \(servers.count) 台")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            refreshAll()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("刷新全部服务器")
                        .disabled(runtime.isBackgrounded)
                    }
                    HStack(spacing: 10) {
                        summaryPill("在线", value: onlineCount, color: .appLive)
                        summaryPill("异常", value: servers.count - onlineCount, color: .appWarning)
                    }
                }
                .padding()
                .background(
                    LinearGradient(
                        colors: [Color.appAccent.opacity(0.18), Color.appSurface],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 24)
                )

                if servers.isEmpty {
                    ContentUnavailableView(
                        "还没有服务器",
                        systemImage: "server.rack",
                        description: Text("前往“机器”添加第一台服务器。")
                    )
                    .padding(.top, 44)
                } else {
                    ForEach(servers) { server in
                        NavigationLink {
                            MobileServerDetailView(server: server)
                        } label: {
                            MobileServerStatusCard(
                                server: server,
                                snapshot: runtime.snapshots[server.id],
                                status: runtime.statuses[server.id] ?? .unknown,
                                error: runtime.errors[server.id]
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding()
            .frame(maxWidth: 920)
            .frame(maxWidth: .infinity)
        }
        .background(Color.appGround)
        .navigationTitle("仪表盘")
        .task(id: servers.map(\.id)) {
            while !Task.isCancelled {
                if !runtime.isBackgrounded { refreshAll() }
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .onChange(of: runtime.isBackgrounded) { _, isBackgrounded in
            if !isBackgrounded { refreshAll() }
        }
    }

    private func refreshAll() {
        for server in servers where server.enableDashboardMonitor {
            runtime.refresh(server: server, identities: identities, keys: keys, routes: routes)
        }
    }

    private func summaryPill(_ title: String, value: Int, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(value) \(title)")
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 12)
        .frame(minHeight: 32)
        .background(.thinMaterial, in: Capsule())
    }
}

struct MobileServerStatusCard: View {
    let server: ServerRecord
    let snapshot: ServerSnapshot?
    let status: ServerConnectionStatus
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
                    .background(Color.appAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.displayName).font(.headline)
                    Text("\(server.username)@\(server.host):\(server.port)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                statusBadge
            }

            if let snapshot {
                HStack(spacing: 8) {
                    metric("CPU", DisplayFormat.percent(snapshot.cpuUsage))
                    metric("内存", DisplayFormat.percent(snapshot.memoryUsage))
                    metric("磁盘", DisplayFormat.percent(snapshot.diskUsage))
                }
                Text(snapshot.distribution)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color.appError)
                    .lineLimit(2)
            } else {
                Text("等待首次监控采集")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.appHairline.opacity(0.35), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 20))
    }

    private var statusBadge: some View {
        Text(status.title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(status == .online ? Color.appLive : .secondary)
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
            .background(.quaternary, in: Capsule())
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit().weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}
