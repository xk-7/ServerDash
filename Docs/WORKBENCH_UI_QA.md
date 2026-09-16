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

新增 Debug 隔离入口必须同时使用 `--mac-ui-fixture` 参数和 `.macqa` 后缀的独立 Bundle ID。`Scripts/prepare-mac-ui-fixture.sh` 从 Debug 产物生成独立签名副本。该入口使用内存 SwiftData、合成主机、文档网段地址、关闭的文件服务和不附加进程的 SSH 控制器；草稿、录制、AI 数据、可信主机及 UserDefaults 均指向隔离目录或独立域。真实应用数据库、设置、凭据、主机和网络连接没有参与窗口检查。

通过真实运行的应用窗口检查了 900×620 浅色、1440×900 深色及 1920×1080 浅色布局。900 宽度下分组栏自动收起，分组与标签作为筛选菜单显示，工具栏收进单一溢出菜单且显示／隐藏分组按钮仍可达；1440 宽度下分组层级、计数、完整工具栏和三列紧凑卡片同时可见。长中文主机名、在线、连接中、失败、离线、待检测及未知延迟状态均由真实 SwiftUI/AppKit 窗口显示。1920×1080 场景挂载 16 个持久 SSH 面板和可调右侧检查器；辅助功能树读取到 16 个连接状态、15 个分隔线，以及综合、CPU、GPU、内存、磁盘、网络、文件、AI、片段九类检查器入口。这里确认了控件标签可被辅助功能 API 读取，但没有运行 VoiceOver 实际朗读，因此 VoiceOver 仍保留为人工验收项。

1,000 台合成主机、48 个分组和 6 组等价查询的同步主线程基准中，旧的重复层级扫描与逐次排序耗时约 1,446.9 ms；投影一次构建及缓存排序耗时约 36.2 ms，语义结果一致；随后 100 次相同更新约 0.074 ms。编辑器基准使用 1,300,000 个 UTF-16 单元、50,000 行：靠近文件末尾的 100 次行号查询从约 2.559 s 降到 0.000042 s，30 次尾部编辑的行索引维护从约 2.359 s 降到 0.000100 s；大文件按设计跳过语法正则高亮。数值来自同一次全量测试运行，仅用于本机前后对比，不作为跨设备性能承诺。

新增回归覆盖工具栏唯一入口、分组栏窄宽切换偏好、筛选后选择清理、同目录刷新选择保留、目录失败原位重试、5–300 秒整数超时、Bundle 版本显示、SSH／本地／串口命令能力、终端搜索隔离、外观与窗口尺寸变化不重启 PTY、中文组合输入、光标／选择／撤销保留、版本化高亮任务及退出前草稿落盘。伪串口 PTY 和本地 `/bin/cat` 由测试进程创建；实体串口拔插、真实 VNC／RDP／WebDAV／SSH 服务和 VoiceOver 朗读未执行，继续按上一节列为设备验收项。

## 2026-09-13 v1.0.2 隐私与可靠性复验

本次复验使用 `codex/mac-privacy-reliability` 分支。位置查询迁移、SFTP 多选下载计划、主机错误脱敏和受管进程排空的 28 项聚焦测试全部通过；最终 macOS 全量测试执行 398 项，零失败。全量日志为 `/tmp/serverdash-v102-mac-final-tests.log`，结果包为 `.build/privacy-full-tests/Logs/Test/Test-ServerDash-2026.09.13_08-24-12-+0800.xcresult`。

全量测试重新生成 `/tmp/serverdash-workbench-ui-qa/` 中的 34 张隔离界面夹具图，其中包含浅色和深色安全设置页。检查确认服务器公网 IP 与大致位置查询默认关闭，启用前明确显示由受管服务器访问 ipinfo.io；SSH 主机密钥验证显示为始终启用，并提供可信主机管理入口。夹具继续使用内存数据、模拟服务及文档网段地址，不访问用户数据库、凭据或真实主机。

发布脚本成功完成 macOS 通用 Release、iPhone Simulator Release、iPad Simulator Release 和无签名 iOS Device Release 兼容构建。macOS 与两份模拟器应用均包含 arm64、x86_64，设备兼容构建为 arm64；三端 `CFBundleShortVersionString` 均为 1.0.2，`CFBundleVersion` 均为 7。macOS ad-hoc 签名通过 `codesign --verify --deep --strict`，DMG 通过 `hdiutil verify`，四项发布文件通过 SHA-256 校验。构建日志为 `/tmp/serverdash-v102-release-build.log`，产物位于 `dist/v1.0.2/`。

本轮没有修改 SwiftData V5、同步包、凭据格式、连接协议或移动端能力白名单。实体 iPhone/iPad、VoiceOver 实际朗读、实体串口、真实 VNC/RDP/SSH 服务及真实 WebDAV 双设备同步未执行，仍列为设备验收项。

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

## 2026-09-15 macOS Liquid Glass 工作台验收

本节只记录 `codex/mac-glass-workbench` 的玻璃界面和 QA 基础设施。历史章节中的构建、测试和截图数字属于当时分支，不能作为本轮通过证据。本轮没有修改 SwiftData V5、同步格式、凭据、连接协议、移动端功能或版本号。

### 隔离应用与路由

`ServerDashMacQA` 是独立 macOS 应用目标，Bundle ID 固定为 `com.serverdash.app.macqa`。目标使用 `SERVERDASH_MAC_QA` 编译条件，因此即使没有传入启动参数也只会进入隔离路径：SwiftData 使用内存容器，UserDefaults 使用 `.macqa` 域，草稿、录制及文件目录使用每进程临时目录，监控使用合成快照，SSH/SFTP/RDP 等真实连接被拒绝。QA 目标不会读取或迁移正式应用数据库。

`--fixture-page` 支持 `dashboard`、`machines-grid`、`machines-list`、`monitor`、`terminal`、`sftp`、`rdp`、`settings`、`empty` 和 `dialog`。`--fixture-theme` 支持 `system`、`light` 和 `dark`；窗口使用 `--fixture-width`、`--fixture-height`，主机及终端规模使用 `--fixture-hosts`、`--fixture-panes`。`--fixture-reduce-transparency`、`--fixture-reduce-motion` 和 `--fixture-increase-contrast` 注入玻璃主题覆盖值，仅影响 QA 进程；只有对应截图确实呈现目标辅助功能状态后才记录为通过。

`ServerDashGlassUITests` scheme 在真实合成窗口中运行 UI 测试并将截图保存在 xcresult 附件中。全矩阵覆盖清单为：

- 仪表盘、机器宫格和机器列表：900×620、1440×900、1920×1080，浅色与深色。
- 监控、终端、SFTP、RDP、设置、空状态和弹窗：1440×900，浅色与深色。
- 1440×900 深色分别覆盖 Reduce Transparency、Reduce Motion 和 Increase Contrast。
- 额外检查长中文名称、卡片 hover 1.05 几何、窗口边界、仪表盘刷新入口、1,000 台主机筛选与连续滚动。

`WorkbenchUIFixtureTests` 的 `cacheDisplay` 输出继续只用于布局、原生子视图挂载和辅助功能语义诊断。材质、Liquid Glass 合成、hover、焦点环和实际窗口裁切以 UI 测试附件及人工窗口检查为准。

### 自动化状态

- [x] `xcodegen generate` 后已核对 QA app、UI 测试 target、依赖、Bundle ID 和共享 scheme；`ServerDashGlassUITests` 的 `build-for-testing` 通过，构建产物 Bundle ID 为 `com.serverdash.app.macqa`，五个字体文件均在 App Resources 中。
- [x] `MacGlassThemeTests` 7 项与 `MacUIFixtureConfigurationTests` 6 项，共 13 项聚焦回归测试通过，零失败。它们覆盖公开 token、表面角色、稳定 ID 只入场一次、Reduce Motion/刷新、字体缺失回退与实际包内注册，以及路由、尺寸、主机数、面板数、辅助功能参数、凭据后端和禁网边界。
- [x] `ServerDashGlassUITests` 真实 QA 窗口全矩阵最终复跑 **10/10 组通过**，导出 37 张 PNG。已覆盖全部路由、三档窗口尺寸、浅深色、三种辅助功能、仪表盘刷新、单窗口设置入口、SFTP 离线数据、hover 几何及千台主机性能。执行入口为 `Scripts/run-mac-glass-ui-tests.sh`。
- [x] 弹窗重复背景修复后，核心页面组再次通过；浅色和深色截图均只保留一层全窗口渐变，圆角玻璃面板无硬边矩形或裁切。最后三处纯字体映射修正后的额外 UI 重试被 macOS 26 的“Enable UI Automation”本机身份验证挡在 Runner 初始化前，未执行任何应用断言；最终源码已继续通过严格编译和全量单元测试。
- [x] 1,000 台主机的最终实际 UI 测量为 **9.542 秒**：筛选 3.423 秒、恢复全量结果 4.457 秒、单次 `4,160pt` 连续滚动 1.662 秒；本机验收上限为 30 秒。该数字用于本轮交互可用性验收，不作为跨设备性能承诺。
- [x] macOS 全量门禁最终复跑 **425/425 项通过、零失败、零跳过**。
- [x] 严格并发检查最终复跑通过，第一方源码、测试及宏展开编译告警为 **0**。依赖告警计数为 SwiftTerm 87、ZIPFoundation 4、NIOSSH 0、Citadel 0；RDP/WinPR 在 bootstrap 阶段单独记录，不并入上述计数。
- [x] 2026-09-16 从实际 Xcode 失败日志确认，清理 `.build` 后工程中的 XCFramework 文件引用会在 Scheme pre-action 前被校验。现已移除该构建图引用，改由两个 Mac Target 的首个阶段恢复缓存并通过静态库搜索路径链接；从完全缺少 `.build/rdp` 开始的 `ServerDash` Scheme、裸 `ServerDash` Target、裸 `ServerDashMacQA` Target 和严格并发门禁均重新构建成功。
- [x] `ServerDash` 和 `ServerDashMacQA` 两个 macOS 目标均打包五个字体文件与对应 OFL 声明；`ServerDashMobile` iOS 目标未包含这些 Mac 字体资源。
- [x] macOS 14/15 本轮完成 deployment target 与编译兼容检查。
- [ ] macOS 14/15 真机／运行时界面矩阵；本轮未在这两个系统上运行，不记录旧系统运行通过。
- [x] macOS 26.3.2 本机真实 QA 窗口已复验：玻璃合成、三张总览卡重叠、hover 1.05、边缘裁切、浅深色、辅助功能覆盖、焦点与键盘可达性均通过自动化及截图检查。
- [x] Mac 通用 Release 构建与产物检查通过：可执行文件包含 arm64 与 x86_64，最低系统为 macOS 14，版本为 1.0.3（Build 8），五个字体与两份 OFL 声明均在包内，二进制和应用包未发现开发机路径泄漏。
- [x] iOS Simulator 兼容构建通过。
- [x] 无签名 iOS Device 兼容构建通过。
- [ ] VoiceOver 实际朗读、顺序与完整键盘导航。

本轮自动化覆盖不替代 VoiceOver 真人朗读，也不替代 macOS 14/15 实际运行验收。这些运行和人工验收项在取得对应证据前保持未通过。
