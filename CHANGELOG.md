# Changelog

本项目的重要变更记录在此文件中。

## 0.1.0-test.5 - S11 专业 SSH 路线与隧道（2026-08-25）

### Added

- 增加统一 `ConnectionProvider`、`ConnectionRoute`、逐跳身份/信任/超时和结构化失败阶段，监控、终端、SFTP 与隧道共享同一 route revision。
- 增加 SSH Config 导入报告、ProxyJump、多跳、SOCKS5/HTTP CONNECT、Local/Remote/Dynamic 转发和连接路线管理页。
- 增加 SwiftData V3 与 V2 → V3 迁移，持久化路线和转发规则；代理 Secret 仅保存于 Keychain。
- 增加 19 项 S11 自动化测试及三跳临时 sshd 隔离验证脚本；详细证据见 [S11 实施状态](Docs/S11_IMPLEMENTATION_STATUS.md)。
- 增加 [0.1.0-test.5 发布记录](Docs/RELEASE_NOTES_0.1.0-TEST.5.md)。

### Security and Reliability

- 明确身份不可读时 fail-closed，不回退到 Agent 或其他默认身份；Agent Forwarding 保持关闭。
- 默认仅监听 `127.0.0.1`；Remote Forward 与 `0.0.0.0`/`::` 每次启动前必须确认并写入脱敏风险/复查审计。
- 隧道启动与 Ready 分离，停止使用 TERM → KILL 并复查进程与本地端口，App Quit 会 drain 全部 app-scoped 隧道。

### Verification

- 完整 Debug 测试 117 项通过、0 失败、0 跳过。
- `arm64`/`x86_64` Release 构建通过；三个本机临时 sshd 的独立身份三跳链路通过。
- Xcode 静态分析通过；仅保留仓库内既有 SwiftTerm 的两个未使用变量警告。
- 未连接真实 VPS，真实代理握手、真实 Remote Forward、硬件密钥和多跳业务长稳仍待隔离环境或实机验证。

## 0.1.0-test.4 - S07 监控历史与 Data Gap（2026-08-25）

### Added

- 增加本地监控历史持久化，保存服务器 ID、采集时间、Collector 及版本、数据质量、源数据年龄和九类基础指标。
- 增加原始样本、聚合记录和 Data Gap 三类 SwiftData 实体，并纳入 VersionedSchema V2 与 V1 → V2 迁移计划。
- 增加 24 小时、7 天、30 天和自定义范围历史页；查询会按显示宽度选择原始值、1 分钟或 15 分钟分辨率。
- 增加超时、不可达、认证失败、主机指纹变化、Mac 睡眠、本机断网、Collector 停止、不支持和未知缺口分类。
- 增加 min/max/avg/last/sampleCount 聚合、按像素降采样、自动保留期清理和 512 MiB 默认磁盘配额。
- 增加可注入监控 Clock 及覆盖退避、jitter、睡眠、断网、恢复、聚合、配额和 10～50 台服务器规模语义的测试。
- 增加 [0.1.0-test.4 发布记录](Docs/RELEASE_NOTES_0.1.0-TEST.4.md)。

### Changed

- `MonitoringCoordinator` 在唯一采集路径记录成功快照和失败原因，并把睡眠、断网、恢复及应用停止接入 Data Gap 生命周期。
- 历史折线按缺口拆分并留白，不再用缺口前的旧值连接出伪连续曲线。
- 持久化存储固定到应用 `Application Support/ServerDash/Data` 目录，并继续提供数据库打开失败时的重试、备份和重建入口。
- 主机信任键改为同时包含主机与端口；缺失身份、密钥或凭据时阻止不安全的 Agent/legacy 回退。
- `CFBundleVersion` 从 2 单调递增到 3；DMG 构建脚本同时生成不包含本机路径的 SHA-256 校验文件。

### Security and Privacy

- 监控历史只保存数值指标和不含主机信息的 Collector 标识，不保存密码、私钥、终端正文、命令、未脱敏主机或敏感路径。
- 主机指纹变化继续阻止连接；相同指纹出现在另一主机时仍需独立信任，不复用旧信任决定。
- 本次包仍为 ad-hoc 签名、未经公证的少量已知测试人员预览版，不包含正式 EdDSA 私钥或更新包。

### Verification

- 完整自动化测试 98 项通过、0 失败。
- Debug 测试构建和 Universal Release 构建通过。
- 1、10、50 台服务器的可重复 fixture、10% 超时场景、V1 → V2 迁移，以及 24 小时/30 天像素有界查询通过。
- Release App ad-hoc 签名、`arm64`/`x86_64` 双架构、DMG 文件系统和 SHA-256 校验通过。
- 真实多服务器长稳、睡眠/切网、Instruments、另一台 Mac 首次启动和真实 SSH/SFTP 仍待实机验证。

## 0.1.0-test.3 - S00 决策基线（2026-08-25）

### Added

- 增加四份 Accepted ADR，冻结内部测试分发与系统 OpenSSH、单业务窗口与 app-scoped 长任务、监控运行承诺、远端平台与 Docker Provider 决策。
- 增加 1.0 核心范围、兼容目标、隐私默认值和非目标清单，明确本产品不设计付费分层。
- 增加架构决策索引，将 D-01、D-02、D-03、D-06、D-07 映射到后续实施阶段。
- 增加 [0.1.0-test.3 发布记录](Docs/RELEASE_NOTES_0.1.0-TEST.3.md)。

### Changed

- 中英文 README 改为与内部测试路线一致：本地 ad-hoc 签名、本人和少量已知测试人员手动分发，不依赖 Developer ID、公证或 Mac App Store。
- 首要远端平台收敛为 Ubuntu LTS 和 Debian Stable；AlmaLinux、Rocky Linux 明确为 capability-gated 兼容目标。
- 位置查询产品约束冻结为新用户默认关闭、首次请求前显式选择加入；当前代码接线仍作为发布前待办公开记录。
- `CFBundleVersion` 从 1 单调递增到 2，便于区分本次内部测试包。

### Security and Compatibility

- 保持系统 OpenSSH、应用专属 `known_hosts` 和 `StrictHostKeyChecking=yes`；没有新增宽松回退。
- 没有修改 SwiftData 数据、Keychain 凭据、真实 SSH 配置或 Sparkle 私钥。
- Accepted ADR 只代表决策冻结，不代表 S01～S06 的代码和实机验收已经完成。

### Verification

- Debug 和 Universal Release 构建通过。
- 完整自动化测试 77 项通过、0 失败。
- Release App 的 ad-hoc 签名、双架构和 DMG 文件系统校验通过。
- 真实 SSH/SFTP、其他测试 Mac 首次启动和长时间运行仍为待实机验证。

## 0.1.0-test.2 - P0 性能与流程加固（2026-08-24）

### Added

- 增加固定名称、无运行时元数据的 OS Signpost，覆盖启动、数据库、监控、主机信任、子进程、仪表盘、终端和 SFTP 性能边界。
- 增加子进程输出上限、超时、取消、进程组清理、按服务器隔离及 FIFO 等待队列的回归测试。
- 增加可信主机稳态零扫描、强制复核、FIFO 信任请求和精确恢复原操作的回归测试。
- 增加中央监控调度器的并发、优先级、去重、退避、低电量、睡眠和网络暂停测试。
- 增加每服务器 `ServerRuntimeState`、原子结果发布和增量舰队汇总模型；新增 100 个 RuntimeState 更新隔离测试。
- 增加首次监控快照的明确等待界面，空快照不再显示为真实的 0% 指标。
- 增加 [P0 实施与验证状态](Docs/P0_IMPLEMENTATION_STATUS.md)，逐批记录需求映射、自动化结果和待实机项目。

### Changed

- 子进程 stdout/stderr 改为 32 KiB 分块读取，达到上限立即终止；取消使用进程组 TERM → KILL 升级并保留结构化终止原因。
- 可信服务器的普通连接直接使用应用 `known_hosts`，只在首次使用、显式复核或主机密钥错误后执行 `ssh-keyscan`。
- 监控刷新收敛为唯一 `MonitoringCoordinator`：每服务器去重，按手动、选中、可见、后台和重试排序，动态补位并限制启动速率。
- 低电量模式下自动监控并发降为 2 且间隔加倍；睡眠或断网会取消监控任务，所有暂停原因解除后再错峰恢复。
- 仪表盘卡片、机器列表和服务器详情改为观察各自 RuntimeState；舰队统计由独立 Store 增量维护，不再扫描全部服务器。
- 监控失败只更新错误状态并保留最后成功的快照和历史，避免详情页跳空。

### Security and Privacy

- SSH 和 SFTP 继续强制 `StrictHostKeyChecking=yes`，使用应用专属 `known_hosts`，不引入宽松回退。
- 性能标记、事件日志和本轮涉及的诊断路径不记录 IP、域名、用户名、文件路径、命令、指纹或凭据。
- 主机密钥变化仍会阻止连接，只有对应信任请求被明确接受后才恢复原操作。

### Verification

- 修改前基线：49 项测试通过。
- 性能测量、子进程、信任队列和中央调度器四个批次依次达到 51、60、66、72 项全量测试通过。
- RuntimeState 批次完成后，Universal Release 构建成功，完整测试为 77 项通过、0 失败、0 跳过。
- Ad-hoc 测试 DMG 已通过 `codesign --verify`、`hdiutil verify` 和 `lipo` 双架构检查；此构建未使用 Developer ID 签名且未公证。
- 100 台服务器 SwiftUI Body Updates、应用 RSS、Energy Log、真实 SSH/SFTP 连接数和终端交互延迟仍需 Instruments/实机验证。

## 0.1.0 - 2026-08-24

### Added

- 统一 SSH/SFTP 子进程连接引擎，支持结构化状态、超时、取消、输出限制和并发控制。
- 常驻多标签终端会话，支持跨服务器切换、连接状态展示、断线原因和重新连接。
- 应用专属 `known_hosts`、首次主机指纹确认、密钥变化对比及可信主机管理。
- 离线保存、独立 SSH 测试、服务器能力探测和验证状态。
- 私钥口令、私钥优先密码回退、外部密钥书签及 Keychain 私钥导入。
- 版本化 SwiftData Schema、数据库打开失败恢复、可信主机和终端会话历史实体。
- OSLog 分类、服务器事件日志和可复制的脱敏 SSH Diagnostics。
- Linux 监控能力探测、过期状态、连接延迟、无重叠刷新和可彻底关闭的位置采集。
- 完整 SFTP 浏览器：文件夹传输、进度取消、冲突策略、移动、递归删除和默认路径。
- 来源感知的服务器详情返回流程，保留仪表盘/机器列表滚动位置和搜索上下文。
- CPU、内存、网络、存储、进程、GPU 和 Docker 的统一监控卡片与详情布局。
- 20 套本地终端主题、系统等宽字体发现、行高、字间距、光标、滚动条和 Bell 设置。
- 全局终端默认外观及会话级即时覆盖，支持 `⌘+`、`⌘-` 和 `⌘0`。
- 仓库内固定的 SwiftTerm 1.11.2 本地分支及终端主题许可证说明。
- 无需 Apple Developer 账号的 Universal Ad-hoc 测试 DMG 构建脚本。

### Changed

- README 采用英文默认页与简体中文独立页面，并提供双向语言切换。
- 服务器保存不再依赖监控采集成功；终端和 SFTP 可在监控不兼容时独立使用。
- 监控卡片详情、事件日志和诊断预览统一使用可点击遮罩关闭的 macOS 风格浮层。
- 终端会话栏改为单行 Apple 风格标签，并与当前终端主题背景衔接。
- 刷新入口收敛为单一“刷新全部”按钮。
- 设置页拆分为通用设置和终端主题设置。

### Fixed

- 修复切换终端标签或页面时 SSH 进程被意外终止。
- 修复 OpenSSH 无法读取包含空格的应用 `known_hosts` 路径。
- 修复主机密钥变化时新旧指纹显示未知或错误判定为相同密钥变化。
- 修复关闭位置采集后远端脚本仍可能访问 `ipinfo.io`。
- 修复数据库打开失败直接触发 `fatalError`。
- 修复基础监控采集重叠和页面切换导致的取消问题。
