# ServerDash 1.0.4 发布通知

ServerDash 1.0.4（Build 9）于 2026-09-21 发布。本版本纳入 macOS 构建自举与 CI 门禁、SSH 审查后续的 fail-closed 收口，以及 Windows RDP 证书/NLA 修复。继续使用 Swift 5.9。本版本不增加协议，不修改 SwiftData V5、同步包、凭据格式或公共连接接口，也不向 iPhone/iPad 开放桌面功能。RDP 仍为开发中能力。

## 构建与工作区

- 共享 `ServerDash` Scheme 会在解析构建图前校验或从锁定源码生成通用 `ServerDashRDP.xcframework`，新工作区不必预先复制二进制产物。
- FreeRDP 使用内容寻址共享缓存；下载、锁、最近使用顺序和活动工作区租约与最终产物目录分离。损坏缓存、架构不全或工具链变化不会被当成可用。
- `macos-dev.sh` 提供诊断、引导、构建、测试和工程漂移检查。直接使用 `xcodebuild -target` 不再受支持。
- 只读 macOS CI 校验固定工具链、XcodeGen 工程漂移、严格并发、第一方零告警、RDP 原生探针，以及主分支 macOS/iOS Release 兼容构建。

## 安全与 SSH

- 直接 SSH 连接固定 `-F none`；临时私钥使用唯一落盘路径，并随启动计划清理。
- 跳板第 2 跳及之后的主机密钥扫描只使用已授权前缀；缺少 `ssh-keyscan` 时 fail-closed。
- ProxyCommand 拒绝控制字符；Keychain 项仅本机解锁后可读，且不同步到 iCloud。
- LocalCommand 握手使用独立标记；导入路线写入 `SSHConfigRouteImport.endpoint`；完整性校验改为流式 SHA-256。
- 隧道停止在阻塞的等待头节点上不会卡住后续清理。

## Windows RDP（开发中）

- 证书检查接受自签发叶证书与自签发链，避免 IP 连接上的 Windows 自签名证书被误判为损坏。
- 工作组或本机账户未填写域、用户名也不是 `DOMAIN\user` / UPN 时，使用单标签证书 CN 作为 NLA 域。
- 上述 NLA 规则以 Swift 实现，iOS 兼容目标不链接 FreeRDP 桥也可编译。
- 本版本不将 RDP 标为已完成的 Windows 互操作验收。

## 其他修复

- 恢复仪表盘刷新控件。
- 录制排空在回调前等待待写入完成。

## 下载文件

本次发布提供以下已验证附件：

- `ServerDash-1.0.4-macOS.dmg`：macOS 通用应用，包含 Apple Silicon 与 Intel 架构。
- `ServerDash-1.0.4-iPhone-Simulator.zip`：用于 Xcode iPhone Simulator。
- `ServerDash-1.0.4-iPad-Simulator.zip`：用于 Xcode iPad Simulator。
- `ServerDash-1.0.4-SHA256SUMS.txt`：发布附件的 SHA-256 校验值。
- `ServerDash-1.0.4-Release-Notice.md`：本发布通知的离线副本。

macOS 继续使用 ad-hoc 签名且不进行 Apple 公证。iPhone 与 iPad 附件仍是模拟器构建，不能安装到实体设备；实体设备分发需要 Apple 签名及 TestFlight/App Store 流程。

## 验证状态

- 发布前提交 `4d4d9fc` 的 GitHub Actions `macOS` 工作流通过严格并发、第一方零告警、macOS 测试、RDP 原生探针，以及通用 macOS Release 与 iOS Simulator/Device 兼容构建。
- 本版本附件由干净 `main` 上的 `Scripts/build-release-artifacts.sh 1.0.4` 生成。三端元数据均为 1.0.4（Build 9）。完整清单见 [macOS 工作台验收记录](WORKBENCH_UI_QA.md) 与 [构建可靠性验收记录](MAC_BUILD_RELIABILITY_QA.md)。

设备或真实服务验收仍需现场完成，不能由自动化夹具替代：实际 VoiceOver 朗读与顺序、实体串口拔插/占用/重连、真实 SSH/VNC/RDP 服务互通、真实 WebDAV 强 ETag 与双设备同步，以及实体 iPhone/iPad 兼容性。
