import AppKit
import Charts
import SwiftUI

/// Filters are presentation preferences: snapshots and monitoring ownership remain intact.
struct MonitoringFilters: Equatable {
    var hideSpecialFilesystems = true
    var hideDockerMounts = true
    var hideVirtualInterfaces = true
    var mountPoints = ""
    var interfaceNames = ""

    static func read(_ defaults: UserDefaults = .standard) -> Self {
        Self(hideSpecialFilesystems: defaults.object(forKey: "monitor.hideSpecialFilesystems") as? Bool ?? true,
             hideDockerMounts: defaults.object(forKey: "monitor.hideDockerMounts") as? Bool ?? true,
             hideVirtualInterfaces: defaults.object(forKey: "monitor.hideVirtualInterfaces") as? Bool ?? true,
             mountPoints: defaults.string(forKey: "monitor.mountPoints") ?? "",
             interfaceNames: defaults.string(forKey: "monitor.interfaceNames") ?? "")
    }
    static func tokens(_ text: String) -> Set<String> {
        Set(text.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;，；"))).filter { !$0.isEmpty })
    }
    func includes(_ item: FilesystemMetric) -> Bool {
        let allow = Self.tokens(mountPoints)
        if !allow.isEmpty { return allow.contains(item.mountPoint) }
        if hideDockerMounts && (item.mountPoint.hasPrefix("/var/lib/docker/") || item.mountPoint.hasPrefix("/var/lib/containers/")) { return false }
        let special = Set(["tmpfs", "devtmpfs", "overlay", "squashfs", "proc", "sysfs", "cgroup", "cgroup2", "tracefs", "debugfs", "securityfs", "pstore", "efivarfs", "mqueue", "hugetlbfs", "fusectl", "swap"])
        if hideSpecialFilesystems && (special.contains(item.filesystemType) || item.device.hasPrefix("/dev/loop") || item.mountPoint == "/boot/efi") { return false }
        return true
    }
    func includes(_ item: NetworkInterfaceMetric) -> Bool {
        let allow = Self.tokens(interfaceNames)
        if !allow.isEmpty { return allow.contains(item.name) }
        return !hideVirtualInterfaces || !["lo", "docker", "veth", "br-", "virbr", "tun", "tap", "tailscale", "zt"].contains(where: item.name.hasPrefix)
    }
    func applying(to source: ServerSnapshot) -> ServerSnapshot {
        var result = source
        result.filesystems = source.filesystems.filter(includes)
        result.networkInterfaces = source.networkInterfaces.filter(includes)
        if let active = result.networkInterfaces.first(where: { $0.isActive }) ?? result.networkInterfaces.max(by: { $0.receivedBytes + $0.sentBytes < $1.receivedBytes + $1.sentBytes }) {
            result.activeNetworkInterface = active.name
            result.downloadBytesPerSecond = active.downloadBytesPerSecond
            result.uploadBytesPerSecond = active.uploadBytesPerSecond
        } else if !source.networkInterfaces.isEmpty {
            result.activeNetworkInterface = ""
            result.downloadBytesPerSecond = 0
            result.uploadBytesPerSecond = 0
        }
        return result
    }
}

struct MonitoringFilterSettingsView: View {
    @AppStorage("monitor.hideSpecialFilesystems") private var special = true
    @AppStorage("monitor.hideDockerMounts") private var docker = true
    @AppStorage("monitor.hideVirtualInterfaces") private var virtual = true
    @AppStorage("monitor.mountPoints") private var mounts = ""
    @AppStorage("monitor.interfaceNames") private var interfaces = ""
    var body: some View {
        Section("磁盘监控") {
            Toggle("隐藏 EFI、临时和特殊分区", isOn: $special)
            Toggle("隐藏 Docker 相关挂载点", isOn: $docker)
            TextField("仅显示指定挂载点", text: $mounts, prompt: Text("/ ; /home"))
        }
        Section("网络监控") {
            Toggle("隐藏 Docker 和虚拟网卡", isOn: $virtual)
            TextField("仅显示指定网卡", text: $interfaces, prompt: Text("eth0 ; wlan0"))
            Text("留空使用上方过滤选项；指定名称后只显示所列项目。可用空格、逗号或分号分隔。设置立即生效。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

enum TerminalInspectorSection: String, CaseIterable, Identifiable {
    case status, cpu, gpu, memory, disk, network, files, ai, snippets
    var id: String { rawValue }
    var title: String {
        switch self {
        case .status: "综合"
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "内存"
        case .disk: "磁盘"
        case .network: "网络"
        case .files: "文件"
        case .ai: "AI"
        case .snippets: "片段"
        }
    }
    var icon: String {
        switch self {
        case .status: "square.stack.3d.up"
        case .cpu: "cpu"
        case .gpu: "display"
        case .memory: "memorychip"
        case .disk: "internaldrive"
        case .network: "network"
        case .files: "folder"
        case .ai: "sparkles"
        case .snippets: "curlybraces"
        }
    }
}

struct CompactMonitorContent: View {
    let snapshot: ServerSnapshot
    let history: [MetricPoint]
    let section: TerminalInspectorSection
    @AppStorage("monitor.hideSpecialFilesystems") private var special = true
    @AppStorage("monitor.hideDockerMounts") private var docker = true
    @AppStorage("monitor.hideVirtualInterfaces") private var virtual = true
    @AppStorage("monitor.mountPoints") private var mounts = ""
    @AppStorage("monitor.interfaceNames") private var interfaces = ""
    @AppStorage("hideIPInformation") private var privacy = false
    private var filters: MonitoringFilters {
        .init(hideSpecialFilesystems: special, hideDockerMounts: docker, hideVirtualInterfaces: virtual, mountPoints: mounts, interfaceNames: interfaces)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch section {
            case .cpu: cpu
            case .gpu: gpu
            case .memory: memory
            case .disk: disk
            case .network: network
            default:
                usage("CPU", value: snapshot.cpuUsage, detail: "\(snapshot.coreCount) 核心 · \(snapshot.cpuModel)")
                usage("内存", value: snapshot.memoryUsage, detail: "\(DisplayFormat.bytes(snapshot.memoryUsedBytes)) / \(DisplayFormat.bytes(snapshot.memoryTotalBytes))")
                usage("磁盘", value: snapshot.diskUsage, detail: "\(DisplayFormat.bytes(snapshot.diskUsedBytes)) / \(DisplayFormat.bytes(snapshot.diskTotalBytes))")
                HStack { stat("负载 1M", value: snapshot.load1.formatted(.number.precision(.fractionLength(2))))
                    stat("进程", value: String(snapshot.processCount)); stat("登录用户", value: String(snapshot.loggedInUsers)) }
                Text("运行时间：\(snapshot.uptime)").font(.caption).foregroundStyle(.secondary)
                trafficChart
                processList
            }
        }
    }
    private var cpu: some View {
        VStack(alignment: .leading, spacing: 14) {
            usage("CPU 总负载", value: snapshot.cpuUsage, detail: "\(snapshot.coreCount) 核心 · \(snapshot.cpuModel)")
            HStack { stat("用户态", value: percent(snapshot.cpuUserPercent)); stat("内核态", value: percent(snapshot.cpuSystemPercent)); stat("IO 等待", value: percent(snapshot.cpuIOWaitPercent)) }
            HStack { stat("1M 负载", value: snapshot.load1.formatted(.number.precision(.fractionLength(2))))
                stat("CPU 温度", value: snapshot.cpuTemperatureCelsius.map { "\($0.formatted(.number.precision(.fractionLength(1)))) °C" } ?? "—") }
            Chart(history) { point in
                LineMark(x: .value("时间", point.date), y: .value("CPU %", point.cpu)).foregroundStyle(Color.accentColor)
            }.frame(height: 130).chartYScale(domain: 0...100).accessibilityLabel("CPU 使用率历史")
            if !snapshot.cpuCores.isEmpty {
                Text("核心详情").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 70))], spacing: 8) {
                    ForEach(snapshot.cpuCores) { core in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Text("#\(core.index)"); Spacer(); Text(DisplayFormat.percent(core.usage)) }
                            ProgressView(value: min(100, max(0, core.usage)), total: 100)
                        }.font(.caption2).monospacedDigit().padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            processList
        }
    }
    @ViewBuilder private var gpu: some View {
        if snapshot.gpus.isEmpty {
            unavailable("未检测到 GPU 数据", detail: "需要远端提供可用的 NVIDIA 采集工具及访问权限。")
        } else {
            ForEach(snapshot.gpus) { gpu in
                VStack(alignment: .leading, spacing: 12) {
                    usage(gpu.name, value: gpu.utilization, detail: "显存 \(DisplayFormat.bytes(gpu.memoryUsedBytes)) / \(DisplayFormat.bytes(gpu.memoryTotalBytes))")
                    HStack {
                        stat("温度", value: gpu.temperatureCelsius.map { "\(Int($0)) °C" } ?? "—")
                        stat("功耗", value: gpu.powerWatts.map { "\(Int($0)) W" } ?? "—")
                        stat("风扇", value: percent(gpu.fanPercent))
                    }
                    ForEach(snapshot.gpuProcesses.filter { $0.gpuID == gpu.uuid }) { process in
                        HStack { Text("\(process.pid) · \(process.name)").lineLimit(1); Spacer(); Text(DisplayFormat.bytes(process.memoryBytes)) }.font(.caption)
                    }
                }.applePanel()
            }
        }
    }
    private var memory: some View {
        VStack(alignment: .leading, spacing: 14) {
            usage("内存", value: snapshot.memoryUsage, detail: "\(DisplayFormat.bytes(snapshot.memoryUsedBytes)) / \(DisplayFormat.bytes(snapshot.memoryTotalBytes))")
            HStack { stat("空闲", value: DisplayFormat.bytes(snapshot.memoryFreeBytes)); stat("缓存", value: DisplayFormat.bytes(snapshot.memoryCachedBytes)) }
            usage("Swap", value: snapshot.swapUsage, detail: "\(DisplayFormat.bytes(snapshot.swapUsedBytes)) / \(DisplayFormat.bytes(snapshot.swapTotalBytes))")
            Chart(history) { point in LineMark(x: .value("时间", point.date), y: .value("内存 %", point.memory)).foregroundStyle(.purple) }
                .frame(height: 150).chartYScale(domain: 0...100).accessibilityLabel("内存使用率历史")
            processRows(snapshot.processes.sorted { $0.memory > $1.memory }, memory: true)
        }
    }
    @ViewBuilder private var disk: some View {
        let filesystems = snapshot.filesystems.filter(filters.includes)
        if filesystems.isEmpty { unavailable("没有可显示的分区", detail: "可在设置的监控分类中调整分区过滤。") }
        ForEach(filesystems) { fs in
            usage(fs.mountPoint, value: fs.usage, detail: "\(fs.device) · \(DisplayFormat.bytes(fs.usedBytes)) / \(DisplayFormat.bytes(fs.totalBytes))")
        }
        ForEach(snapshot.diskIO) { io in
            VStack(alignment: .leading, spacing: 8) {
                Text(io.device).font(.headline)
                HStack { stat("读取", value: DisplayFormat.speed(io.readBytesPerSecond)); stat("写入", value: DisplayFormat.speed(io.writeBytesPerSecond)) }
                Text("IOPS 读 \(Int(io.readIOPS)) / 写 \(Int(io.writeIOPS))").font(.caption).foregroundStyle(.secondary)
            }.applePanel()
        }
    }
    @ViewBuilder private var network: some View {
        if let sockets = snapshot.sockets {
            HStack { stat("总连接数", value: String(sockets.total)); stat("TCP", value: String(sockets.tcp)); stat("UDP", value: String(sockets.udp)) }
            Text("监听 \(sockets.listening) · TIME_WAIT \(sockets.timeWait)").font(.caption).foregroundStyle(.secondary)
        } else { Text("连接统计不可用").font(.caption).foregroundStyle(.secondary) }
        if let used = snapshot.fileHandlesUsed {
            stat("文件句柄", value: "\(used) / \(snapshot.fileHandlesLimit.map(String.init) ?? "—")")
        }
        trafficChart
        Text("监听端口").font(.headline)
        if let error = snapshot.listeningPortsError {
            Label("监听端口采集失败：\(error)", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
        } else if !snapshot.listeningPortsAvailable {
            Text("监听端口数据不可用，远端可能未安装 ss。").font(.caption).foregroundStyle(.secondary)
        } else if snapshot.listeningPorts.isEmpty {
            Text("没有监听端口").font(.caption).foregroundStyle(.secondary)
        } else {
            ForEach(snapshot.listeningPorts) { port in
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text(port.transport.uppercased()).font(.caption.bold()); Text(privacy ? "[地址]" : port.address).font(.caption.monospaced()) }
                    Text(port.process.isEmpty ? "进程信息不可用" : port.process).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        Text("网络接口").font(.headline)
        ForEach(snapshot.networkInterfaces.filter(filters.includes)) { item in
            VStack(alignment: .leading, spacing: 8) {
                Text(item.name).font(.headline)
                HStack { stat("下载", value: DisplayFormat.speed(item.downloadBytesPerSecond)); stat("上传", value: DisplayFormat.speed(item.uploadBytesPerSecond)) }
            }.applePanel()
        }
    }
    private var trafficChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("网络流量").font(.headline)
            Chart(history) { point in
                LineMark(x: .value("时间", point.date), y: .value("字节/秒", point.download), series: .value("方向", "下载")).foregroundStyle(by: .value("方向", "下载"))
                LineMark(x: .value("时间", point.date), y: .value("字节/秒", point.upload), series: .value("方向", "上传")).foregroundStyle(by: .value("方向", "上传"))
            }.chartYAxis {
                AxisMarks(position: .trailing) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let bytes = value.as(Double.self) { Text(DisplayFormat.speed(bytes)).font(.caption2) }
                    }
                }
            }.frame(height: 130).accessibilityLabel("上传及下载速率历史")
        }.applePanel()
    }
    private var processList: some View { processRows(snapshot.topProcesses, memory: false) }
    private func processRows(_ processes: [ProcessMetric], memory: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(memory ? "进程内存排行" : "进程 CPU 排行").font(.headline)
            ForEach(processes.prefix(10)) { process in
                HStack {
                    VStack(alignment: .leading, spacing: 3) { Text(process.name).lineLimit(1); Text("\(process.pid) · \(process.user)").font(.caption2).foregroundStyle(.secondary) }
                    Spacer(minLength: 8)
                    Text(DisplayFormat.percent(memory ? process.memory : process.cpu)).monospacedDigit()
                }.font(.caption)
            }
        }.applePanel()
    }
    private func usage(_ title: String, value: Double, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack { Text(title).font(.headline).lineLimit(1); Spacer(); Text(DisplayFormat.percent(value)).font(.headline).monospacedDigit() }
            ProgressView(value: min(100, max(0, value)), total: 100)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }.applePanel().accessibilityElement(children: .combine)
    }
    private func stat(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.caption2).foregroundStyle(.secondary); Text(value).font(.callout.bold()).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75) }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func percent(_ value: Double?) -> String { value.map(DisplayFormat.percent) ?? "—" }
    private func unavailable(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(title).font(.headline); Text(detail).font(.caption).foregroundStyle(.secondary) }.applePanel()
    }
}
