# ServerDash

[English](README.md) | **简体中文**

ServerDash 是一款面向 Linux VPS 的原生 macOS、iPhone 与 iPad 监控、SSH 终端和 SFTP 客户端。应用基于 SwiftUI 构建，最低支持 macOS 14 或 iOS/iPadOS 18，不需要在服务器安装 Agent。

## 核心能力

### Linux 资源监控

- CPU 总体/每核心、温度、Load、内存、Swap、进程和登录用户。
- 网络接口实时速率、累计流量及 vnStat 小时/日/周/月/年历史。
- 文件系统容量、块设备吞吐、IOPS 和读写延迟。
- NVIDIA GPU 利用率、显存、温度、风扇、功耗和 GPU 进程。
- Docker 版本、容器状态、镜像与运行详情。
- 可排序、可隐藏的监控卡片；不可用能力自动隐藏。
- 仪表盘和机器页共享搜索、分组与标签筛选，支持名称、分组和添加时间排序；筛选不改变监控范围。工具栏支持仅重试失败监控（`⌘⇧R`）。
- 能力探测、SSH 延迟、最后成功时间、数据年龄和过期提示。
- 唯一中央监控调度器负责每服务器去重、优先级、封顶退避、低电量策略，以及 1–60 秒自动刷新或手动模式。
- 每服务器独立运行时状态、增量舰队汇总、首次快照等待界面；采集失败后保留最后成功数据。

### 本地监控历史与 Data Gap

- 本地保存 CPU、内存、Load、Swap、磁盘和网络速率，并记录服务器 ID、采集时间、Collector/版本、数据质量和源数据年龄。
- 提供 24 小时、7 天、30 天和自定义历史范围；根据显示宽度自动选择原始值、1 分钟或 15 分钟分辨率。
- 采集缺口以明确阴影区显示，折线在缺口处断开，不用旧值连接出伪连续数据。
- 区分超时、服务器不可达、认证失败、主机指纹变化、Mac 睡眠、本机断网、Collector 停止、不支持和未知失败。
- 聚合保存 `min`/`max`/`avg`/`last`/`sampleCount`，并按可用像素数降采样，自动执行保留期和磁盘配额维护。
- 默认保留 24 小时原始样本、30 天 1 分钟聚合和一年 15 分钟聚合；监控历史默认磁盘配额为 512 MiB。

首要支持 Ubuntu LTS 和 Debian Stable。AlmaLinux、Rocky Linux 属于按能力开放的兼容目标；除非后续兼容矩阵另有说明，Alpine/BusyBox 环境不在支持范围内。

### SSH 连接与安全

- Mac 使用系统 `/usr/bin/ssh`；iPhone/iPad 使用仓库内固定的 Citadel 0.12.1 原生 SSH 引擎。
- 两套引擎共同实现 `RemoteConnectionEngine` / `RemoteSession` 协议，统一命令、PTY Shell、SFTP、取消与关闭语义，同时保持已有 macOS 进程行为不变。
- 导入 SSH Config 并展示最终值、来源和不支持项；支持逐跳独立身份、信任和超时的 ProxyJump 多跳路线。
- 支持结构化 SOCKS5/HTTP CONNECT 代理及 Local、Remote、Dynamic 转发；默认回环监听，远端或广域监听必须确认。
- 密码、SSH 私钥、加密私钥口令及“私钥优先，密码回退”。
- 私钥可引用外部文件，也可导入 macOS Keychain。
- 密码、私钥内容和 Passphrase 不写入 SwiftData 数据库或命令行。
- 应用专属 `known_hosts`，支持首次指纹确认、密钥变化对比和可信主机管理。
- 已信任主机走 `known_hosts` 稳态快路径；只有首次使用、显式复核或主机密钥错误恢复时才执行 `ssh-keyscan`。
- 服务器可离线保存；SSH 测试结果使用独立弹窗反馈。
- iPhone/iPad 对未知或变化的主机密钥一律暂停并要求明确确认，不提供“接受所有主机”模式。
- 移动端仅开放密码与导入的 OpenSSH Ed25519/RSA 私钥；凭据使用“仅本设备可访问”的 Keychain 等级。外部密钥路径、SSH Agent、SSH Config、代理、跳板机与端口转发均隐藏。
- 本地 NIOSSH 0.3.6 已回移 Apple `31cdc3c` 修复，并为 [GHSA-998x-vgvp-xwpc](https://github.com/apple/swift-nio-ssh/security/advisories/GHSA-998x-vgvp-xwpc) 增加回归测试；安全门失败时移动端真实 SSH 不具备交付条件。

### 多会话终端

- 基于仓库内固定的 SwiftTerm 1.11.2；macOS 使用 OpenSSH PTY，iPhone 与 iPad 使用 Citadel PTY。
- 终端会话独立于 SwiftUI 页面生命周期，切换标签、服务器或功能页不会断开。
- 支持 ANSI、宽字符、`vim`、`top`、`htop`、`tmux` 等交互程序。
- 20 套本地浅色/深色主题及 macOS 已安装的等宽字体。
- 支持字号、行高、字间距、活动/非活动光标、闪烁、滚动条和 Terminal Bell。
- 全局外观仅影响新会话；运行中的会话可以独立即时调整。
- `⌘T` 新建终端；`⌘+` / `⌘=` 放大、`⌘-` 缩小当前会话字号，`⌘0` 恢复初始字号。
- `⌘F` 查找终端内容，`⌃Tab` / `⌃⇧Tab` 切换标签页，`⌘⇧,` 打开终端外观设置；菜单栏“终端”中可查看这些快捷键。
- `⌘⌥I` 显示状态 / 代码片段检查器：查看资源快照与过期提示，搜索、复制、插入或执行命令。执行和多行插入前确认，并锁定目标会话。
- iPhone 使用 SwiftTerm UIKit 全屏终端，状态与代码片段通过 Sheet 展示；iPad 可并排显示终端和检查器，并支持指针与硬件键盘输入。

### SFTP

- 文件和文件夹上传、下载。
- 新建文件/文件夹、重命名、移动和递归删除。
- 字节进度、速度、剩余时间、取消和失败重试。
- 同名目标支持覆盖、跳过或自动重命名。
- 支持中文、空格和特殊字符路径，以及服务器默认进入目录。
- iPhone 使用紧凑列表，iPad 使用自适应网格；本地文件通过系统文件导入器/导出器访问，不保存外部安全作用域路径。

## 平台功能矩阵

| 能力 | macOS 14+ | iPhone / iPadOS 18+ |
| --- | --- | --- |
| 仪表盘与 Linux 监控 | 支持 | 支持；前台刷新 |
| 多远程终端 | 支持 | 支持；进入后台后中断 |
| SFTP 浏览/上传/下载/重命名/移动/删除 | 支持 | 支持；通过“文件”导入导出 |
| 密码与导入私钥认证 | 支持 | 支持 |
| 外部私钥路径 / SSH Agent / SSH Config | 支持 | 不支持 |
| 跳板机与 SOCKS5 / HTTP CONNECT 代理 | 支持 | 不支持 |
| Local / Remote / Dynamic 转发 | 支持 | 不支持 |
| 本地终端 | 支持 | 不支持 |
| CloudKit 或跨设备数据同步 | 不支持 | 不支持 |

### 性能与进程生命周期

- stdout/stderr 以受限的 32 KiB 分块消费，输出超限、超时、用户取消和自然退出保持不同结果语义。
- 取消针对应用拥有的进程组执行 TERM → KILL 升级，也可以只终止一台服务器的工作而不影响其他服务器。
- 监控连接容量使用 continuation/FIFO 等待队列，不再轮询；任一槽位释放后立即补位。
- 中央调度器优先处理手动、选中和可见服务器，限制新连接启动速率，错峰重试，并在睡眠或断网时暂停监控。
- 固定名称且无运行时元数据的 OS Signpost 覆盖启动、数据库、监控、主机信任、子进程、仪表盘、终端和 SFTP 边界。

### 数据与诊断

- SwiftData 持久化服务器、身份、SSH 密钥引用、连接路线、转发规则、代码片段、可信主机、终端历史、监控样本、聚合和 Data Gap。
- VersionedSchema V1/V2/V3 与 V1 → V2、V2 → V3 迁移阶段；数据库打开失败时提供重试、备份和重建。
- OSLog 按 App、Data、SSH、Monitoring、Terminal、SFTP 分类。
- 每台服务器独立事件日志及可复制、可预览的脱敏 SSH Diagnostics。
- 隐藏 IP 会覆盖界面、Markdown 和诊断；冻结的 1.0 隐私约束要求远端位置查询显式选择加入，其当前界面与默认值接线仍属于内部测试前待完成工作。
- 性能标记及本轮涉及的诊断路径不记录主机、用户名、路径、命令、指纹或凭据。

完整更新记录见 [CHANGELOG.md](CHANGELOG.md)。

## 产品体验参考

以 [SwiftServer 产品页](https://swiftserver.app/)和[官方文档](https://swiftserver.app/docs)作为主要体验参考，优先对齐服务器组织、监控卡片、自适应多设备导航、终端检查器、SFTP 与连接诊断流程。ServerDash 保留自有品牌、实现、文案、资产和安全约束；参考不代表完整功能兼容，也不自动引入付费限制或 iCloud。

## 构建要求

- macOS 14 或更高版本
- `ServerDashMobile` 需要 iOS 或 iPadOS 18 及以上
- Xcode 26
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

项目使用仓库内的 `Vendor/SwiftTerm`、`Vendor/Citadel` 与 `Vendor/swift-nio-ssh` 本地 package；其传递依赖由 `Package.resolved` 固定。

## 开发与验证状态

通用 `ServerDashMobile` Target 已通过 iPhone 与 iPad Simulator 构建。移动端专项套件现有 14 项测试，覆盖连接协议、本地 Citadel 密码/密钥/PTY 集成、主机信任、生命周期中断、平台能力门控和凭据脱敏；Vendored NIOSSH 另有两项畸形 ECDSA 签名安全回归测试。实体设备 SSH/SFTP 与辅助功能检查尚未执行，详见[移动端实机检查清单](Docs/MOBILE_DEVICE_TEST_CHECKLIST.md)。

已有 macOS S11 专业 SSH 路线与隧道保持可用，并继续使用系统 OpenSSH。生产多跳、认证代理、Remote Forward、硬件密钥和长时间稳定性仍需隔离环境或实机验证。

需求到代码的对应关系、各批次结果、验收覆盖和待实机项目见 [Docs/S11_IMPLEMENTATION_STATUS.md](Docs/S11_IMPLEMENTATION_STATUS.md)。

内部测试产品与架构约束见[架构决策索引](Docs/ArchitectureDecisions/README.md)和[1.0 范围与非目标](Docs/PRODUCT_SCOPE_1.0.md)。

最新内部预览版：[ServerDash 0.1.0 test.5](https://github.com/xk-7/ServerDash/releases/tag/v0.1.0-test.5)（Build 4）。安装前请阅读[发布记录](Docs/RELEASE_NOTES_0.1.0-TEST.5.md)；该构建使用 ad-hoc 签名、未经公证，仅供已知测试人员使用。

## 运行

```bash
xcodegen generate
open ServerDash.xcodeproj
```

在 Xcode 中选择 `ServerDash` scheme 后运行，或使用命令行：

```bash
xcodebuild \
  -project ServerDash.xcodeproj \
  -scheme ServerDash \
  -destination 'platform=macOS' \
  -skipPackagePluginValidation \
  build
```

构建通用 iPhone/iPad Simulator App：

```bash
xcodebuild \
  -project ServerDash.xcodeproj \
  -scheme ServerDashMobile \
  -destination 'generic/platform=iOS Simulator' \
  build
```

安装到 iPhone 或 iPad：在 Xcode 中选择 `ServerDashMobile`，设置开发团队，连接运行 iOS/iPadOS 18 及以上的设备后运行。可使用免费 Apple ID 进行本地开发签名，但受 Apple 常规 Provisioning 限制；本项目当前不提供 TestFlight 或 App Store 包。

运行全部测试：

```bash
xcodebuild \
  -project ServerDash.xcodeproj \
  -scheme ServerDash \
  -destination 'platform=macOS' \
  -skipPackagePluginValidation \
  test
```

开发过程中只运行应用测试 Bundle：

```bash
xcodebuild \
  -project ServerDash.xcodeproj \
  -scheme ServerDash \
  -destination 'platform=macOS' \
  -skipPackagePluginValidation \
  -only-testing:ServerDashTests \
  test
```

仓库中的 Xcode 工程由 `project.yml` 生成。修改工程定义后运行 `xcodegen generate`；普通源码修改不需要重新生成。

生成无需 Apple Developer 账号的 Ad-hoc 测试 DMG：

```bash
./Scripts/build-test-dmg.sh
```

DMG 会输出到 `dist/`。在其他 Mac 上首次打开时，请按住 Control 点击 App 并选择“打开”，或在“系统设置 → 隐私与安全性”中允许运行。

## 项目结构

```text
Sources/                    SwiftUI 应用、连接服务和数据模型
Mobile/Sources/             原生 iPhone/iPad App、自适应 UI 与 Citadel 适配器
Mobile/Tests/               移动端连接、安全、信任与生命周期测试
Tests/                      单元与基础集成测试
Docs/                       架构决策、实施状态与发布记录
Resources/TerminalThemes/   本地终端主题与许可证说明
Vendor/SwiftTerm/           固定并扩展的 SwiftTerm 1.11.2
Vendor/Citadel/             本地固定 Citadel 0.12.1
Vendor/swift-nio-ssh/       本地固定 NIOSSH 0.3.6 与安全补丁
project.yml                 XcodeGen 工程定义
```

## 技术栈

- UI：SwiftUI、Swift Charts、MapKit
- 数据：SwiftData
- 凭据：Security / Keychain Services、LocalAuthentication
- SSH/SFTP：macOS 系统 OpenSSH；iOS/iPadOS 使用 Citadel 0.12.1 + NIOSSH 0.3.6
- 终端：本地 SwiftTerm 1.11.2 package
- 日志：OSLog

## 分发与范围

macOS App 需要启动 OpenSSH/SFTP 子进程，因此继续关闭 App Sandbox。iOS/iPadOS App 使用自己的沙箱容器和独立 SwiftData V3 数据库，不迁移或同步 Mac 数据。移动端连接仅面向前台：回到前台后监控会重连；终端与中断传输必须由用户明确重启，不承诺恢复远程进程或断点续传。CloudKit、TestFlight、StoreKit、Widget、Live Activity、付费分层、7×24 告警和 Mosh 仍不在当前范围内。详见 [ADR-0005](Docs/ArchitectureDecisions/ADR-0005-native-ios-and-dual-ssh-engine.md)。
