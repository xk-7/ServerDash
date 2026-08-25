# S11 专业 SSH 路线与隧道：实施与验证状态

日期：2026-08-25

## 结论

S11 的本地实现与自动化验收已经完成：监控、终端、SFTP 和隧道统一经过 `ConnectionProvider` 与同一个 `ConnectionRoute` revision；SSH Config 导入、逐跳身份/信任、结构化代理、Local/Remote/Dynamic 转发、有限重连和退出清理已经接线。

这不代表生产或任意真实网络已经验收。真实硬件密钥、真实 SOCKS5/HTTP CONNECT 服务、真实 Remote Forward、防火墙/NAT、多跳弱网和用户交互式三跳指纹确认仍按下文列为待验证。

## 前置能力审计

- 修改前 Git 工作区干净，仓库没有 `AGENTS.md` 或等价附加指令。
- 修改前完整 Debug 基线为 98 项测试通过、0 失败。
- 既有系统 OpenSSH、应用专属 `known_hosts`、Keychain 凭据、终端/SFTP、进程取消、事件日志与 SwiftData V2 可复用。
- 第二部分的 S08～S10 代码与验收证据不存在；第一部分文档要求的完整 `RemoteActionExecutor` / Operations Center 也不存在。没有为此展开其他大型阶段。
- S11 必需的最小任务语义由 app-scoped `PortForwardSupervisor` 提供：规则级幂等、风险确认、Ready/Stopped 复查、有限退避、取消、退出 drain 和脱敏事件审计。完整的持久化 Operations Center 仍是前置债务，S11 不把它描述为已经补齐。

## 已实现能力

- `ConnectionProvider`、`CredentialProvider`、`HostKeyVerifier` 及 Shell、Remote Command、SFTP、Port Forward 会话协议。
- `ConnectionRoute`、逐跳 `ConnectionHop`、独立 endpoint/credential/timeout，以及节点和阶段化错误。
- SSH Config 的 Host、HostName、User、Port、IdentityFile、ProxyJump、ProxyCommand、ServerAliveInterval、Include 解析；展示最终值、来源、匹配顺序和全部不支持项。
- Include 循环、Host 通配/否定、多重 first-value 语义、权限/资源错误和重同步用户覆盖保护。
- 多跳 OpenSSH 临时配置：每跳独立身份、`IdentitiesOnly=yes`、严格 host key、Agent Forwarding 关闭、应用专属 `known_hosts`。
- SOCKS5/HTTP CONNECT 本机代理桥；代理 Secret 只存 Keychain，握手时读取，不进入 SwiftData、命令行、环境变量值或诊断。
- Local、Remote、Dynamic SOCKS 规则；默认 `127.0.0.1`，Remote Forward 与 `0.0.0.0`/`::` 启动前必须确认。
- 隧道进程启动与 Ready 分离；端口占用检查、有限重连、退避、TERM → KILL、1 秒退出/端口复查和 App Quit `stopAll`。
- SwiftData V3 保存连接路线与隧道规则，提供 V2 → V3 轻量迁移；删除服务器时检查并清理关联规则、路线和代理 Keychain 引用。

## 自动验证证据

- 新增 19 项 S11 测试，覆盖导入来源/不支持项、Include 循环、三跳解析、用户覆盖、ProxyCommand 确认、路线循环、统一 Provider revision、私钥 fail-closed、错误节点/阶段、V2 → V3、系统 `ssh -G`、代理桥 Perl 语法、监听风险、非英文错误、Ready 超时、拒绝退出、端口释放和 App Quit 型 `stopAll`。
- 完整 Debug 测试：117 项通过、0 失败、0 跳过。
- Release：`arm64` 与 `x86_64` 双架构构建通过。
- Xcode 静态分析通过；仅报告仓库内既有 SwiftTerm 的两个未使用变量警告。
- Build 4 ad-hoc App、Universal DMG、`hdiutil verify` 和 SHA-256 校验通过；DMG SHA-256 为 `592044aaf39c8e672fee5fb0a9a8793a9f07c4a387d78badbe86b547045590aa`。
- `Scripts/verify-s11-three-hop.sh` 在三个仅监听 `127.0.0.1` 的临时 sshd 上，以三套独立主机密钥和三套独立客户端身份完成真实系统 OpenSSH 三跳命令；脚本结束后清理自身进程和 `/tmp/serverdash-s11.*`。
- `git diff --check` 通过。

## 退出条件状态

- 三跳连接逐跳确认并保存指纹：领域流程、独立信任和隔离三跳链路已自动验证；真实 UI 三次人工确认待实机验证。
- 失败定位到准确节点和阶段：已自动验证。
- SSH Config 报告全部不支持项：已自动验证。
- 停止隧道无残留且端口按时释放：fake 故障注入与 `stopAll` 已自动验证；真实 OpenSSH/代理子进程待隔离环境长稳验证。
- 默认规则不监听局域网地址：已自动验证；广域和 Remote Forward 均要求执行时确认。
- 监控、终端和 SFTP 对同一路线一致：统一 launch plan/revision 已自动验证；真实多跳三种业务端到端待实机验证。

## 明确未验证或未完成

- 没有连接或写入真实 VPS，没有使用生产凭据，没有执行真实 Remote Forward。
- SOCKS5/HTTP CONNECT 只验证生成配置和代理桥语法；匿名/认证握手、代理断网、407/认证失败和高吞吐背压待隔离代理环境验证。
- 连接数与流量在系统 OpenSSH CLI Provider 下没有可靠来源，界面明确显示“不可用”，没有伪造为 0。
- SSH Certificate 详情、硬件密钥触摸提示和真实 `ssh-agent` 组合待实机验证与后续 UI 完善。
- 完整持久化 Operations Center、异常退出任务恢复和 S08～S10 不属于本批次，仍未完成。

## 非目标

- 不实现原生 SSH Engine、服务器 Agent、Developer ID、公证、Mac App Store、付费能力或云端后端。
- 不开始 S12～S16。
