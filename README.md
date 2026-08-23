# ServerDash

ServerDash 是一款使用 SwiftUI 构建的原生 macOS VPS 监控与 SSH 客户端，最低支持 macOS 14。

## 已实现

- SwiftData 持久化服务器、身份、SSH 密钥引用和代码片段，支持完整 CRUD、搜索与关联保护。
- 密码按身份隔离保存在 macOS Keychain，数据库中不保存明文凭据；私钥只保存本地文件引用和 SHA256 指纹。
- 使用系统 OpenSSH 连接服务器，并遵循 `~/.ssh/known_hosts` 指纹校验。
- 通过 SSH 无 Agent 采集 CPU、负载、内存、Swap、磁盘、网络、系统和进程数据。
- 最多三台服务器并发采集，支持手动刷新和 5/10/30/60 秒自动刷新。
- Swift Charts 资源趋势图和接近设计稿的概览、服务器详情界面。
- 基于 SwiftTerm 与 OpenSSH PTY 的内置多标签终端，支持 ANSI、`vim`、`top` 等交互程序。
- 原生 SFTP 文件管理器，支持目录浏览、上传、下载、新建文件夹、重命名和删除。
- 未打开终端会话时，通过公网 IP 在地图中显示服务器的大致城市位置。
- 代码片段可复制、插入终端，执行前必须确认。
- 原生 macOS sidebar、统一 toolbar、语义色和材质，支持浅色、深色、跟随系统、Reduce Motion、Reduce Transparency 与 Increase Contrast。

## 运行

```bash
xcodegen generate
open ServerDash.xcodeproj
```

在 Xcode 中选择 `ServerDash` scheme 后运行，或执行：

```bash
xcodebuild \
  -project ServerDash.xcodeproj \
  -scheme ServerDash \
  -destination 'platform=macOS' \
  -skipPackagePluginValidation \
  build
```

## 技术说明

- UI：SwiftUI、Swift Charts
- 数据：SwiftData
- 凭据：Security / Keychain Services
- SSH：macOS `/usr/bin/ssh`
- 终端：SwiftTerm 1.11.2
- 地图：MapKit；城市定位会把解析后的公网 IP 发送给 `ipwho.is`，不会发送 SSH 凭据。

应用需要启动本地 OpenSSH/SFTP 子进程，因此当前关闭了 App Sandbox，适合 Developer ID 直接分发，不适合原样提交 Mac App Store。云同步和通知告警不在当前 MVP 中。
