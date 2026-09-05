# ServerDash 1.0.0 正式发布通知

ServerDash 1.0.0 现已发布。这是首个同时覆盖 macOS、iPhone 与 iPad 的正式 GitHub 版本，提供 Linux 服务器监控、SSH 终端、SFTP 文件管理以及本地身份与主机信任管理。

## 本次发布

- macOS 14+：完整服务器工作台，支持资源监控、多会话终端、SFTP、SSH Config、跳板机、SOCKS5 / HTTP CONNECT 代理和 Local / Remote / Dynamic 端口转发。
- iPhone（iOS 18+）：底部导航、全屏终端、移动端 SFTP、密码与导入私钥认证，以及前台自动监控。
- iPad（iPadOS 18+）：左右横屏双栏导航、自适应多列仪表盘、终端与检查器并排布局，并支持键盘和指针操作。
- 三端共用服务器搜索、分组、标签、监控状态筛选和稳定排序；支持跨名称、地址、用户名、标签与备注的组合搜索。
- 移动端监控采用每服务器去重、最多三路并发和失败退避；后台、删除与重新连接之间使用请求隔离，旧任务不会覆盖新状态。
- 未知或变化的主机密钥必须经过明确确认；密码和导入私钥只保存在本机 Keychain。

## 下载文件

- `ServerDash-1.0.0-macOS.dmg`：macOS 通用应用，支持 Apple Silicon 与 Intel。
- `ServerDash-1.0.0-iPhone-Simulator.zip`：用于 Xcode iPhone Simulator。
- `ServerDash-1.0.0-iPad-Simulator.zip`：用于 Xcode iPad Simulator，限定为左右横屏。
- `ServerDash-1.0.0-SHA256SUMS.txt`：全部构建产物的 SHA-256 校验值。
- `ServerDash-1.0.0-Release-Notice.md`：本正式发布通知的离线副本。

## 安装

macOS 用户下载 DMG 后，将 ServerDash 拖入“应用程序”。当前构建使用 ad-hoc 签名且未经 Apple 公证；首次打开时可能需要按住 Control 点击应用并选择“打开”，或在“系统设置 → 隐私与安全性”中允许运行。

iPhone 和 iPad 附件是模拟器构建，不能安装到实体设备。解压后可运行：

```bash
xcrun simctl install booted ServerDashMobile.app
xcrun simctl launch booted com.serverdash.app.ios
```

公开真机安装仍需要有效的 Apple Distribution 证书、Provisioning Profile，以及 TestFlight、App Store 或其他符合 Apple 签名规则的分发流程。本次发布已执行 iOS 真机架构的无签名编译验证，但不附带不可安装的伪 IPA。

## 验证情况

- macOS Debug 测试覆盖 145 项；其中一个已有的进程取消时序断言在全量并发运行时偶发超过一秒，定向复跑通过。
- iPhone 与 iPad Simulator 测试各 23 项通过，覆盖 Citadel 密码 / Ed25519 / PTY、本地主机信任、监控并发、失败退避、生命周期、筛选和自适应卡片渲染。
- macOS Release 通用构建、iPhone Simulator Release、iPad Simulator Release 及 iOS Device Release 无签名编译均在发布前重新执行。
- NIOSSH 包含 GHSA-998x-vgvp-xwpc 对应的回移修复与畸形签名回归测试。

实体 iPhone / iPad 的 SSH、SFTP、VoiceOver、分屏和长期弱网测试仍需在具备有效签名后完成，详见 [移动端实机验收清单](https://github.com/xk-7/ServerDash/blob/v1.0.0/Docs/MOBILE_DEVICE_TEST_CHECKLIST.md)。

## 已知限制

- 移动端仅在前台保持监控连接；进入后台后终端和传输会中断，需要用户重新连接或重试。
- 移动端暂不支持 SSH Config、Agent、跳板机、代理和端口转发。
- macOS 与移动端数据库相互独立，当前不提供 iCloud / CloudKit 同步。
- 本版本不包含 Widget、Live Activity、Mosh、StoreKit、TestFlight 或 App Store 安装包。
