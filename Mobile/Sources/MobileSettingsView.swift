import SwiftUI

struct MobileSettingsView: View {
    @AppStorage("appearance") private var appearanceRawValue = AppAppearance.system.rawValue
    @AppStorage("hideIPInformation") private var hideIPInformation = false
    @AppStorage("disableLocationLookup") private var disableLocationLookup = true
    @AppStorage("confirmHostFingerprint") private var confirmHostFingerprint = true
    @AppStorage("sshConnectTimeout") private var connectTimeout = 8.0
    @AppStorage("mobileRefreshInterval") private var refreshInterval = 15

    var body: some View {
        Form {
            Section("外观") {
                Picker("显示模式", selection: $appearanceRawValue) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Label(appearance.title, systemImage: appearance.symbol)
                            .tag(appearance.rawValue)
                    }
                }
            }

            Section("监控") {
                Picker("自动刷新", selection: $refreshInterval) {
                    Text("手动刷新").tag(0)
                    ForEach([5, 15, 30, 60], id: \.self) { seconds in
                        Text("每轮完成后 \(seconds) 秒").tag(seconds)
                    }
                }
                Text("前台统一刷新，最多同时采集 3 台机器。连接失败后逐步延长重试间隔，手动刷新可立即重试。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("SSH 安全") {
                Toggle("始终确认新主机指纹", isOn: $confirmHostFingerprint)
                    .disabled(true)
                Stepper(
                    "连接超时：\(DisplayFormat.integer(Int(connectTimeout))) 秒",
                    value: $connectTimeout,
                    in: 5...60,
                    step: 5
                )
                LabeledContent("SSH 引擎", value: "Citadel / NIOSSH")
                LabeledContent("密钥保存", value: "仅本设备 Keychain")
                Text("移动端不会自动接受未知或变化的主机密钥。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("隐私") {
                Toggle("隐藏机器概览中的 IP", isOn: $hideIPInformation)
                Toggle("禁用远程位置查询", isOn: $disableLocationLookup)
                Text("服务器配置、历史和凭据不会通过 iCloud 同步。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("地址隐藏适用于仪表盘、机器列表与连接详情；编辑表单和主机信任核对仍显示完整地址。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("移动端能力") {
                capability("远程监控", available: true)
                capability("远程终端", available: true)
                capability("SFTP", available: true)
                capability("跳板机与代理", available: false)
                capability("端口转发", available: false)
                capability("SSH Agent", available: false)
            }

            Section("后台行为") {
                Text("进入后台时监控、终端和传输会安全停止。返回前台后监控会在下一轮自动恢复；终端和传输需要手动重试。")
                    .font(.callout)
            }

            Section("关于") {
                LabeledContent("应用", value: "ServerDash")
                LabeledContent("版本", value: versionDisplay)
                Link("SwiftServer 设计参考", destination: URL(string: "https://swiftserver.app/docs")!)
                Link(
                    "NIOSSH 安全公告",
                    destination: URL(string: "https://github.com/apple/swift-nio-ssh/security/advisories/GHSA-998x-vgvp-xwpc")!
                )
            }
        }
        .navigationTitle("设置")
    }

    private var versionDisplay: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(version) (\($0))" } ?? version
    }

    private func capability(_ title: String, available: Bool) -> some View {
        LabeledContent {
            Label(
                available ? "支持" : "仅 macOS",
                systemImage: available ? "checkmark.circle.fill" : "desktopcomputer"
            )
            .foregroundStyle(available ? Color.appLive : .secondary)
        } label: {
            Text(title)
        }
    }
}
