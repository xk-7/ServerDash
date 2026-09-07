# 会话导航与连接生命周期验收

日期：2026-09-07。状态：最新 macOS 应用构建通过；移动端最终构建与三端全量回归仍未完成。本记录随用户授权的代码提交一起保存，不代表正式发布验收通过。

## 本轮实现

- 三端 `SessionOpenRequest` 使用复用最近会话、新建标签、指定面板分屏三种策略。选机取消只关闭面板；机器管理默认仍为详情页。
- macOS 路由由 `AppState.route` 驱动；移动端根导航由 `MobileRuntime.destination` 驱动，iPad 切换分区清理上一导航栈。连接完成不改导航。
- 工作区记录内存中的面板使用顺序；关闭后台标签不抢选择，关闭最后标签保持空工作区。分屏/缩放/排序不重新认证。
- 终端请求先分配面板，再执行凭据和信任检查；失败显示在所属面板。关闭/重连使旧代次失效，移动端迟到 SSH/Shell 主动关闭。
- macOS SFTP 控制器持有目录与操作任务，继续使用现有 OpenSSH/SFTP 服务；移动端控制器持有 SSH、文件客户端、目录请求、传输和待导出内容。页面不拥有连接生命周期。
- 关闭含传输的标签集中确认；前台切页保留任务。移动端后台中断，返回不自动恢复终端/传输；下载完成后用户显式保存。
- macOS 进程读取使用非阻塞 DispatchSource；保留定向 TERM/宽限期/KILL。SwiftTerm 的 PTY 重连隔离旧进程与回调，仍需最终验证。

## 已执行（中间版本）

- macOS Debug 构建通过：`/tmp/serverdash-navigation-mac-build.log`。
- 通用 iOS Simulator Debug 构建通过（arm64/x86_64）：`/tmp/serverdash-navigation-mobile-build.log`。
- `ConnectionProcessControllerTests` 7 项、`TerminalRegistryLifecycleTests` 5 项全部通过：`/tmp/serverdash-navigation-process-tests.log`。
- 原有 `testCancellationEscalatesAndLeavesNoChildProcess` 约 0.222 秒通过；1 秒上限及子进程退出检查未放宽。服务器范围终止不影响其他主机的测试通过。
- 最终静态差异检查 `git diff --check` 通过。

以上测试发生在后续 PTY 回收、目录任务收口、导航细节和新增用例之前，不代表最新文件状态已通过全量测试。

## 最新补充验证

- 移除 macOS 终端面板的重复标题栏，关闭与放大面板操作移至上方“+”菜单，快捷键保留。
- 最新 macOS Debug 应用构建通过：`/tmp/serverdash-pane-header-build.log`。这次只构建应用，没有运行全量测试或移动端构建。

## 待执行的最终验证

此前全量测试启动被自动权限审核拒绝，返回额度限制提示，没有通过其他执行通道绕过。后续 macOS 应用构建已获准并完成，以下全量验证尚未重新执行。

- [x] 最新 macOS 应用构建。
- [ ] macOS 全量测试（包括新增 `SessionNavigationRegressionTests`、MRU/跨主机分屏用例）。
- [ ] iPad 模拟器全量测试（包括新增迟到回调、连续重连、SFTP 子系统失败清理、目录代次、前台传输与后台取消测试）。
- [ ] iPhone 模拟器全量测试。
- [ ] PTY 连续重连/TERM 升级/子进程回收的最终定向复核；不能仅依赖中间版本管道测试。
- [ ] 无真实凭据的 macOS、iPhone 紧凑、iPad 横屏/分屏 UI 回归：会话选机、取消、其他入口、焦点、快捷键、最后标签、批量关闭确认。
- [ ] SFTP 文件选择取消、权限释放、隐藏下载完成后的导出、关闭/删除服务器时只取消目标会话。
- [ ] 实体设备：软硬键盘、中文输入、旋转、Stage Manager、VoiceOver、超大 Dynamic Type。本轮未连接实体设备或用户真实服务器。

## 重跑命令

使用现有工程与构建缓存；模拟器测试需要临时签名以访问测试 Keychain。

```sh
xcodebuild -project ServerDash.xcodeproj -scheme ServerDash -destination 'platform=macOS' -derivedDataPath .build/workspace-tests test CODE_SIGNING_ALLOWED=NO
xcodebuild -project ServerDash.xcodeproj -scheme ServerDashMobile -destination 'platform=iOS Simulator,id=49E76F37-F186-4008-8429-140C50577BF7' -derivedDataPath .build/workspace-mobile test CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
xcodebuild -project ServerDash.xcodeproj -scheme ServerDashMobile -destination 'platform=iOS Simulator,id=F3436AE3-7F54-412E-8D34-3225BD66BCC9' -derivedDataPath .build/workspace-mobile test-without-building CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
```

不修改 SwiftData Schema，不增加跨设备同步。提交与推送由用户另行明确授权，不自动创建 Release。
