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

当前主要支持 Ubuntu LTS、Debian Stable、AlmaLinux 和 Rocky Linux；Alpine/BusyBox 环境属于有限支持。

### SSH 连接与安全

- 基于 macOS `/usr/bin/ssh`，统一管理超时、取消、并发和子进程退出。
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

- SwiftData 持久化服务器、身份、SSH 密钥引用、代码片段、可信主机和终端历史。
- 版本化 Schema；数据库打开失败时提供重试、备份和重建。
- OSLog 按 App、Data、SSH、Monitoring、Terminal、SFTP 分类。
- 每台服务器独立事件日志及可复制、可预览的脱敏 SSH Diagnostics。
- 隐藏 IP 会覆盖界面、Markdown 和诊断；停止位置采集后服务器不再请求 `ipinfo.io`。
- 性能标记及本轮涉及的诊断路径不记录主机、用户名、路径、命令、指纹或凭据。

完整更新记录见 [CHANGELOG.md](CHANGELOG.md)。

## 构建要求

- macOS 14 或更高版本
- Xcode 26
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

项目使用仓库内的 `Vendor/SwiftTerm` 本地 package，不需要单独下载 SwiftTerm。

## 开发与验证状态

P0 性能加固按可独立验证的小批次实施。性能测量、子进程生命周期、可信主机协调、中央监控调度器和每服务器 RuntimeState 已通过 Universal Release 构建及完整的 77 项测试。依赖 Instruments 或真实服务器的性能阈值继续明确标记为待验证，不会当作已经达标。

需求到代码的对应关系、各批次结果、验收覆盖和待实机项目见 [Docs/P0_IMPLEMENTATION_STATUS.md](Docs/P0_IMPLEMENTATION_STATUS.md)。

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
Docs/                       设计审查及 P0 实施/验证状态
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

应用需要启动 OpenSSH/SFTP 子进程，因此当前关闭 App Sandbox，适合 Developer ID 直接分发，不适合原样提交 Mac App Store。正式签名、公证、iCloud、告警中心、Mosh、端口转发和完整 Docker 运维面板暂不在当前范围内。
