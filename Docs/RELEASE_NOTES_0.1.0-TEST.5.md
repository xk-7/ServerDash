# ServerDash 0.1.0 test.5 — S11 专业 SSH 路线与隧道

ServerDash 0.1.0 test.5 是面向本人和少量已知测试人员的内部预发布版，Build 4，最低要求 macOS 14。应用使用 ad-hoc 签名且未经公证，不面向公开分发。

## 用户可见变化

- 侧边栏新增“连接与隧道”，集中管理 SSH Config、专业连接路线、结构化代理和端口转发规则。
- SSH Config 导入会展示 Host 最终解析值、来源文件与行号、匹配顺序以及全部不支持项；Include 循环和不可读资源会生成明确报告。
- 支持单跳及多跳 ProxyJump，每一跳具有独立主机、端口、用户名、身份、超时和主机信任。
- 支持 SOCKS5 与 HTTP CONNECT 代理；代理 Secret 仅保存到 macOS Keychain。
- 支持 Local、Remote 和 Dynamic SOCKS 转发。新规则默认监听 `127.0.0.1`；Remote Forward、`0.0.0.0` 和 `::` 在每次启动前要求明确确认。
- 隧道启动与 Ready 状态分离，界面会显示 Starting、Ready、Reconnecting、Stopping、Stopped 或 Failed，不把进程创建误报为可用。

## 架构与数据流

监控、终端、SFTP 和端口转发统一经过 `ConnectionProvider`，共享同一个 `ConnectionRoute` revision。路线按顺序解析每个 `ConnectionHop`，分别验证凭据和主机指纹，再由系统 OpenSSH launch plan 启动对应业务会话。

SwiftData 升级为 VersionedSchema V3，新增连接路线与端口转发规则实体，并提供 V2 → V3 轻量迁移。替换路线或删除服务器时，旧代理 Keychain 引用只在数据持久化成功后清理。

## 安全与可靠性

- 继续强制应用专属 `known_hosts`、`StrictHostKeyChecking=yes` 和 `ForwardAgent=no`。
- 明确选择私钥时使用 `IdentitiesOnly=yes`；私钥读取或导入失败会立即阻止连接，不回退到 Agent、默认身份或密码。
- “私钥优先、密码回退”仅在明确私钥成功读取后开放服务器认证级密码回退。
- 导入的 ProxyCommand 默认不可执行，必须由用户明确核验并确认。
- 代理 Secret 不进入 SwiftData、OpenSSH 参数、环境变量值、诊断或发布记录。
- 隧道停止采用 TERM → KILL，随后复查进程状态与本地端口；App Quit 会 drain 全部 app-scoped 隧道。
- 隧道请求使用规则级幂等、风险确认、Ready/Stopped 复查和不含原始命令或凭据的事件审计。

## 自动验证

- 完整 Debug 测试：117 项通过，0 失败，0 跳过。
- S11 新增 19 项测试，覆盖 SSH Config、Include、ProxyJump、统一 Provider、凭据 fail-closed、V2 → V3、监听确认、Ready 超时、非英文错误、拒绝退出和 App Quit 型清理。
- 隔离多跳：三个仅监听 `127.0.0.1` 的临时 sshd 使用三套独立主机密钥与三套独立客户端身份，真实系统 OpenSSH 三跳命令通过；fixture 结束后进程和临时目录已清理。
- Universal Release：`arm64` 与 `x86_64` 构建通过。
- Xcode 静态分析通过；仅报告仓库内既有 SwiftTerm 的两个未使用变量警告。
- 分发包：App ad-hoc 签名、双架构、DMG 文件系统和 SHA-256 校验通过；DMG SHA-256 为 `592044aaf39c8e672fee5fb0a9a8793a9f07c4a387d78badbe86b547045590aa`，对应 `.sha256` 文件随 Release 附件提供。

## 安装与升级

1. 从本预发布下载 `ServerDash-0.1.0-test.dmg` 和同名 `.sha256` 文件。
2. 可选：在终端进入下载目录后运行 `shasum -a 256 -c ServerDash-0.1.0-test.dmg.sha256`。
3. 打开 DMG，将 ServerDash 拖到 `/Applications`。
4. 因为应用未经公证，首次启动请按住 Control 点击应用并选择“打开”，或在“系统设置 → 隐私与安全性”中允许运行。
5. 升级前建议保留 ServerDash 数据备份；本版本会把 SwiftData V2 数据库轻量迁移到 V3，不会主动删除服务器、监控历史或 Keychain 凭据。

## 已知限制与待验证

- 没有使用生产凭据或对真实 VPS 执行写操作。真实多跳监控/终端/SFTP、真实 Remote Forward 和防火墙/NAT 行为仍待实机验证。
- SOCKS5/HTTP CONNECT 已验证生成配置和代理桥语法；真实匿名/认证握手、407、断网、背压和高吞吐待隔离代理环境验证。
- 系统 OpenSSH CLI Provider 不提供可靠连接数和流量统计，界面明确显示不可用，不伪造为 0。
- SSH Certificate 详情、硬件密钥触摸提示和真实 `ssh-agent` 组合仍待实机完善。
- 第一部分文档要求的完整持久化 Operations Center 及异常退出任务恢复在当前仓库中不存在；本版本只实现 S11 所需的最小隧道任务语义。
- 真实用户数据库副本升级、磁盘满、旧 macOS 14/15、第二台 Mac 首次启动和长时间弱网稳定性仍待验证。

完整实现与验收状态见 [S11_IMPLEMENTATION_STATUS.md](S11_IMPLEMENTATION_STATUS.md)，完整变更历史见 [CHANGELOG.md](../CHANGELOG.md)。
