# ServerDash 1.0.1 发布通知

ServerDash 1.0.1（Build 6）于 2026-09-11 发布。本版本集中交付 macOS 原生工作台和日常体验优化，并包含自 1.0.0 以来尚未进入正式版本的终端、文件、连接、同步、录制、AI 与 RDP 开发实现。iPhone/iPad 保持独立能力边界；本次提供的移动端附件仅供 Xcode Simulator 使用。

## macOS 工作台与日常体验

- 主机管理采用原生主侧栏、层级分组与标签目录、网格/原生 Table、批量整理、隐私模式和统一窗口工具栏。窄窗口自动收起辅助栏并提供筛选菜单，宽窗口恢复用户偏好。
- 主机列表以共享投影集中计算层级、计数、筛选和排序；卡片、表格、状态及操作区更紧凑。1,000 台合成主机的等价查询在本机基准中由约 1,446.9 ms 降至约 36.2 ms。
- 终端保留持久标签、拖拽、最多 16 个 SSH 面板、自由分屏与 4×4 网格；统一顶部操作和底部工具，并提供固定目标清单的批执行及 15 类预设高亮。
- 右侧检查器提供综合、CPU、GPU、内存、磁盘、网络、文件、AI 和片段分类；窗口变窄时改用弹出面板。调整窗口、主题、布局和检查器不会重建会话。
- SSH、本地 Shell 和串口共享明确的搜索、字号与外观能力；分屏、批执行和隧道仍限于 SSH。本地/串口不再在视图更新时抢占搜索、弹窗、路径输入或中文输入法焦点。
- 设置保留上次分类，连接与认证超时只接受 5–300 秒整数；显示版本来自应用元数据。表单的保存、取消、错误与焦点行为已统一。

## 连接、文件与配置

- SwiftData 升级为固定 V1–V5 Schema 的增量迁移。V5 增加分组/标签、VNC/串口记录、SSH 高级设置、目录同步任务和配置同步映射，同时保留既有 UUID 与凭据引用。
- macOS 新增用户登录 Shell、IOKit/termios 串口会话和系统“屏幕共享”VNC 启动；SSH 增加 Keep-Alive、连接/认证超时、会话日志、交互连接前后本地命令及 HTTP-to-SOCKS 隧道。
- SFTP 修复精确目标文件名、特殊字符字面路径和递归删除问题；补齐搜索、隐藏文件、路径复制、同主机复制/剪切/粘贴、归档、权限修改和本地应用打开。
- 原生多标签远程编辑器支持行号、搜索、编码、语法高亮、草稿恢复和版本冲突保护。高亮任务可取消并按文档版本应用；中文组合输入、后台保存和切换文档会保留光标、选择与撤销记录。
- 文件夹同步默认手动双向比较并预览差异，可单独开启本地改动自动上传；删除和双边修改冲突始终需要选择，且不跟随符号链接。
- 默认关闭的 WebDAV 配置同步使用版本化 AES-GCM 包、基线比较、删除标记、冲突预览和 ETag 条件写入。同步密钥保存在本机 Keychain，并支持恢复密钥显式导出/导入。
- 会话迁移支持预览导入 XShell、SecureCRT、MobaXterm、FinalShell、XTerminal、PuTTY、ServerDash JSON 和 OpenSSH Config；可用导出格式不携带凭据，未完成真实客户端验证的格式继续禁用。

## 其他 macOS 功能

- 会话录制支持本地回放、时间轴、空闲跳过和最长五分钟 GIF 片段导出。
- AI 助手支持多个独立提供商配置、原生流式响应和逐连接终端上下文授权；API Key 使用本机专用 Keychain 项。
- 内嵌 RDP 使用 FreeRDP/WinPR，并保留证书确认和高级显示/重定向选项。Windows 登录、音频、文件交换、真实多显示器和性能仍未完成互操作验收，因此该能力继续标记为开发中。

## 隐私与安全默认值

- 本地连接前后命令、目录自动上传和 WebDAV 同步均默认关闭。导入或同步的本地命令不会自动启用；前置命令失败会阻止连接，后置命令失败会明确报告。
- 配置同步不包含密码、私钥、信任记录、终端历史、录制、监控数据、本机目录授权或串口设备绑定。
- 本地应用打开的是下载副本，只有显式点击“上传修改”才会回写。远端文件变更、删除或权限失败时保留草稿，并要求重新载入、另存为或明确覆盖。

## 下载文件

- `ServerDash-1.0.1-macOS.dmg`：macOS 通用应用，支持 Apple Silicon 与 Intel。
- `ServerDash-1.0.1-iPhone-Simulator.zip`：用于 Xcode iPhone Simulator。
- `ServerDash-1.0.1-iPad-Simulator.zip`：用于 Xcode iPad Simulator。
- `ServerDash-1.0.1-SHA256SUMS.txt`：全部构建产物的 SHA-256 校验值。
- `ServerDash-1.0.1-Release-Notice.md`：本发布通知的离线副本。

## 安装

macOS 用户下载 DMG 后，将 ServerDash 拖入“应用程序”。当前构建使用 ad-hoc 签名且未经 Apple 公证；首次打开时可能需要按住 Control 点击应用并选择“打开”，或在“系统设置 → 隐私与安全性”中允许运行。

iPhone 和 iPad 附件是模拟器构建，不能安装到实体设备。解压后可运行：

```bash
xcrun simctl install booted ServerDashMobile.app
xcrun simctl launch booted com.serverdash.app.ios
```

## 验证范围

- macOS 全量测试 394 项全部通过、零失败；macOS Release 构建及 `ServerDashMobile` 通用 iOS Simulator 兼容构建通过。
- 使用隔离内存数据与模拟服务，在真实应用窗口检查 900×620 浅色、1440×900 深色及 1920×1080 的 16 面板/检查器布局；测试未访问用户数据库或真实主机。
- 大文件夹具覆盖 1,300,000 个 UTF-16 单元和 50,000 行；末尾行号查询与尾部索引维护从秒级降至亚毫秒。基准仅表示同一台测试 Mac 的前后对比。
- iPhone/iPad 本轮仅完成共享模型与接口的模拟器兼容构建；附件不是 IPA，也未通过 TestFlight 或 App Store 分发。
- 实体 iPhone/iPad、VoiceOver 实际朗读、实体串口拔插与占用恢复、真实 VNC/RDP/SSH 服务互操作、真实 WebDAV 强 ETag/双设备同步及断网恢复均未执行，不标记为通过。

更多运行边界和验证证据见 [macOS 工作台验收记录](WORKBENCH_UI_QA.md)、[连接说明](WORKBENCH_CONNECTIONS.md)、[文件与目录同步说明](WORKBENCH_FILES.md)及[配置同步说明](WORKBENCH_SYNC.md)。
