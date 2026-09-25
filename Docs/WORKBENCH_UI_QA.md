# macOS 工作台验收记录

日期：2026-09-09。范围为本轮 macOS 原生工作台、共享 V5 模型、连接、文件和配置同步。界面保持 ServerDash 品牌、系统控件、语义配色与浅色/深色模式。

## 构建与测试

- macOS 最终全量验收：372 项测试通过，零失败，包含应用编译及链接。使用 `-collect-test-diagnostics never`，避免失败时生成庞大的系统日志归档。
- iPhone/iPad 通用模拟器构建通过，覆盖 arm64 与 x86_64。移动端只升级共享模型及能力白名单，没有新增桌面入口。
- macOS 测试结果：`.build/workbench-ui/Logs/Test/Test-ServerDash-2026.09.09_08-03-51-+0800.xcresult`；日志：`/tmp/serverdash-workbench-tests-3.log`。移动端日志：`/tmp/serverdash-workbench-mobile-build.log`。
- 界面夹具：`/tmp/serverdash-workbench-ui-qa/` 保存 32 张布局图、16 面板图、原生侧栏子图、生命周期检查点及可访问性诊断；系统临时目录下 `serverdash-file-ui-qa/` 保存 10 张文件相关浅深色图。夹具可由对应 XCTest 重新生成。

## 自动化隔离

SwiftData 使用内存容器或测试临时数据库，测试主机均为合成数据，关闭自动监控。文件服务在 XCTest 下使用每进程独立临时目录。工作台夹具关闭共享文件服务注册；SSH 控制器使用 `attachProcess: false`，不会连接已保存的主机。

服务测试仅使用本机临时文件、PTY、`sftp -D /usr/libexec/sftp-server`、固定 Python 程序、回环 SOCKS/HTTP 端点及 URLProtocol 响应。没有上传用户文件、连接真实 WebDAV 目录或修改真实服务器。

## 界面检查

- 主机网格和原生 Table：900×620、1440×900 与 1920×1080，浅色/深色；长中文名称、空数据、连接中、失败、离线和过期快照；窄窗口折叠分组辅助栏。
- 空状态包含六类客户端导入；设置页、监控过滤、综合/CPU/GPU/内存/磁盘/网络检查器均生成隔离截图。
- 文件完整页/紧凑检查器、多标签编辑器、本地副本上传、目录删除冲突分别检查明暗布局。
- 工作台隔离夹具生成 32 张布局图，另有 16 面板深色图与原生侧栏子视图诊断图。1920×1080 四张网格/列表图的分组栏、主机内容和工具栏布局正常；16 面板图确认 4×4 布局及深色终端背景。
- 截图限制：即使 NSHostingController 窗口可见，`cacheDisplay` 仍遗漏原生玻璃主侧栏的合成内容，整窗图该区域呈白色。原生列表记录有 12 行，单独缓存其子视图可见图标和选中行，但材质及部分文字仍不完整；这些诊断证明列表已挂载，不能代替主侧栏在实际应用窗口中的完整视觉验收。

## 生命周期与行为

- 1/4/16 SSH 面板夹具切换机器/终端页面、调整分隔比例、网格/放大布局、显示/切换/隐藏检查器，以及切换应用外观和终端主题。检查控制器、SwiftTerm 视图、连接代次、连接时间及输出保留；明确关闭后清理工作区。
- 可见隔离窗口检查每个终端可成为第一响应者、Tab 可达原生视图，以及导航 outline 和工具菜单的可访问性角色。进程内 NSHostingController 夹具无法可靠读取 SwiftUI 虚拟元素标签，连可见静态文本也返回空字符串，因此仅输出不完整标签诊断，不将命名、朗读顺序或完整键盘导航标记为通过。
- 本轮 1/4/16 面板共 50 个生命周期检查点通过；Tab 分别到达 2/5/17 个原生视图。三份 AX 诊断均记录零个可读标签、`manualVoiceOverRequired: true`，保留实际 VoiceOver 人工验收项。
- 批执行请求保存目标面板与端点，提交时重新核对已连接目标，焦点变化不会改变收件面板。
- 分组目录在数据库打开及主机保存/导入事务中维护；页面显示不保存配置。RDP 仅在真正连接成功时保存本机时间；串口编辑不打断当前会话，明确重连时读取最新配置，已删除记录不能重新连接。
- 文件关闭标签继续后台传输；远程编辑草稿、本地副本和目录任务由应用级控制器持有。RDP 活跃传输关闭仍需确认中断。
- 文件测试覆盖中文、空格、通配符字面路径、精确文件名、编码往返、远端变更冲突、权限保留、符号链接拒绝、复制/归档、删除版本校验、自动上传范围和目录任务迁移。
- 同步测试覆盖 V4→V5 原 UUID/凭据引用、重复导入/同步、并发修改、删除/重建冲突、错误密钥、条件写入失败及凭据排除。

## 真实设备验收

以下项目需相应设备或服务，不能由夹具结果替代：

- 实体串口拔插、占用恢复与不同驱动/高波特率。
- 系统屏幕共享与真实 VNC 服务端的启动/认证，以及现有 RDP 的 Windows 互操作。
- 真实 SSH 多因素认证、多跳代理和长时间 16 主机会话压力。
- 真实 WebDAV 服务强 ETag、双设备同步、断网恢复及恢复密钥交换。
- 实际 VoiceOver 的控件命名、朗读顺序、完整键盘导航和不同 macOS 辅助功能偏好。自动化仅验证可读取的原生角色与关键焦点路径；虚拟标签读取不完整，仍需实际应用中的人工朗读验收。

连接与文件的具体运行边界见 [连接说明](WORKBENCH_CONNECTIONS.md)、[文件说明](WORKBENCH_FILES.md) 和 [同步说明](WORKBENCH_SYNC.md)。

## 2026-09-11 日常体验优化复验

本次复验使用 `codex/mac-native-polish` 分支。macOS Debug 应用完成编译并运行全量测试，394 项全部通过、零失败；日志为 `/tmp/serverdash-mac-polish-final-tests.log`。`ServerDashMobile` 通用 iOS Simulator 目标兼容构建通过，日志为 `/tmp/serverdash-mac-polish-final-mobile-build.log`。本轮没有修改 SwiftData V5、同步包、凭据格式或移动端能力白名单。

Debug 隔离入口使用独立的 `ServerDashMacQA` 应用 target 和 `ServerDashMacQA` Scheme，Bundle ID 固定为 `com.serverdash.app.macqa`。夹具能力由该 target 的 `SERVERDASH_MAC_QA` 编译条件启用；生产 `ServerDash` 应用即使收到相同启动参数也无法进入夹具。`Scripts/prepare-mac-ui-fixture.sh` 直接构建专用 QA 应用，不再复制或改签生产产物。该入口使用内存 SwiftData、合成主机、文档网段地址、关闭的文件服务和不附加进程的 SSH 控制器；草稿、录制、AI 数据、可信主机及 UserDefaults 均指向隔离目录或独立域。真实应用数据库、设置、凭据、主机和网络连接没有参与窗口检查。

`ServerDashMacQAUITests` 使用真实应用窗口验证仪表盘、机器页和终端路由，并固定覆盖 900×620 最小窗口。可用 `xcodebuild -project ServerDash.xcodeproj -scheme ServerDashMacQA -destination 'platform=macOS' test` 运行；Scheme 与生产构建一样在构建前校验 RDP 依赖。

本轮 `.macqa` 路由还覆盖设置、AI、远程编辑器、导入／导出、SSH/RDP 等连接编辑器以及空白和错误状态；代表性启动用例覆盖 900×620 与 1440×900、浅色与深色参数。`ServerDashMacQA` 和 UI 测试的 `build-for-testing` 已通过，构建产物的 Bundle ID 已核对为 `com.serverdash.app.macqa`。本机执行 XCTest UI runtime 时，测试 Runner 在启用 automation mode 阶段等待 60 秒后超时；当时没有收集到足以判定 TCC 或其他宿主原因的证据，因此本轮没有把 XCUI runtime 标记为通过，也没有修改系统隐私权限。结果包位于 `/tmp/serverdash-macqa-derived/Logs/Test/`，需在可正常启动 UI Runner 的验收机复跑。

通过真实运行的应用窗口检查了 900×620 浅色、1440×900 深色及 1920×1080 浅色布局。900 宽度下分组栏自动收起，分组与标签作为筛选菜单显示，工具栏收进单一溢出菜单且显示／隐藏分组按钮仍可达；1440 宽度下分组层级、计数、完整工具栏和三列紧凑卡片同时可见。长中文主机名、在线、连接中、失败、离线、待检测及未知延迟状态均由真实 SwiftUI/AppKit 窗口显示。1920×1080 场景挂载 16 个持久 SSH 面板和可调右侧检查器；辅助功能树读取到 16 个连接状态、15 个分隔线，以及综合、CPU、GPU、内存、磁盘、网络、文件、AI、片段九类检查器入口。这里确认了控件标签可被辅助功能 API 读取，但没有运行 VoiceOver 实际朗读，因此 VoiceOver 仍保留为人工验收项。

1,000 台合成主机、48 个分组和 6 组等价查询的同步主线程基准中，旧的重复层级扫描与逐次排序耗时约 1,446.9 ms；投影一次构建及缓存排序耗时约 36.2 ms，语义结果一致；随后 100 次相同更新约 0.074 ms。编辑器基准使用 1,300,000 个 UTF-16 单元、50,000 行：靠近文件末尾的 100 次行号查询从约 2.559 s 降到 0.000042 s，30 次尾部编辑的行索引维护从约 2.359 s 降到 0.000100 s；大文件按设计跳过语法正则高亮。数值来自同一次全量测试运行，仅用于本机前后对比，不作为跨设备性能承诺。

新增回归覆盖工具栏唯一入口、分组栏窄宽切换偏好、筛选后选择清理、同目录刷新选择保留、目录失败原位重试、5–300 秒整数超时、Bundle 版本显示、SSH／本地／串口命令能力、终端搜索隔离、外观与窗口尺寸变化不重启 PTY、中文组合输入、光标／选择／撤销保留、版本化高亮任务及退出前草稿落盘。伪串口 PTY 和本地 `/bin/cat` 由测试进程创建；实体串口拔插、真实 VNC／RDP／WebDAV／SSH 服务和 VoiceOver 朗读未执行，继续按上一节列为设备验收项。

## 2026-09-13 v1.0.2 隐私与可靠性复验

本次复验使用 `codex/mac-privacy-reliability` 分支。位置查询迁移、SFTP 多选下载计划、主机错误脱敏和受管进程排空的 28 项聚焦测试全部通过；最终 macOS 全量测试执行 398 项，零失败。全量日志为 `/tmp/serverdash-v102-mac-final-tests.log`，结果包为 `.build/privacy-full-tests/Logs/Test/Test-ServerDash-2026.09.13_08-24-12-+0800.xcresult`。

全量测试重新生成 `/tmp/serverdash-workbench-ui-qa/` 中的 34 张隔离界面夹具图，其中包含浅色和深色安全设置页。检查确认服务器公网 IP 与大致位置查询默认关闭，启用前明确显示由受管服务器访问 ipinfo.io；SSH 主机密钥验证显示为始终启用，并提供可信主机管理入口。夹具继续使用内存数据、模拟服务及文档网段地址，不访问用户数据库、凭据或真实主机。

发布脚本成功完成 macOS 通用 Release、iPhone Simulator Release、iPad Simulator Release 和无签名 iOS Device Release 兼容构建。macOS 与两份模拟器应用均包含 arm64、x86_64，设备兼容构建为 arm64；三端 `CFBundleShortVersionString` 均为 1.0.2，`CFBundleVersion` 均为 7。macOS ad-hoc 签名通过 `codesign --verify --deep --strict`，DMG 通过 `hdiutil verify`，四项发布文件通过 SHA-256 校验。构建日志为 `/tmp/serverdash-v102-release-build.log`，产物位于 `dist/v1.0.2/`。

本轮没有修改 SwiftData V5、同步包、凭据格式、连接协议或移动端能力白名单。实体 iPhone/iPad、VoiceOver 实际朗读、实体串口、真实 VNC/RDP/SSH 服务及真实 WebDAV 双设备同步未执行，仍列为设备验收项。

## 2026-09-21 v1.0.4 构建自举、审查收口与 RDP 修复验收

本轮在 `main` 发布，版本元数据为 1.0.4（Build 9），Swift 语言模式保持 5.9。macOS 应用和测试目标继续启用 `SWIFT_STRICT_CONCURRENCY=complete`；SwiftData V5、同步包、凭据格式、连接协议及移动端能力白名单未改变。RDP 仍为开发中。

### 最终自动化证据

- GitHub Actions run `35564546008`（提交 `4d4d9fc`）通过 Strict build and tests 与 Main release smoke。
- 严格并发门禁要求第一方源码与测试编译告警为 0；RDP 原生探针随同一作业执行。
- 构建自举、缓存损坏/并发/保留策略的隔离测试见 `Docs/MAC_BUILD_RELIABILITY_QA.md`。
- 本版本新增或收紧的回归覆盖 hop 扫描 fail-closed、工作组 NLA 域名、自签发 RDP 证书链，以及 iOS 兼容目标不依赖 FreeRDP 符号。

### 发布构建与附件

- [x] `Scripts/build-release-artifacts.sh 1.0.4` 完成 macOS 通用 Release、iPhone Simulator Release、iPad Simulator Release 与无签名 iOS Device Release 兼容构建。最终产物位于 `dist/v1.0.4/`。构建日志为 `/tmp/serverdash-v104-release-build.log`。
- [x] macOS、模拟器与设备兼容 App 的 `CFBundleShortVersionString` 均为 1.0.4，`CFBundleVersion` 均为 9。
- [x] macOS 与模拟器二进制均包含 arm64、x86_64；无签名 iOS Device 兼容二进制为 arm64。
- [x] macOS 构建目录和挂载 DMG 内的 `ServerDash.app` 均通过 `codesign --verify --deep --strict`；签名为 ad-hoc。DMG 通过 `hdiutil verify`。
- [x] macOS DMG、两份模拟器 ZIP 与离线发布通知共四项文件均通过 `ServerDash-1.0.4-SHA256SUMS.txt` 回读校验。

### 现场验收

以下项目需要设备或真实服务，保持未通过状态：

- [ ] 实际 VoiceOver 朗读、顺序与完整键盘导航。
- [ ] 实体串口拔插、端口占用、异常断开、恢复和不同驱动/高波特率。
- [ ] 真实 SSH 多因素认证、VNC 系统屏幕共享、RDP Windows 互操作及长时间会话退出。
- [ ] 真实 WebDAV 强 ETag、双设备同步、冲突、断网恢复与恢复密钥交换。
- [ ] 实体 iPhone/iPad 的兼容性、前后台行为和辅助功能。

## 2026-09-21 macOS 原生界面与 Apple-only 主线验收

本轮使用 `codex/mac-native-ui-polish` 分支，继续保持系统字体、语义颜色和原生非玻璃视觉。产品版本仍为 1.0.4（Build 9）；SwiftData V5、同步包、凭据格式、连接协议和移动端界面均未改变。

### 自动化与构建

- 严格并发构建通过，第一方 `Sources`、`Tests`、`MacUITests` 和 `Native` 编译告警为 0。依赖告警实例为 SwiftTerm 87、ZIPFoundation 4、NIOSSH 0、Citadel 0；FreeRDP/WinPR 继续由 RDP bootstrap 单独记录。构建日志为 `.build/concurrency-gate/build.log`。
- macOS 全量测试执行 **473 项，全部通过、零失败**，用时 117.077 秒。日志为 `/tmp/serverdash-native-ui-final-tests.log`，结果包为 `.build/concurrency-gate/Logs/Test/Test-ServerDash-2026.09.21_18-46-56-+0800.xcresult`。
- Apple-only tracked-tree 门禁夹具 17/17 通过，开发工作区与发布诊断夹具 24/24 通过。检查覆盖 Windows 分支来源、大小写变体、Windows 产品目录、Windows 客户端工程格式、Windows 文档、脚本和发布工作流、未知根目录及非 Apple 平台声明；Apple 侧 RDP、FreeRDP/WinPR、远端 Windows 识别、证书夹具和相关文档继续允许。
- 通用 macOS Release 构建通过，应用包含 `x86_64` 与 `arm64`；日志为 `/tmp/serverdash-native-ui-final-release.log`。iOS Simulator 兼容构建通过并包含 `x86_64` 与 `arm64`，无签名 Device 构建通过并包含 `arm64`；日志分别为 `/tmp/serverdash-native-ui-final-mobile-sim.log` 和 `/tmp/serverdash-native-ui-final-mobile-device.log`。
- `ServerDashMacQA` 与 UI 测试完成 `build-for-testing`，Bundle ID 为 `com.serverdash.app.macqa`。隔离入口使用内存数据库、模拟状态、独立凭据域、临时 SSH 配置和禁用网络的服务配置，不访问用户数据库、凭据或真实主机。

### 界面、行为与性能

- QA 路由覆盖仪表盘、主机网格／列表、终端 1／4／16 面板、录制与资源页面、监控、SFTP、RDP、设置、AI、远程编辑、导入导出、连接编辑器、批执行、空状态和错误弹窗；快捷键用例覆盖 `⌘R`、`⌘⇧R`、`⌘N`、`⌘F`、`⌘W`、Escape 和 `⌘⌥I`。
- 真实隔离应用窗口已检查 900×620 的仪表盘、SSH 编辑器、导入预览、批执行和录制配置，以及 1920×1080 的 16 面板终端。最终 900×620 导入预览使用单栏候选列表与底部摘要，长来源名称不再逐字换行；批执行和录制配置的内容、原生取消／确认操作及键盘焦点均位于可用区内。缓存布局夹具只用于补充尺寸和语义检查，不代替这些真实窗口检查。
- 1,000 台主机、48 个分组和 6 组查询的同步主线程基准由 1,525.353 ms 降至 36.751 ms，100 次缓存更新耗时 0.0701 ms，语义结果一致。
- 10,000 项隔离 SFTP 列表的加载、隐藏文件切换、搜索及清除搜索总计 71.163 ms，并验证筛选后不可见选择会被移除。
- 1,300,000 个 UTF-16 单元、50,000 行的编辑器基准中，100 次尾部行号查询由 2.636 s 降至 0.0000363 s；30 次尾部编辑的行索引维护由 2.436 s 降至 0.0000972 s。
- 回归覆盖 Keychain 凭据保留与回滚、异步 lease 冲突、SSH 密钥正文与口令、路线 revision 变化、未来连接配置刷新，以及主题、布局、检查器和切页不重启既有会话控制器。

### 保留验收项

- 当前宿主的 XCTest UI runtime 在启用 automation mode 时超时；未确认是 TCC、Runner 签名还是其他启动故障。因此只标记 UI 测试 `build-for-testing` 通过，不标记完整 XCUI 矩阵通过，也没有修改系统隐私权限。
- 实际 VoiceOver 朗读、完整键盘遍历、实体串口、实体 iPhone/iPad 及真实 SSH、VNC、RDP、WebDAV 服务互通尚未执行。

GitHub [`Apple-only main protection` 规则集](https://github.com/xk-7/ServerDash/rules/23774515)已于 2026-09-23 通过只读 API 回读：状态为 `active`，目标为默认分支，要求 PR 和严格的 `Apple main scope / Validate Apple-only tree` 必需检查，只允许普通 merge，禁止强推与删除，`bypass_actors` 为空。

## 2026-09-13 v1.0.3 并发与退出可靠性验收

本轮使用 `codex/mac-concurrency-stability` 分支，版本元数据为 1.0.3（Build 8），Swift 语言模式保持 5.9。macOS 应用和测试目标启用 `SWIFT_STRICT_CONCURRENCY=complete`；SwiftData V5、同步包、凭据格式、连接协议及移动端能力白名单未改变。

### 最终自动化证据

- `Scripts/check-app-concurrency.sh` 在清空 DerivedData 后执行严格并发 `build-for-testing`，当前提交的第一方源码、测试及宏展开编译告警为 **0**。最终日志为 `/tmp/serverdash-v103-concurrency-final.log`。
- 同一门禁内记录的第三方告警实例为 SwiftTerm 87、ZIPFoundation 4、FreeRDP/WinPR 42，NIOSSH 0、Citadel 0。它们来自 vendored 或二进制依赖，只作信息记录，本轮没有修改依赖源码。
- 当前最终源码执行 macOS 全量测试 **411 项，全部通过、零失败**，测试用时 86.631 秒。日志为 `/tmp/serverdash-v103-mac-release-final.log`；结果包为 `.build/concurrency-gate/Logs/Test/Test-ServerDash-2026.09.13_15-49-42-+0800.xcresult`。
- 新增回归覆盖一次性 continuation 的自然退出/回调/超时竞争和单次恢复，退出草稿冻结、保存失败重试/取消、300 毫秒进度门限、共享 8 秒截止、强制终止、迟到回调、`.partial` 录制、并发日志脱敏、终端通知释放、RDP 启停、可信主机隔离及监控排序。

### 当前实现检查点

- 退出入口统一到 `MacTerminationDelegate`；草稿保存失败时先关闭进度层，再提供重试保存或取消退出。取消发生在全局关闭前，编辑状态可以恢复。
- 草稿保存成功后开始计算 8 秒绝对期限。目录同步、监控、隧道、受管进程、交互会话、文件传输和录制并行收尾；期限到达后取消剩余任务，迟到结果不再更新关闭报告。
- 进程和隧道在关闭时停止接收新任务，并区分正常完成、TERM/KILL 后强制完成及超时。录制排空使用通知和一次性 continuation，不阻塞 GCD 工作线程。
- 退出报告只包含固定组件、结果和耗时；事件写入在进入 OSLog 和最多 300 条的界面列表前脱敏。临时密钥材料在关闭收尾后清理。
- 隔离应用夹具输出 59 张 PNG 到 `/tmp/serverdash-workbench-ui-qa/`。退出进度层在 900×620、1440×900 与 1920×1080 三种窗口尺寸下分别验证浅色和深色，共六个组合；检查其作为无取消控件的 AppKit 模态键盘窗口、无关闭/默认按钮，并读取到“退出进度”和“退出状态”辅助功能标签。

### 发布构建与附件

- [x] `Scripts/build-release-artifacts.sh 1.0.3` 完成 macOS 通用 Release、iPhone Simulator Release、iPad Simulator Release 与无签名 iOS Device Release 兼容构建。最终产物位于 `dist/v1.0.3/`。
- [x] macOS、模拟器与设备兼容 App 的 `CFBundleShortVersionString` 均为 1.0.3，`CFBundleVersion` 均为 8。
- [x] macOS 与模拟器二进制均包含 arm64、x86_64；无签名 iOS Device 兼容二进制为 arm64。两份模拟器 App 均声明 `iPhoneSimulator`，`UIDeviceFamily` 同时包含 1 与 2。
- [x] macOS 构建目录和挂载 DMG 内的 `ServerDash.app` 均通过 `codesign --verify --deep --strict`；签名为 ad-hoc，`TeamIdentifier=not set`。DMG 通过 `hdiutil verify`，并包含 App 与 Applications 符号链接。
- [x] iPhone/iPad ZIP 均通过完整性测试；解包后顶层目录、`ServerDashMobile.app`、安装说明、版本、平台、设备族与架构均通过复核。
- [x] macOS DMG、两份模拟器 ZIP 与离线发布通知共四项文件均通过 `ServerDash-1.0.3-SHA256SUMS.txt` 回读校验。

首次完整发布构建日志 `/tmp/serverdash-v103-release-build.log` 跨架构/目标记录 SwiftTerm 16、NIOSSH 135、Citadel 54、FreeRDP/WinPR 84 次依赖告警，另有 4 次无 AppIntents 依赖的元数据跳过提示和 1 次既有移动端方向验证提示；ZIPFoundation 为 0。这些计数包含多个目标的重复编译。随后修正第一方原生 BOOL 与移动端日志调用告警，并用全部四种构建重新生成附件；最终重建日志 `/tmp/serverdash-v103-release-rebuild.log` 没有第一方源码告警。本轮按范围不改变移动端方向或功能。

### 现场验收

以下项目需要设备或真实服务，保持未通过状态：

- [ ] 实际 VoiceOver 朗读、顺序与完整键盘导航。
- [ ] 实体串口拔插、端口占用、异常断开、恢复和不同驱动/高波特率。
- [ ] 真实 SSH 多因素认证、VNC 系统屏幕共享、RDP Windows 互操作及长时间会话退出。
- [ ] 真实 WebDAV 强 ETag、双设备同步、冲突、断网恢复与恢复密钥交换。
- [ ] 实体 iPhone/iPad 的兼容性、前后台行为和辅助功能。

## 2026-09-23 macOS 界面与交互一致性复验

本轮工作分支为 `codex/mac-ui-consistency`。项目配置仍为 1.0.4（Build 9）；以下为本轮独立验收清单，不沿用先前版本的通过状态。

### 行为与性能

- [x] 仪表盘目录投影回归覆盖父子分组、空分组和标签、旧主机的默认分组、旧名称筛选迁移至目录 ID、跨页面改名后保持 ID 及删除后清除失效选择。真实窗口选择“生产环境”父组后显示 4/8 台主机，包含子组主机；筛选菜单显示空分组与空标签。
- [x] 搜索、标签和监控开关的组合筛选回归通过；“刷新全部”在 900×620 真实仪表盘窗口仍可见。筛选只计算主机投影，未触发监控调度；现有会话控制器生命周期回归包含在全量测试中。本轮未连接真实服务验证远端监控任务。
- [x] SFTP 真实浏览器在 900×620 与 1440×900 间原位缩放：宽窄两种操作栏、列显示随实际内容宽度切换，长中文路径和搜索始终可见。往返缩放后同一个表格保持“应用配置-15.txt”选中，滚动条值保持为 1。窄窗更多菜单包含上传、下载和隐藏文件等操作；权限与压缩原生弹窗可打开，非法权限值原位报错并聚焦输入框。控制器未因布局切换重建，未连接真实 SFTP 服务。
- [x] 终端与快捷键分类使用 grouped Form；真实窄窗终端外观预览在编辑区下方可展开/收起，宽窗改为左右排列。现有设置绑定与终端会话生命周期回归通过；未对真实 PTY 会话执行本轮窗口缩放验收。
- [x] 隔离数据操作基准在 M1、16 GB 内存、macOS 26.3.2、Xcode 26.3 上完成：Dashboard 1,000 台合成主机与 48 个分组的投影构建耗时 16.138 ms，5 次查询耗时 33.556 ms，总计 49.694 ms；SFTP 10,000 项相关操作总计 60.234 ms。这些数字不包含 UI 绘制、滚动或网络，测试范围与旧基线不同，不能直接作同比结论。

### 隔离窗口与构建

- [x] `ServerDashMacQA` 的 SFTP 路由现在挂载真实 `SFTPBrowserView`、合成控制器和文件表格，控制器不自动连接；设置分类启动参数可进入终端、快捷键及其他分类。夹具仍使用内存数据库、隔离凭据域及禁用网络的连接入口。
- [x] 真实隔离应用窗口检查了仪表盘和 SFTP 的 900×620、1440×900 浅色与深色四种组合，以及全部九个设置分类在同样四种组合下的布局。检查包含长中文路径、表单焦点、文件菜单、弹窗、折叠预览和辅助功能树中控件名称/标识；未以缓存截图替代真实窗口。
- [x] 严格并发 `build-for-testing` 通过，项目自有代码编译告警为 0；macOS 全量测试 **482/482** 通过。日志分别为 `.build/concurrency-gate/build.log` 和 `.build/ui-consistency-results/macos-full.log`。Xcode 工程生成检查通过，Apple-only tracked-tree 夹具 **17/17** 通过。
- [x] 通用无签名 Mac Release 构建及 `verify-ci-release.sh` 架构/动态链接路径检查通过；iOS Simulator Release 和无签名 Device Release 兼容构建通过。日志位于 `.build/ui-consistency-results/macos-release.log`、`ios-simulator-release.log` 和 `ios-device-release.log`。
- [ ] XCUI 运行时矩阵。测试目标已在严格并发门禁中成功编译，但本机 `test-without-building` 在测试进程建立连接前被 signal kill，结果包显示 `passedTests: 0` 和 “Early unexpected exit, operation never finished bootstrapping”。结果包为 `.build/ui-consistency-results/macqa-targeted.xcresult`；原因尚未确认，不能标记 XCUI 运行时通过。

实际 VoiceOver 朗读、实体串口、实体 iPhone/iPad，以及真实 SSH、VNC、RDP、WebDAV 服务互通尚未在本轮执行，继续保留为设备验收项。

## 2026-09-25 macOS 核心页面密度与交互完善验收

本轮继续使用原生非玻璃外观，版本保持 1.0.4（Build 9）。以下项目只有在对应构建、测试或真实窗口检查完成后才能勾选。

### 隔离 QA 与故障诊断

- [x] QA 五文档长中文标签场景中，第五个选中标签自动滚入可见区；900×620 窗口内搜索 `server` 显示“1 / 2 处”，不存在的词显示“无匹配”。25 项 SFTP 夹具从 900×620 放大至 1440×900 再缩回，已选“应用配置-15.txt”和滚动锚点保持。
- [x] 签名 QA 应用中的 1,000 主机夹具实际显示 1,003 台（含三个额外协议示例）。1440×900 原生表格滚动三页后选中 `fixture@192.0.2.49:22`，经真实侧栏“机器→仪表盘→机器”往返，辅助功能树仍报告“已选 1 台”、同一行为 selected，滚动条仍在约 0.05549；缩至 900×620 后选择保持，首行仍在附近的 `.40` 主机。选择状态已由应用级内容视图持有，不依赖重新创建的机器页。
- [x] 25 项 SFTP 浏览器的控制器由 QA 根视图持有；选中“应用配置-15.txt”并滚动后，经 SFTP→设置→SFTP 路由重挂，辅助功能树仍报告相同选中项与滚动锚点。原生表格列配置及锚点由浏览控制器持有，原位缩放和重挂均不触发远端连接。
- [ ] 使用真实 `ServerDashMacQA` 窗口检查仪表盘、机器网格/列表、终端检查器、SFTP、编辑器及九个设置分类：900×620、1440×900 的浅色和深色，以及 1920×1080 宽屏。记录长中英文、空/加载/失败状态、键盘焦点和辅助功能树中的标签；实际 VoiceOver 朗读需另行验收。
- [x] 已在真实 `.macqa` 窗口完成部分逐项检查：900×620 浅色/深色仪表盘的总览、全宽搜索、筛选菜单、首行卡片和底部终端/失败重试操作均可见；同尺寸深色机器网格的搜索、筛选、长名称提示与首行快速连接可见。1440×900 浅色/深色仪表盘，以及深色机器网格/列表显示完整；机器列表为单一原生 `Table`，辅助功能树提供列头与行选择。900×620 浅色 SFTP 路径与搜索始终可见，权限/所有者列已隐藏，文件行可以选择；编辑器输入无结果查询后出现“搜索结果：无匹配”。这些是实际窗口截图与 AX 树观察，不代表尚未逐项检查的页面/尺寸通过。
- [x] 设置页九个分类均在真实 QA 应用的 900×620、1440×900 浅色与深色组合中打开并读取辅助功能树；各分类分组标题和主要控件可达。另目视检查 900×620 深色终端设置的分组表单和上下排列，以及 1440×900 浅色终端设置的左右编辑/预览，均未见裁切。无效本地 Shell 草稿显示原位错误，保存按钮现只在路径有效且草稿有变更时启用；取消恢复有效配置。实际 VoiceOver 朗读和完整键盘遍历仍未执行。
- [x] 最终增量签名 QA 构建 `/tmp/serverdash-mac-ui-density-qa-shell-final.log` 通过，App 与 Runner 均通过 `codesign --verify --deep --strict`。真实终端设置窗口输入 `/definitely/missing/shell` 后，辅助功能树显示原位错误且“保存”为 disabled；改为 `/bin/sh` 后“保存”可用；点击“取消”后路径恢复为空，“保存”再次禁用。测试过程未提交草稿或改动有效 Shell 配置。
- [x] 以 ad-hoc 签名的独立 Debug 构建运行单个 XCUI smoke test，并核对 QA App 与 Runner 的 `codesign --verify --deep --strict`。Runner PID 91000 已启动，测试方法执行前在 `enabling automation mode` 等待 60.04 秒后超时（22:29:20.636–22:30:20.675）；结果包 `.build/macqa-signed-smoke.xcresult` 为 `passedTests: 0`。`testmanagerd.log` 记录了对 Runner 的授权请求及 `result:error 1: (null)`，限定进程的 `tccd` 日志未出现明确拒绝；证据不足以判定 TCC、签名或宿主服务哪一项是根因。先前 2026-09-23 的 bootstrap 前 signal kill 是不同观察结果。本机 XCUI runtime 继续标为**未通过**，未修改系统隐私权限，也未执行其余 XCUI 断言。
- [x] 10,000 项 SFTP 真实窗口暴露数据基准未覆盖的 UI 卡顿：清除搜索曾超过 20 秒，进程采样显示主线程在原生表格自动行高计算中反复创建 SwiftUI 单元格。SFTP 表格单独采用 30pt 固定行高后，同一签名 QA 窗口搜索末项耗时 1.459 秒、清除搜索 1.750 秒、滚动三页 1.705 秒（均包含 CUA 操作及辅助功能树读取）；25 项 900×620 浅色和深色截图确认行高、文本与选中态可读。原始卡顿采样保留在 `/tmp/serverdash-sftp-10000-hang.sample.txt`；共享表格桥默认不固定行高，机器列表未受影响。

### 回归与构建待填

- [x] 最终源码的严格并发 `build-for-testing` 与第一方零告警检查通过；`test-without-building` 运行 **497 项 macOS 测试，497 项通过、0 失败**。结果包 `.build/final-macos-tests-20260925-frozen-v2.xcresult`，日志 `/tmp/serverdash-mac-ui-density-strict-build-final-frozen-v2.log` 和 `/tmp/serverdash-mac-ui-density-macos-tests-final-frozen-v2.log`。
- [x] 通用 Mac Release 构建通过，`ServerDash` 与 RDP archive 均为 `x86_64 arm64`；`Scripts/verify-ci-release.sh` 的架构及动态链接路径检查通过。iOS Simulator Release 为 `iPhoneSimulator` 平台、`x86_64 arm64`；无签名 Device Release 为 `iPhoneOS` 平台、`arm64`，签名检查确认未签名。日志分别为 `/tmp/serverdash-mac-ui-density-macos-release-final-frozen-v2.log`、`/tmp/serverdash-mac-ui-density-ios-simulator-release-final-frozen-v2.log` 和 `/tmp/serverdash-mac-ui-density-ios-device-release-final-frozen-v2.log`。三项构建均为第一方 0 告警、0 错误；Mac 的 1 条警告仅为无 AppIntents 依赖时跳过元数据提取，移动端无告警。
- [x] 隔离内存基准：1,000 主机、48 分组、6 次机器页查询，旧逐行层级/排序计算占主线程 1752.366 ms，新投影含建立成本为 38.810 ms，缓存的 100 次状态更新为 0.085 ms；同一夹具的结果语义相等。仪表盘投影建立 16.641 ms、5 次查询 40.743 ms。10,000 项 SFTP 列表建立 14.704 ms、显示隐藏文件 11.113 ms、再次隐藏 11.023 ms、搜索 22.450 ms、清除搜索 10.794 ms，合计 70.084 ms；均在主线程执行，选择清理断言通过。数据源分别为系统临时目录的 `serverdash-mac-browser-benchmark.json`、`serverdash-dashboard-filter-benchmark.json` 和 `/tmp/serverdash-sftp-list-benchmark.json`。这些数字不包含 SwiftUI 绘制、窗口滚动或网络；真实窗口交互另行记录，不与旧口径直接同比。
- [x] `Scripts/test-apple-main-scope.sh` 17/17 通过；`Scripts/macos-dev.sh generate-check` 确认分支基线、1.0.4（Build 9）、生成工程与 RDP 缓存有效，并报告 0 条开发检查告警。
