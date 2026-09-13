# ServerDash 1.0.3 发布通知

ServerDash 1.0.3（Build 8）聚焦 macOS 并发安全与退出可靠性，继续使用 Swift 5.9。本版本不增加协议，不修改 SwiftData V5、同步包、凭据格式或公共连接接口，也不向 iPhone/iPad 开放桌面功能。

## 安全退出

- macOS 退出入口统一由 `MacTerminationDelegate` 和应用级关闭协调器处理，重复退出请求共享同一关闭任务。
- 退出先冻结远程编辑状态并保存最新版本的本地草稿。保存失败时可以重试；选择取消退出后恢复编辑，此时连接与后台服务尚未进入不可逆关闭阶段。
- 草稿保存成功后，目录同步、监控、SSH 隧道、受管子进程、终端/串口会话、文件传输和录制写入共享一个 8 秒绝对期限。到期后取消未完成操作，并对仍存活的受管进程执行 TERM/KILL 收尾。
- 退出超过 300 毫秒才显示原生进度层，快速退出不会闪现。草稿错误对话框出现前会先关闭进度层；进度层本身不能取消全局关闭。
- 录制排空使用事件通知与一次性 continuation，不再阻塞 GCD 工作线程。未能在期限内完成的录制保留 `.partial` 文件，供后续恢复检查。
- 关闭报告只记录固定组件、结果与耗时，不记录主机、路径、命令或凭据；临时密钥材料在正常排空或强制停止后清理。

## 并发与内部边界

- macOS 应用和测试目标启用 `SWIFT_STRICT_CONCURRENCY=complete`，语言模式保持 Swift 5.9。
- 增加锁保护的 `OneShotContinuation`，处理进程退出、回调、取消和超时之间的竞争，并确保 continuation 只恢复一次。
- 受管进程和隧道在应用退出时关闭新任务入口；已有任务共享绝对期限，强制终止与超时保留不同结果。
- `EventLogStore` 的可观察状态限制在 `MainActor`；后台入口先脱敏，再切换到主线程维护最多 300 条事件。
- Keychain 查询、导入凭据、终端主题、通知令牌和 SwiftUI 回调收紧到明确的不可变、锁保护或 actor 隔离边界。
- Objective-C RDP 客户端只通过窄范围 `NativeRDPWorkerBox` 进入既有串行 worker；可信主机文件改为不可变生产位置和可注入存储，测试使用独立临时文件。
- 监控历史及 SwiftData `ModelContext` 继续限制在 `MainActor`，未改变数据库格式、分页或维护语义。

## 下载文件

本次发布提供以下已验证附件：

- `ServerDash-1.0.3-macOS.dmg`：macOS 通用应用，包含 Apple Silicon 与 Intel 架构。
- `ServerDash-1.0.3-iPhone-Simulator.zip`：用于 Xcode iPhone Simulator。
- `ServerDash-1.0.3-iPad-Simulator.zip`：用于 Xcode iPad Simulator。
- `ServerDash-1.0.3-SHA256SUMS.txt`：发布附件的 SHA-256 校验值。
- `ServerDash-1.0.3-Release-Notice.md`：本发布通知的离线副本。

macOS 继续使用 ad-hoc 签名且不进行 Apple 公证。iPhone 与 iPad 附件仍是模拟器构建，不能安装到实体设备；实体设备分发需要 Apple 签名及 TestFlight/App Store 流程。

## 验证状态

- 最终源码通过干净严格并发 `build-for-testing` 门禁，第一方源码与测试编译告警为 **0**。第三方告警实例为 SwiftTerm 87、ZIPFoundation 4、FreeRDP/WinPR 42，NIOSSH 与 Citadel 为 0；本轮没有修改这些依赖。
- 最终 macOS 全量测试执行 **411 项、0 失败**，覆盖退出重试/取消、300 毫秒展示门限、共享 8 秒截止、迟到回调、强制终止、`.partial` 录制、日志脱敏、终端通知、RDP 启停、可信主机隔离与监控排序。
- macOS 通用 Release、iPhone Simulator、iPad Simulator 和无签名 iOS Device Release 兼容构建全部通过。三端元数据均为 1.0.3（Build 8）；macOS 与模拟器应用包含 arm64、x86_64，设备兼容构建为 arm64。
- macOS 构建目录及 DMG 内的 App 均通过 `codesign --verify --deep --strict`；签名为 ad-hoc、无 Team Identifier。DMG 通过完整性验证，两份模拟器 ZIP 可完整解包且包含应用与安装说明。
- iPhone/iPad ZIP 内应用均声明 `iPhoneSimulator`，`UIDeviceFamily` 同时包含 1 与 2，版本、Build 和通用架构均已复核。
- 四项下载文件通过 `ServerDash-1.0.3-SHA256SUMS.txt` 回读校验。
- 隔离 UI 验收生成 59 张 PNG，覆盖 900×620、1440×900 与 1920×1080 的浅色/深色工作台。退出进度层在全部六种尺寸/配色组合中验证了模态键盘焦点契约、无关闭或取消按钮，以及“退出进度”和“退出状态”辅助功能标签。

最终严格并发日志为 `/tmp/serverdash-v103-concurrency-final.log`，macOS 全量测试日志为 `/tmp/serverdash-v103-mac-release-final.log`，发布构建日志为 `/tmp/serverdash-v103-release-build.log`。完整验收边界见 [macOS 工作台验收记录](WORKBENCH_UI_QA.md)。

设备或真实服务验收仍需现场完成，不能由自动化夹具替代：实际 VoiceOver 朗读与顺序、实体串口拔插/占用/重连、真实 SSH/VNC/RDP 服务互通、真实 WebDAV 强 ETag 与双设备同步，以及实体 iPhone/iPad 兼容性。
