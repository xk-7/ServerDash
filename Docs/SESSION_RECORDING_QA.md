# 会话录制验收记录

日期：2026-09-07。macOS 全量 237/237、iPad 模拟器 93/93、iPhone 模拟器 93/93 通过。录制功能仅面向 macOS，未使用用户真实服务器或真实凭据，未提交或推送。

## 已执行

- 最终 macOS 全量 237/237 通过，包含 27 项录制专项，日志 `/tmp/serverdash-recording-verified-mac-tests.log`。原有 SSH、主机信任、SFTP、监控、导航、工作区与进程取消测试均保留，未放宽取消时间限制。
- 通用 iOS Simulator 应用（arm64 / x86_64）构建通过，日志 `/tmp/serverdash-recording-mobile-build.log`。移动端不开放录制功能。
- iPad Pro 13-inch (M5) 93/93 通过，日志 `/tmp/serverdash-recording-ipad-tests.log`；iPhone 17 Pro 93/93 通过，日志 `/tmp/serverdash-recording-iphone-tests.log`。模拟器使用临时本地签名，不代表实体设备或商店发布验收。
- 专项覆盖 Unicode/真彩色、光标、备用屏、中途开始和尺寸变化、任意跳转一致性、损坏/截断/恶意索引、非单调时间、只读回放无控制序列副作用、队列上限、分块写入、文件权限及 16 面板独立生命周期。
- 1/10/30 FPS GIF 已用 ImageIO 实际解码，帧数及总时长验证通过；取消保留原有目标文件且不残留临时文件。
- 补充覆盖独立帧调色板、sRGB 色值、导出已写入后取消、资源超限、模拟 ENOSPC 写入失败、无效书签不回退、断开仅结束所属面板、快速连续跳转最后请求生效，以及一小时录制的 721 个关键帧索引和随机跳转。
- 已生成并检查浅色/深色 GIF 导出界面，以及中文、Emoji、组合字符、颜色和水印的终端渲染图：临时目录 `serverdash-recording-qa` 中的 `gif-sheet-light.png`、`gif-sheet-dark.png` 和 `terminal.png`。截图使用无真实数据的测试窗口，不表示文件选择器或 VoiceOver 全流程已人工验证。

## 性能检查的范围

合成测试对相同 972,000 字节文本比较纯终端解析与附带 30 次显示快照的耗时，结果写入最终 macOS 测试日志；这不是实时 SSH、文件写入全链路或 16 路并发基准，不能推导“零开销”。

900 帧（30 秒、30 FPS、280×75）样本检查 GIF 导出时的主线程心跳及驻留内存变化。测试发现多帧 ImageIO 目的对象会累计内存，改为单帧 ImageIO 压缩加流式 GIF89a 写出，并统一 sRGB。独立专项复测约 1.19 秒、驻留内存增加约 8.6 MiB、主线程心跳 96 次；以日志中各次测试结果为准，字体/系统缓存与同时运行的任务会影响测量。仍保留 512 MiB 内存增量及文件大小保护。

未使用实际磁盘耗尽或真实服务器制造故障；ENOSPC 通过受控写入注入验证。异常退出恢复通过截断测试文件验证，不强制退出用户正在使用的应用。

## 尚未执行的人工验收

- [ ] 完整真实 SSH 吞吐、主线程和内存压力检查；五分钟、高分辨率 GIF 导出与跨应用分享兼容性。
- [ ] 手工完成文件选择取消、自定义目录授权失效、磁盘耗尽和应用强制退出后的恢复流程。
- [ ] VoiceOver 完整操作、超大字体、长时间 16 路真实 SSH 并发录制、实际睡眠/唤醒。
- [ ] 实体 iPhone/iPad 未连接，本功能不包含移动端录制。

专项单元测试和模拟器构建不能替代以上未执行项，不能据此宣称具备零性能影响或合规审计能力。

## 重跑

```sh
xcodebuild -project ServerDash.xcodeproj -scheme ServerDash -destination 'platform=macOS' -derivedDataPath .build/workspace-tests test CODE_SIGNING_ALLOWED=NO
xcodebuild -project ServerDash.xcodeproj -scheme ServerDashMobile -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/workspace-mobile build CODE_SIGNING_ALLOWED=NO
```
