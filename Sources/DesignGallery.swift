import SwiftUI

struct AppleDesignGallery: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppleDesign.Spacing.lg) {
                AppleSectionHeader(
                    title: "ServerDash 样式画廊",
                    subtitle: "统一表面、长文本、实时状态、错误和刷新状态。"
                )

                AppleUnifiedPanel {
                    galleryRow(status: .online, title: "东京生产节点", value: "23.8%")
                    Divider().padding(.leading, 50)
                    galleryRow(
                        status: .connecting,
                        title: "正在刷新具有很长名称的内部基础设施服务器",
                        value: "—"
                    )
                    Divider().padding(.leading, 50)
                    galleryRow(status: .failed, title: "备份节点 · 认证失败", value: "重试")
                }

                HStack {
                    Button("次要操作") {}
                    Button("主要操作") {}
                        .buttonStyle(.borderedProminent)
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                }
                .applePanel()

                ContentUnavailableView {
                    Label("空状态", systemImage: "server.rack")
                } description: {
                    Text("添加第一个对象后，内容会显示在统一面板中。")
                }
                .frame(maxWidth: .infinity, minHeight: 180)
                .applePanel()
            }
            .padding(AppleDesign.Spacing.lg)
            .frame(maxWidth: 760)
        }
        .background(Color.appGround)
    }

    private func galleryRow(
        status: ServerConnectionStatus,
        title: String,
        value: String
    ) -> some View {
        HStack(spacing: AppleDesign.Spacing.sm) {
            StatusDot(status: status)
            Text(title)
                .lineLimit(1)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(status == .failed ? Color.appError : Color.secondary)
        }
        .padding(AppleDesign.Spacing.md)
    }
}

#Preview("Apple Gallery · Light") {
    AppleDesignGallery()
        .frame(width: 820, height: 680)
        .preferredColorScheme(.light)
}

#Preview("Apple Gallery · Dark") {
    AppleDesignGallery()
        .frame(width: 820, height: 680)
        .preferredColorScheme(.dark)
}
