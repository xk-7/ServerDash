# ServerDash 共享契约

这里保存 Apple 客户端与 Rust 桌面客户端之间的版本 1 交换样本。样本来自仓库中的真实 Swift Codable 类型、CryptoKit、Compression 和协议解析器，不是网络抓包，不含用户服务器信息或真实凭据。

`generate.py` 从当前 Swift 源文件抽取相关定义，编译到 `.build/contracts/`，再使用 `FixtureMain.swift` 构造固定输入。只替代不会影响编解码的跟踪、显示格式、旧默认值和 Keychain 查询依赖；不构建完整 Apple 应用，也不访问 Keychain 或调用在线 AI 服务。共享契约验证不等于 Apple 应用完整回归。

## 样本内容

- `swift-local.json`：混合 SSH/RDP/VNC/串口、分组、标签、路线、高级设置、转发与墓碑；验证白名单和本地配置身份空间。
- `swift-sync.configsync`：CryptoKit AES-256-GCM 配置包，使用公开固定测试密钥、nonce 和认证头；验证 Rust 解密与错误密钥拒绝机制。
- `swift-frame.json`、`swift-recording.sdrec`、`swift-recording.partial`：真实 Apple LZFSE 独立块、SHA-256、初始画面、增量行、结束索引和截断恢复；包含中文、组合字符、宽字符及 OSC 输出。
- `swift-ai.json`：八类提供商的请求 URL/JSON 和逐字节流解析结果；验证 Chat Completions、Claude、Gemini SSE 与 Ollama NDJSON，并确认隐藏推理不进入回复。
- `swift-sessions.json`：ServerDash 会话文档 v1，包含 Windows 路径提示但不含私钥正文或密码。
- `monitoring.txt`、`swift-monitoring.json`：Linux 行协议及 Swift 解析结果；覆盖内存口径、重复记录、字段内的 `=`/`|`、GPU 缺失值及字节单位。
- `swift-metadata.json`、`SHA256SUMS`：固定身份、日期、公开测试密钥与样本校验和。

## 关键兼容规则

Foundation 默认将 `UUID` 编码为大写字符串。本地配置映射 ID 的 SHA-256 输入包含这个大写字符串，不能改用 Rust 默认的小写显示形式。默认 Codable `Date` 是自 **2001-01-01 UTC** 起的秒数；会话迁移文档另外使用 ISO 8601，不能混用。

Foundation `Data` 编码为 Base64 字符串。Swift 关联值枚举中的 SSH Agent 凭据编码为 `{"sshAgent":{}}`。JSON 布尔值与数值必须按类型区分，不能因为 Foundation 底层使用 `NSNumber` 就把 `true` 当作端口或尺寸。对象键顺序不是线格式语义，Rust ↔ Swift 往返比较解析后的值；录制块长度、哈希与索引偏移则必须对应实际编码字节。

`.sdrec` 回放只消费中立屏幕快照，不把录制中的输出重新发送给终端。样本中的 OSC 序列用于验证这一边界。SHA-256 检测文件损坏，不提供防篡改保证。

## 生成与检查

在 macOS 的仓库根目录运行，需要 Xcode 命令行工具和 Python 3：

```sh
# 重新生成已跟踪样本；修改后应审阅差异。
python3 Shared/Contracts/generate.py

# 生成到临时目录并检查漂移，不覆盖已跟踪样本。
python3 Shared/Contracts/generate.py --check
```

`--check` 验证已保存文件的 SHA-256，并用真实 Swift 解码器校验录制块/索引后比较事件语义。录制 JSON 字段顺序与 LZFSE 压缩大小可能随运行变化，因此不要求重新生成的压缩字节完全相同；其余样本保持内容比对。`--check` 仍会更新 `.build/contracts/` 内的编译缓存。变更 Swift 交换格式时应先确认兼容策略，再更新样本与 Rust 测试，不能仅为消除差异而重生成。

## 双向验证

Rust 集成测试读取已提交的 Swift 样本，无需本机安装 Swift：

```sh
bash Scripts/desktop-cargo.sh test -p serverdash-portability --test shared_contracts --locked
bash Scripts/desktop-cargo.sh test -p serverdash-core --test monitor_contract --locked
```

在 macOS 上额外让 Rust 写回，再用真实 Swift 解码器读取：

```sh
CONTRACT_OUTPUT=$(mktemp -d "${TMPDIR:-/tmp}/serverdash-contracts.XXXXXX")
SERVERDASH_CONTRACT_OUTPUT="$CONTRACT_OUTPUT" \
  bash Scripts/desktop-cargo.sh test -p serverdash-portability \
  --test shared_contracts swift_configuration_and_recording_roundtrip --locked
python3 Shared/Contracts/generate.py --verify-rust "$CONTRACT_OUTPUT"
```

每次使用新的输出目录，因为录制写入器拒绝覆盖已有文件。`--verify-rust` 检查 `rust-local.json`、`rust-sync.configsync` 和 `rust-recording.sdrec` 的配置、解密、日期与画面兼容性。也可以把 Windows 测试生成的这三个文件复制到 macOS 后执行同一验证命令。

当前已通过 Swift 生成、Rust 读取及 Rust 回写后 Swift 读取；Windows 本机运行与真实客户端导入仍是独立验收项目。
