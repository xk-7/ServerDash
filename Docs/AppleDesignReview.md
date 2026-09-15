# ServerDash macOS Liquid Glass 设计规范

本规范覆盖 macOS 工作台。它保留原生控件、键盘和辅助功能语义，并将 ServerDash 的玻璃视觉集中在 Mac 专用主题层。iPhone 与 iPad 继续使用共享设计系统中的既有实现。

设计规则最初参考 [naplesblue/apple-design-skill](https://github.com/naplesblue/apple-design-skill)，许可见 [第三方声明](THIRD_PARTY_NOTICES.md)。

## 背景与表面

- 主窗口内容背景固定为左上到右下 `#667eea → #764ba2`，并叠加静态径向光晕。详情页、滚动容器和设置内容不得再用不透明背景遮住它。
- macOS 26 的卡片、搜索、浮层及自定义 chrome 使用原生 Liquid Glass；相邻或重叠玻璃内容使用 `GlassEffectContainer` 统一合成。
- macOS 14/15 使用 `ultraThinMaterial` 降级，并叠加白色 10% tint、白色 20% 描边、20pt 连续圆角和柔和双层阴影。
- 普通卡片、交互卡片、chrome、高对比内容底板及突出操作由 `GlassSurfaceRole` 区分。终端、编辑器、RDP 画面和密集 `Table` 保持高对比底板；玻璃只用于其栏位、检查器、状态区和浮层。
- 原生 `NavigationSplitView` 侧栏、统一工具栏、`Table`、`List` 与 `Form` 仍由系统控制，不在整栏上重复添加一层玻璃。

## 字体与颜色

- 标题、分区标题和卡片标题使用静态 Outfit SemiBold/Bold/ExtraBold；正文、标签与按钮使用 Plus Jakarta Sans Regular/Medium。
- 字体通过 `AppTypography` 注册和选择。缺失字形自动回退 PingFang/系统字体；资源缺失或注册失败时使用对应系统语义字体，不阻止应用启动。
- 终端、代码编辑器、命令和地址继续使用等宽字体；变化中的指标继续使用等宽数字。
- 白色品牌文字用于玻璃上的主要层级；次级和三级文字分别使用白色 `0.96` 与 `0.92` 不透明度。可读性 scrim 默认不透明度为 `0.42`，Increase Contrast 时提高到 `0.52`。在线、警告和错误只使用系统语义状态色；选择与主操作使用系统强调色。
- 五个字体文件及 SIL Open Font License 1.1 全文随 macOS `ServerDash` 和隔离的 `ServerDashMacQA` 两个目标打包；`ServerDashMobile` iOS 目标明确排除这些资源，移动端字体行为不变。

## 形状、层级与动效

- 标准玻璃卡片使用 20pt 连续圆角。其他控件沿用设计系统中的命名圆角，不在页面内散落新 token。
- 仪表盘三张总览卡轻微负间距重叠；窄窗口降低重叠量。重叠顺序必须稳定，文本、焦点环和命中区域不能被相邻卡片遮住。
- 卡片首次进入当前页面时按稳定 ID 浮现：透明度 `0→1`、纵向偏移 `12→0`、缩放 `0.98→1`，延迟为 `min(index, 8) × 45ms`。
- `GlassCardEntranceRegistry` 记录已经出现的稳定 ID。筛选后重新出现、监控刷新及返回同一页面不会重播。
- 可点击卡片 hover 精确缩放到 `1.05`，同时提高 `zIndex` 并加强光晕。网格为缩放预留空间；原生表格、列表行、表单和不可点击指标不缩放。

## 辅助功能与系统设置

- Reduce Transparency 使用不透明紫色表面，仍维持文字与状态色对比。
- Increase Contrast 将可读性 scrim 从 `0.42` 提高到 `0.52`，并加强描边与内容分隔，不改变信息含义。
- Reduce Motion 停止位移、缩放和 stagger；内容直接显示在最终位置。刷新数据从不触发入场动画。
- 所有按钮保留清楚的辅助功能名称、help 与现有快捷键；焦点环不得被玻璃 overlay、负间距或 hover 裁切。
- 系统、浅色、深色三种控件外观均受支持。玻璃背景固定使用品牌渐变，不随控件外观替换为另一组品牌色。

## 页面行为

- 工具栏保留唯一的命令入口。仪表盘“刷新全部”、更多刷新选项、菜单栏刷新与快捷键必须同时可达；刷新只更新状态。
- 设置继续使用 `NavigationSplitView + Form` 并恢复上次分类。玻璃用于分类栏、页头和表单外围，输入控件保持系统填充、校验、焦点和键盘行为。
- 弹窗、空状态、导入界面和退出进度层使用统一玻璃表面，并保留原有取消、默认操作、错误恢复及 VoiceOver 语义。

## 完成门禁

- Mac 主题 token 和表面实现集中在 Mac 专用主题层；共享 `DesignSystem.swift` 的 Mac 分支必须由 `#if os(macOS)` 隔离。
- `ServerDashMacQA` 必须保持独立 `.macqa` Bundle ID、内存数据库、合成监控与禁网连接器；真实窗口截图不得由 `cacheDisplay` 结果替代。
- 仪表盘和机器页检查 900×620、1440×900、1920×1080 的浅色与深色；其余主要页面检查 1440×900 的浅色与深色，并单独检查三项辅助功能偏好。
- 自动化结果、实际窗口检查与待人工项目分别记录。只有运行过并留有日志或 xcresult 的检查才标记为通过。
- macOS 14/15 必须单独区分编译兼容检查与真机运行验收；未在对应系统上运行时不得声称运行通过。VoiceOver 真人朗读、顺序和完整键盘导航同样保留为人工验收项。
