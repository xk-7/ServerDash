# RDP 验收记录

日期：2026-09-08。此记录区分构建、受控测试与真实 Windows 兼容性。
构建/测试主机为 macOS 26.3.2、Xcode 26.3（17C529）；macOS 14 为部署下限，
没有在 macOS 14 实体环境运行。移动端使用 iOS 26.3 Simulator。

## 已执行（迭代中）

- FreeRDP/WinPR 3.31.0、OpenSSL 3.5.8，官方归档 SHA-256 校验；arm64/x86_64
  本地静态 XCFramework 构建成功。
- macOS arm64 Debug 构建成功；通用 iOS Simulator 构建成功，移动目标没有原生
  RDP 引擎和界面。
- RDP 默认值、端口、域、屏幕预算、混合标签/LRU/不支持分屏、晚到回调、
  重连读取新配置、目的地址变化清除内存密码等受控回归通过。
- V3 磁盘库迁移 V4，并验证原 SSH id、地址及非默认端口保留；新增 RDP 保存。
- 自签名证书有效期、篡改签名、损坏 PEM 拒绝；指纹按主机+端口隔离。
- UTF-16 中文/组合 Emoji、超过 4 GiB 的文件描述、畸形/重名/路径拒绝。
- 目录只读、新建、拒绝覆盖、路径穿越及符号链接逃逸检查。
- 旧剪贴板回调不能读取新连接，旧 native client 不被闭包循环引用持有。

## 本机复验结果

- macOS arm64 全量 **305/305** 通过（`/tmp/serverdash-rdp-final-all-tests.log`），
  含 AI、SSH、主机信任、监控、SFTP、录制和新增 RDP 回归。RDP 定向
  **22/22** 通过（`/tmp/serverdash-rdp-final-targeted.log`）。
- 通用 macOS Debug 应用 arm64/x86_64 构建通过
  （`/tmp/serverdash-rdp-final-universal-mac.log`）；`lipo` 验证 app/debug dylib 与
  原生静态库包含两种架构，运行链接不含 Homebrew/外部 FreeRDP 动态库。没有运行 Intel 实体机器。
- iPhone 17 Pro 与 iPad Pro 13-inch (M5)，iOS 26.3 Simulator 各 **93/93**
  通过，包含本地 Citadel 服务端、主机信任及 Keychain 测试。使用临时签名，
  未放宽权限策略或跳过 Keychain 失败。
  日志：`/tmp/serverdash-rdp-iphone-tests.log`、`/tmp/serverdash-rdp-ipad-tests.log`。
- 原生目录服务使用 AddressSanitizer + UBSan：新建/拒绝覆盖/穿越检查和
  **1,799** 个固定种子的畸形/截断 IRP 请求通过，无检测到的错误。复现命令
  `bash Scripts/test-rdp-native.sh`；不等于整个上游协议库经过全面模糊测试。
- 原生连接到仅回环的受控 TCP 服务端，暂停协商后取消，worker 在 2 秒门限内
  退出；一轮实测 0.124 秒。没有 Windows 凭据或真实网络桌面参与。
- 已生成并查看添加 RDP 页浅色/深色和未连接桌面截图，修复表单背景缺失。
  文件位于临时目录 `serverdash-rdp-ui-qa`，只含虚构主机。

首次 301 项 macOS 回归发现旧 AI 对话持有面板引用，修改旧提供商配置会误撤销
新提供商授权；已修复并保留原回归测试。一次并行负载下 GIF 帧等待超时，后续
单独复验已通过，未放宽门限。未签名模拟器的六个 Keychain 用例返回 -34018，改用
本机临时签名运行，而不是跳过 Keychain 测试。
末次复验曾因磁盘耗尽在包解析阶段退出；仅清理本轮两个旧 `.xcresult` 结果包
（约 885 MiB），保留最近通过的记录后重跑。没有删除源码、用户数据库或凭据。

## 未执行 / 尚待完成

- 真实 Windows：NLA 登录、域账户、未知/变更证书交互、不同 Windows 版本。
- 双向文件剪贴板、音频、目录映射在 Windows 中的实际操作与异常链路。
- 实体多显示器、热拔插、混合 DPI、中文输入和系统快捷键/VoiceOver。
- 目录传输逐文件进度与独立取消、已有文件覆盖确认工作流。
- 完整 file clipboard clipDataId 锁定；当前在远端剪贴板变化时中止旧传输。
- 整个原生引擎的系统性模糊测试及 1080p/4K 长时 CPU、内存测量。
- Windows 服务端认证失败/注销/证书变化下的真实重连次数和连接资源压力测试。

目前不能标记整份 RDP 计划验收完成，不应以“全面兼容”发布。本轮未提交、未推送、
未发布 Release。无真实凭据测试不得操作实际保存的服务器；测试宿主使用内存库。
