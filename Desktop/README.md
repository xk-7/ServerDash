# ServerDash Desktop

面向 Windows 11 x64 的内部预览工程，使用 Tauri 2、React/TypeScript 和 Rust。现有 SwiftUI macOS、iPhone/iPad 应用继续保留。当前实现尚未完整对齐 macOS，首个 NSIS 安装包已通过 Windows CI 构建和 SHA-256 校验，Windows 11 实机验收仍待完成；发布条件见 [Windows 支持记录](../Docs/WINDOWS.md)。

## 工程结构

- `src/`：React 工作台、xterm.js 终端、文件、AI、配置与录制界面。
- `src-tauri/`：桌面宿主、IPC、系统文件选择器、本地授权、配置预览和录制任务。
- `crates/core/`：独立 Rust 业务核心，包含 SQLite、SSH/SFTP、主机信任、会话生命周期与 Linux 监控。
- `crates/platform/`：本地 PTY/Windows ConPTY、串口、外部 VNC 客户端与进程清理。
- `crates/portability/`：配置包和 WebDAV、八类 AI 协议、会话迁移及 `.sdrec` 格式。
- `native/rdp/`：独立 C ABI、HWND 子窗口和 D3D11 显示探针。目前没有 RDP 连接实现，应用的 `rdp` 能力为 `false`。
- [共享契约](../Shared/Contracts/README.md)：由真实 Swift 编解码器生成的配置、录制、AI、会话和监控样本。

应用级会话注册表持有连接，切换工作区不会重建 SSH 会话。终端输出通过有界通道传递，在 xterm.js 消费后确认；连接代次、序号和任务标识用于拒绝关闭连接的迟到输入与输出。

## Windows 开发

需要 Windows 11 x64、Visual Studio C++ Build Tools（桌面 C++ 工作负载和 Windows SDK）、Node.js、Rust MSVC 工具链，以及 WebView2 Runtime。当前 CI 固定 Node.js `24.13.0` 和 Rust `1.98.1`；依赖版本保存在 `package-lock.json` 与 `Cargo.lock`。

在仓库根目录打开 PowerShell：

```powershell
rustup toolchain install 1.98.1 --profile minimal --component rustfmt
$env:RUSTUP_TOOLCHAIN = '1.98.1'
$env:CARGO_TARGET_DIR = Join-Path (Get-Location) '.build/desktop-target'
Set-Location Desktop
npm ci
npm run tauri -- dev
```

`npm run dev` 只启动前端开发服务器，不提供桌面 IPC；验证 SSH、凭据、文件选择器等功能应运行 Tauri 宿主。

在上述 `Desktop` 目录中运行检查和构建：

```powershell
npm test
npm run build
cargo fmt --all -- --check
cargo test --workspace --locked
npm run tauri -- build --target x86_64-pc-windows-msvc --bundles nsis -- --locked
```

最后一条命令用于生成按当前用户安装的 NSIS `.exe`，配置会在需要时下载 WebView2 bootstrapper。预期输出位于仓库 `.build/desktop-target/x86_64-pc-windows-msvc/release/bundle/nsis/`；首个内部预览安装包及对应校验和见 [构建产物](https://github.com/xk-7/ServerDash/actions/runs/34449353992)。当前不包含签名证书、商店发布或自动更新。

## macOS 开发检查

非 Windows 构建用于检查共享代码，不作为新的 macOS 发行版。凭据只在当前进程内存保存，退出后必须重新提供，不会写入 Apple 应用的 Keychain。

从仓库根目录运行：

```sh
bash Scripts/desktop-cargo.sh test --workspace --locked
python3 Shared/Contracts/generate.py --check
```

包装脚本优先使用 `.build/windows-toolchain/` 下的仓库本地 Rust 工具链，否则使用 `PATH` 中的 `cargo`；构建缓存位于 `.build/desktop-target/`。前端检查在 `Desktop/` 内使用 `npm ci`、`npm test`、`npm run build`。Swift ↔ Rust 往返测试命令见 [共享契约说明](../Shared/Contracts/README.md)。

## 数据与迁移

Tauri 宿主使用自身 `app_local_data_dir` 保存独立 SQLite 数据库和凭据引用。Windows 长期凭据在 Rust 中使用用户级 DPAPI 加密后保存；数据库和读取接口不返回长期明文凭据。录制默认写入系统文档目录下的 `ServerDash/Recordings`，文档目录不可用时使用应用数据目录。

配置迁移不复制 Apple 数据库。使用版本化本地配置包或用户主动开启的 WebDAV 同步；密码、私钥正文、代理凭据、信任记录、目录授权与串口设备绑定不会随配置迁移。导入后需在本机配置凭据、确认主机指纹并重新授权文件访问。嵌套连接 JSON 同样经过白名单校验；导入的连接命令保持禁用。

## 当前验证边界

本机已验证 Rust 核心、真实 loopback SSH/SFTP 和共享契约往返；这不能替代 Windows DPAPI、OpenSSH 命名管道、ConPTY、安装升级或图形会话验收。Windows CI 的构建、47 项 Rust 测试、15 项前端测试及独立 RDP 显示探针已通过；这仍不是 Windows 11 交互验收。详细功能边界、已执行测试与待验收项目见 [Windows 支持记录](../Docs/WINDOWS.md)。
