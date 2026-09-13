# ServerDash 1.0.2 发布通知

ServerDash 1.0.2（Build 7）于 2026-09-13 发布。本版本聚焦 macOS 隐私默认值、SFTP 批量传输、故障反馈和退出可靠性。没有增加协议、修改 SwiftData V5、改变同步包或凭据格式，也没有向 iPhone/iPad 开放桌面功能。

## 隐私与安全

- 服务器公网 IP 与大致位置查询现在默认关闭。启用前会明确说明受管服务器将访问 ipinfo.io；只有用户确认后才会开始查询。
- 从旧版本升级时不会根据原有反向开关推断同意。兼容键同步为关闭状态，使降级后的应用同样不会意外查询。
- 关闭查询会停止后续请求，并清理 ServerDash 当前进程中的位置缓存。
- SSH 设置不再显示一个不能改变实际行为的指纹确认开关。应用专属主机密钥验证始终启用，设置页可直接打开可信主机管理。

## 传输与运行可靠性

- SFTP 多选下载会为每个可见选中项目生成精确本地目标，并在一次 SFTP 连接中提交整批命令。覆盖、跳过和自动重命名策略按每个目标处理。
- SFTP 传输状态不再每 400 毫秒额外建立远程查询连接，也不再反复扫描本地目录；长传输以不确定进度显示，传输进程退出后校验目标，校验通过才报告完成。
- 主机列表会显示短且脱敏的单机监控错误，并为启用监控的主机提供原位重试。
- 正常退出会等待远程编辑草稿、目录同步、监控、SSH 隧道、受管子进程和录制写入收尾；超时的子进程会由 TERM 升级为 KILL，再清理临时密钥材料。

## 下载文件

- `ServerDash-1.0.2-macOS.dmg`：macOS 通用应用，支持 Apple Silicon 与 Intel。
- `ServerDash-1.0.2-iPhone-Simulator.zip`：用于 Xcode iPhone Simulator。
- `ServerDash-1.0.2-iPad-Simulator.zip`：用于 Xcode iPad Simulator。
- `ServerDash-1.0.2-SHA256SUMS.txt`：全部构建产物的 SHA-256 校验值。
- `ServerDash-1.0.2-Release-Notice.md`：本发布通知的离线副本。

## 安装

macOS 用户下载 DMG 后，将 ServerDash 拖入“应用程序”。当前构建使用 ad-hoc 签名且未经 Apple 公证；首次打开时可能需要按住 Control 点击应用并选择“打开”，或在“系统设置 → 隐私与安全性”中允许运行。

iPhone 和 iPad 附件是模拟器构建，不能安装到实体设备。解压后可运行：

```bash
xcrun simctl install booted ServerDashMobile.app
xcrun simctl launch booted com.serverdash.app.ios
```

## 验证范围

- 位置选择加入迁移、SFTP 多选下载计划、主机错误脱敏和受管进程排空的 28 项聚焦测试全部通过。
- macOS 全量 398 项测试全部通过，并重新生成 34 张隔离工作台界面夹具图。
- macOS 通用 Release、iPhone Simulator、iPad Simulator 与无签名 iOS Device 兼容构建全部通过；macOS 和两份模拟器产物均包含 arm64 与 x86_64，设备兼容构建为 arm64。
- 三端包元数据均为 1.0.2（Build 7）；macOS 应用签名、DMG、四项发布文件的 SHA-256 校验均已独立验证。完整结果记录在 [macOS 工作台验收记录](WORKBENCH_UI_QA.md)。
- 隔离界面夹具使用内存数据、模拟服务和文档网段地址，不访问用户数据库、凭据或真实主机。
- 实体 iPhone/iPad、VoiceOver 实际朗读、实体串口、真实 VNC/RDP/SSH 服务和真实 WebDAV 双设备同步本轮未执行，不标记为通过。

完整运行边界见 [macOS 工作台验收记录](WORKBENCH_UI_QA.md)、[连接说明](WORKBENCH_CONNECTIONS.md)、[文件与目录同步说明](WORKBENCH_FILES.md)及[配置同步说明](WORKBENCH_SYNC.md)。
