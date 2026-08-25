# ServerDash 0.1.0 test.4 — S07 监控历史与 Data Gap

ServerDash 0.1.0 test.4 是面向本人和少量已知测试人员的内部预发布版，Build 3，最低要求 macOS 14。应用使用 ad-hoc 签名且未经公证，不面向公开分发。

## 用户可见变化

- 服务器详情新增本地监控历史，可查看 24 小时、7 天、30 天和自定义时间范围。
- CPU、内存、Load、Swap、磁盘和网络速率会保存到本机；历史查询会根据时间跨度和图表宽度自动选择合适分辨率。
- 采集超时、服务器不可达、认证失败、主机指纹变化、Mac 睡眠、本机网络中断、Collector 停止等情况会记录为 Data Gap。
- 图表在 Data Gap 处真实留白并拆分折线，不会将缺口前的旧值连接到恢复后的新值。
- 历史页显示当前分辨率、样本数量、Data Gap 数量及估算存储占用，并提供手动清理入口。
- 默认保留 24 小时原始值、30 天 1 分钟聚合和一年 15 分钟聚合，默认配额为 512 MiB；维护过程优先保留长期的粗粒度上下文。

## 架构与数据流

唯一 `MonitoringCoordinator` 继续负责调度。成功采集通过 `ServerRuntimeState` 原子发布后写入 `MonitoringHistoryRepository`；失败按原因开启缺口；睡眠、断网、恢复和应用停止则写入 Collector 侧生命周期缺口。查询从 SwiftData 读取原始样本或聚合记录，先按 Data Gap 分段，再按显示像素降采样后交给 Swift Charts。

监控历史新增至 VersionedSchema V2，并提供 V1 → V2 轻量迁移。存储目录固定在当前用户的 `Application Support/ServerDash/Data` 下。历史记录不包含密码、私钥、终端正文、命令、未脱敏主机信息或敏感路径。

## 安全修正

- 主机信任按“主机 + 端口”隔离；相同指纹出现在其他主机时不会静默继承旧信任。
- 缺失身份、私钥或凭据会直接阻止连接，不再进入可能造成凭据串台的 Agent/legacy 回退。
- 主机指纹变化仍是阻断性错误，需要用户明确处理后才能恢复连接。

## 自动验证

- 完整测试：98 项通过，0 失败。
- Debug 测试构建：通过。
- Universal Release：`arm64` 与 `x86_64` 构建通过。
- 持久化：V1 → V2 迁移 fixture、失败恢复路径和监控实体接线通过。
- 规模语义：1、10、50 台服务器 fixture 与 50 台服务器 10% 超时场景通过。
- 查询与维护：24 小时/30 天像素有界查询、聚合统计、保留期、配额和 Data Gap 分段通过。
- 分发包：App ad-hoc 签名、双架构、DMG 文件系统及 SHA-256 校验通过；DMG SHA-256 为 `883f1afa448db98c610c7f41e1c131b7b0a2a88eab41fefc3b2350f6cc675472`，对应 `.sha256` 文件随 Release 附件提供。

## 安装与升级

1. 从本预发布下载 `ServerDash-0.1.0-test.dmg` 和同名 `.sha256` 文件。
2. 可选：在终端进入下载目录后运行 `shasum -a 256 -c ServerDash-0.1.0-test.dmg.sha256`。
3. 打开 DMG，将 ServerDash 拖到 `/Applications`。
4. 因为应用未经公证，首次启动请按住 Control 点击应用并选择“打开”，或在“系统设置 → 隐私与安全性”中允许运行。
5. 升级测试前建议保留 ServerDash 数据备份；本版本不会主动删除真实监控历史或 Keychain 凭据。

## 已知限制与待实机验证

- ServerDash 是本地优先应用；Mac 睡眠、关机、应用退出或本地网络中断期间不能承诺 7×24 云端监控，相关时间会显示为 Data Gap。
- 真实多服务器长时间运行、睡眠/唤醒与切网、Instruments 内存/能耗、第二台 Mac 首次启动、真实 SSH/SFTP 路径仍待实机验证。
- 第一部分安全底座仍缺少完整的凭据事务协调、传输管理和远端动作执行门禁证据；本版本只包含 S07 继续开发所需的最小阻断修复。
- 现有 SFTP 代码在 Swift 5.9 下可构建，但有一处可变变量并发捕获警告，切换 Swift 6 语言模式前必须修复。
- 本版本不含本地告警中心、MachineAsset 自动盘点或 Sparkle 自动更新。升级使用手动 DMG；没有生成或上传正式 EdDSA 私钥。

完整变更历史见 [CHANGELOG.md](../CHANGELOG.md)。
