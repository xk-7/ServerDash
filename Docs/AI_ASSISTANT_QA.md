# AI 助手验收记录

日期：2026-09-08。首版仅 macOS；不使用用户真实服务器、凭据或付费模型。未自动提交或推送。

## 多提供商优化：当前验收状态

- 已实现八种提供商的独立配置、原生／兼容流式协议、模型查询／手动输入、参数设置、Keychain 隔离迁移、对话目的地绑定及面板快捷切换。未增加移动端 AI、登录后台或计费功能。
- 第一轮 macOS 全量测试 **279/279 通过**，含新增 17 项提供商协议／配置／布局测试；日志 `/tmp/serverdash-ai-providers-tests.log`。未修改原有进程取消测试或放宽测试门限。
- 通用 iOS Simulator 构建 **通过**（arm64／x86_64），日志 `/tmp/serverdash-ai-providers-mobile-build.log`。移动端仍不包含 AI 模块。
- 已查看合成浅色设置页和 340pt 运维面板截图；设置页浅深色、原有运维浅深色和通用窗口样本通过生成测试。临时截图位于 `serverdash-ai-provider-qa`、`serverdash-ai-qa`，不包含真实服务器数据。
- 第一轮测试后继续补充：原始迁移地址绑定、请求层过期配置拒绝、授权弹窗地址准确性、变更地址显式新建入口、模型缓存失效、隐藏面板隔离与八协议 URLSession 回归测试。**这些最后补充尚未重新编译／运行，不将首轮通过当作最终版本通过。**
- iPad 测试启动被权限审批服务拒绝，原因为 `Your workspace is out of credits`；没有启动、没有绕过审批。iPhone 测试和最终 macOS 重跑也留待审批恢复后执行。此前版本的移动端测试记录见下方，不代表本轮已重跑。
- 本机未找到 `ollama` 可执行程序；没有探测本地端口、安装模型或调用真实云服务。

### 仍须完成

- [ ] 恢复构建／模拟器权限审批后，重新运行最终 macOS 全量测试（包含新增网络与隐藏面板用例）。
- [ ] 在 iPad Pro 13-inch (M5) 与 iPhone 17 Pro 模拟器运行现有 93 项移动端回归。
- [ ] 模型查询真实服务权限、真实 Keychain 锁定、Ollama 本地模型、付费云服务联调。
- [ ] VoiceOver 全流程、硬件键盘与多窗口设置修改人工操作验收。新增控件已有无障碍标签；不以截图测试替代实际辅助功能验收。

以下为多提供商改动之前的 AI 助手基线记录。

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
