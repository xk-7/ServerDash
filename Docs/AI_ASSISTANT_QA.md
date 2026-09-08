# AI 助手验收记录

日期：2026-09-08。首版仅 macOS；不使用用户真实服务器、凭据或付费模型。未自动提交或推送。

## 验证范围

- AI 专项覆盖 API 地址限制、请求字段及密钥分离、逐字节 SSE／中文／Emoji、角色与 usage 空增量、截断／畸形／超限响应、取消与迟到回调、HTTP 错误脱敏。
- 终端上下文的当次请求隔离、通用模式禁止自动上下文、默认 20 条历史、大小限制、单行命令及代码围栏、目标面板／连接代次校验。
- 本地持久化与 0600 权限、异常结束恢复标记、旧写入／删除竞态、损坏版本／符号链接／目录错误、50 对话上限及 16 面板独立授权。
- 使用 `URLProtocol` 测试真实 URLSession 接收链路，不向外网发起模型调用；控制型流式服务验证重复发送、取消、失败时保留部分回复及关闭后不能恢复。
- 原生 NSHostingView 合成窗口检查运维面板的浅色、深色、340pt 窄布局和通用窗口；包含中文问题、单行 Shell 代码和确认入口。截图保存在临时目录 `serverdash-ai-qa`，不含真实终端信息。

## 执行结果

- 首轮 AI 专项 24/24 通过，日志 `/tmp/serverdash-ai-targeted-tests.log`；其后增加同网络块内异常仍保留有效增量的回归测试。
- 通用 iOS Simulator 构建通过（arm64／x86_64），日志 `/tmp/serverdash-ai-mobile-build.log`。移动端 Target 不包含 AI 模块。
- macOS 全量 262/262 通过，其中 AI 专项 25 项，日志 `/tmp/serverdash-ai-mac-final-tests.log`；保持现有 SSH、主机信任、SFTP、监控、录制和进程取消测试，未修改或放宽原有验收门限。
- iPad Pro 13-inch (M5) 93/93 通过，日志 `/tmp/serverdash-ai-ipad-tests.log`；iPhone 17 Pro 93/93 通过，日志 `/tmp/serverdash-ai-iphone-tests.log`。模拟器使用临时本地签名，不代表实体设备或商店发布验收。

## 尚未执行

- [ ] 真实 OpenAI／第三方兼容服务／本机模型端点、实际 Keychain 锁定与服务端计费行为。
- [ ] 使用真实 SSH 的右键选区、首次授权、命令确认及远端 Shell／全屏程序状态全流程人工验收。
- [ ] VoiceOver 完整键盘操作、窗口分屏、多显示器、超大字体、实际睡眠／唤醒与强制退出。
- [ ] 长期大对话性能、实际磁盘耗尽与真实网络限流；现有故障测试使用受控注入，不耗尽用户磁盘。
- [ ] 实体 iPhone／iPad 未连接；移动端不开放 AI 功能。

## 重跑

```sh
xcodebuild -project ServerDash.xcodeproj -scheme ServerDash -destination 'platform=macOS' -derivedDataPath .build/workspace-tests test CODE_SIGNING_ALLOWED=NO
xcodebuild -project ServerDash.xcodeproj -scheme ServerDashMobile -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/workspace-mobile build CODE_SIGNING_ALLOWED=NO
```
