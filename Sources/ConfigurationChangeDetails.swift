import SwiftUI

/// Portable configuration only; credential references never enter these objects.
struct ConfigurationChangeDetails: View {
    @AppStorage("hideIPInformation") private var privacy = false
    let local: SyncConfigurationObject?
    let incoming: SyncConfigurationObject?
    var incomingTitle = "远端"
    private var changedKeys: [String] {
        Set(local?.fields.keys.map { $0 } ?? []).union(incoming?.fields.keys.map { $0 } ?? [])
            .filter { local?.fields[$0] != incoming?.fields[$0] }.sorted()
    }
    var body: some View {
        DisclosureGroup("查看配置差异") {
            VStack(alignment: .leading, spacing: 12) {
                if local?.deleted == true || incoming?.deleted == true {
                    Text("本机：\(local?.deleted == true ? "删除" : "保留") · \(incomingTitle)：\(incoming?.deleted == true ? "删除" : "保留")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(changedKeys, id: \.self) { key in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title(key)).font(.caption.weight(.semibold))
                        HStack(alignment: .top, spacing: 12) {
                            value(local?.fields[key], label: "本机", key: key)
                            value(incoming?.fields[key], label: incomingTitle, key: key)
                        }
                    }
                }
                if changedKeys.isEmpty { Text("配置内容相同，删除状态不同。").font(.caption).foregroundStyle(.secondary) }
            }.padding(.vertical, 8)
        }
    }
    private func value(_ text: String?, label: String, key: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            ScrollView([.vertical, .horizontal]) {
                Text(privacy && ["host", "username", "route"].contains(key) ? "连接信息已隐藏" : text.flatMap { $0.isEmpty ? "（空）" : $0 } ?? "（不存在）")
                    .font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 140)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func title(_ key: String) -> String {
        ["name":"名称", "title":"标题", "host":"地址", "port":"端口", "username":"用户名", "authentication":"认证方式",
         "group":"分组", "tags":"标签", "notes":"备注", "settings":"连接设置", "route":"连接路线", "server":"所属主机",
         "parent":"上级分组", "command":"命令", "sftpPath":"默认文件目录", "category":"分类", "color":"标签颜色"][key] ?? key
    }
}
