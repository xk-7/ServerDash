# ServerDash

[English](README.md) | **简体中文**

ServerDash 是一款面向 Linux VPS 的原生 macOS 监控、SSH 终端与 SFTP 客户端。应用基于 SwiftUI 构建，最低支持 macOS 14，不需要在服务器安装 Agent。

## 核心能力

### Linux 资源监控

- CPU 总体/每核心、温度、Load、内存、Swap、进程和登录用户。
- 网络接口实时速率、累计流量及 vnStat 小时/日/周/月/年历史。
- 文件系统容量、块设备吞吐、IOPS 和读写延迟。
- NVIDIA GPU 利用率、显存、温度、风扇、功耗和 GPU 进程。
- Docker 版本、容器状态、镜像与运行详情。
- 可排序、可隐藏的监控卡片；不可用能力自动隐藏。
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

- 基于 macOS `/usr/bin/ssh`，统一管理超时、取消、并发和子进程退出。
- 导入 SSH Config 并展示最终值、来源和不支持项；支持逐跳独立身份、信任和超时的 ProxyJump 多跳路线。
- 支持结构化 SOCKS5/HTTP CONNECT 代理及 Local、Remote、Dynamic 转发；默认回环监听，远端或广域监听必须确认。
- 密码、SSH 私钥、加密私钥口令及“私钥优先，密码回退”。
- 私钥可引用外部文件，也可导入 macOS Keychain。
- 密码、私钥内容和 Passphrase 不写入 SwiftData 数据库或命令行。
- 应用专属 `known_hosts`，支持首次指纹确认、密钥变化对比和可信主机管理。
- 已信任主机走 `known_hosts` 稳态快路径；只有首次使用、显式复核或主机密钥错误恢复时才执行 `ssh-keyscan`。
- 服务器可离线保存；SSH 测试结果使用独立弹窗反馈。

### 多会话终端

- 基于仓库内固定的 SwiftTerm 1.11.2 与 OpenSSH PTY。
- 终端会话独立于 SwiftUI 页面生命周期，切换标签、服务器或功能页不会断开。
- 支持 ANSI、宽字符、`vim`、`top`、`htop`、`tmux` 等交互程序。
- 20 套本地浅色/深色主题及 macOS 已安装的等宽字体。
- 支持字号、行高、字间距、活动/非活动光标、闪烁、滚动条和 Terminal Bell。
- 全局外观仅影响新会话；运行中的会话可以独立即时调整。
- `⌘T` 新建终端，`⌘+` / `⌘-` 调整当前会话字号，`⌘0` 恢复。

### SFTP

- 文件和文件夹上传、下载。
- 新建文件/文件夹、重命名、移动和递归删除。
- 字节进度、速度、剩余时间、取消和失败重试。
- 同名目标支持覆盖、跳过或自动重命名。
- 支持中文、空格和特殊字符路径，以及服务器默认进入目录。

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

## 构建要求

- macOS 14 或更高版本
- Xcode 26
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

项目使用仓库内的 `Vendor/SwiftTerm` 本地 package，不需要单独下载 SwiftTerm。

## 开发与验证状态

S11 专业 SSH 路线与隧道已经接入 S07 基线。当前内部构建通过 117 项自动化测试、Debug 构建和 Universal Release 构建；三个临时 sshd 的隔离 fixture 已验证真实系统 OpenSSH 三跳链路。生产多跳、认证代理、Remote Forward、硬件密钥和长时间稳定性仍明确列为待隔离环境或实机验证。

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
Tests/                      单元与基础集成测试
Docs/                       架构决策、实施状态与发布记录
Resources/TerminalThemes/   本地终端主题与许可证说明
Vendor/SwiftTerm/           固定并扩展的 SwiftTerm 1.11.2
project.yml                 XcodeGen 工程定义
```

## 技术栈

- UI：SwiftUI、Swift Charts、MapKit
- 数据：SwiftData
- 凭据：Security / Keychain Services、LocalAuthentication
- SSH/SFTP：macOS 系统 OpenSSH
- 终端：本地 SwiftTerm 1.11.2 package
- 日志：OSLog

## 分发与范围

应用需要启动 OpenSSH/SFTP 子进程，因此当前关闭 App Sandbox。1.0 内部测试路线使用本地 ad-hoc 签名，只在本人和少量已知测试人员之间手动分发；不依赖 Apple Developer Program、Developer ID、公证或 Mac App Store。S11 端口转发属于可选高级本地能力；CloudKit、付费分层、7×24 告警承诺、Mosh 和完整 Docker 运维面板仍不在当前已实现范围内。详见[已接受的分发与 SSH 决策](Docs/ArchitectureDecisions/ADR-0001-internal-distribution-and-ssh-engine.md)。
