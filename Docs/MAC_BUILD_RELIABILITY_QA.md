# macOS 构建自举与工作区可靠性验收记录

验收日期：2026-09-14

本记录覆盖 ServerDash 1.0.3（Build 8）的构建基础设施改造。本轮没有修改
SwiftData、同步包、凭据格式、连接协议或移动端能力。

## 工作区

- 主工作区保持在 main，功能分支位于同级 ServerDash-worktrees 目录。
- 所有已注册 worktree 均已移出 .build。
- Windows 预览分支、提交与远端未改变；迁移前后安装包 SHA-256 均为
  d68b3f848a937aeed5246654eed5b572cb04213f1200a06f6dbc28797a4d4b21。
- 最终检查时，除本功能分支的预期修改外，其余五个工作区均无已跟踪修改。

## RDP 自举与缓存

- Xcode 26.3、Swift 6.2.4、macOS SDK 26.2 下的最终内容键为
  7bf377779ce2b4d31d14d4ecd0b41a2c4ff2f39bb6bf1a98ed0750e778bc593e。
- 清空产物后的 arm64 与 x86_64 源码冷构建通过，用时约 180 秒。
- 缓存校验约 1.15 秒；使用不可达下载地址的离线命中约 2.42 秒。
- 2026-09-16 复现发现，Xcode GUI 的一次 Run 在清理 `.build` 后先校验工程中的
  XCFramework 文件引用，Scheme pre-action 未获得执行机会。工程现改为通过静态库
  搜索路径链接，并在 Mac Target 首个构建阶段再次执行自举，不再让缺失的忽略文件
  阻断构建图。
- 移除工作区 `.build/rdp` 后直接执行共享 `ServerDash` Scheme，预操作恢复链接、
  Target 自举阶段完成复核并成功链接应用。CI 严格并发构建也会先移除工作区链接，
  持续覆盖这一回归场景。
- 第二个临时工作区在不可达下载地址下复用同一产物，没有触发源码重建。
- 空缓存且断网时不会留下归档或 XCFramework，并输出 macos-dev.sh bootstrap
  修复命令。
- 隔离夹具覆盖冷构建、命中、损坏重建、工具链换代、并发自举、下载中断、
  构建失败、原子发布、活动租约和两套缓存清理，全部通过。
- 最终 XCFramework 与静态库仅包含 arm64 和 x86_64；头文件与归档未发现
  用户目录、Homebrew 或临时构建路径。

## 构建与测试

- 严格并发 build-for-testing 通过，Sources、Tests 和 Native 第一方编译告警为 0。
- macOS 全量执行 411 项测试，0 失败，测试体用时 88.7 秒。
- RDP 原生 ASan/UBSan 探针通过。
- 通用 macOS Release 通过；应用版本为 1.0.3（Build 8）。
- iPhone 17 Pro 与 iPad Air 11-inch（M3）Simulator Release 均通过，二进制均为
  arm64 与 x86_64，第一方编译告警为 0。
- 无签名 iOS Device Release 通过，二进制为 arm64，版本为 1.0.3（Build 8）。
- Release 校验遍历应用包内全部 Mach-O；架构、动态库路径和 LC_RPATH 均通过。
- 第三方告警单独记录：SwiftTerm 87、ZIPFoundation 4、NIOSSH 0、Citadel 0。
  FreeRDP/WinPR 源码冷构建产生 956 条重复弃用诊断/空符号归档提示，不计入
  第一方零告警门禁。

## 未纳入本轮通过项

本轮没有执行实体串口、真实 Windows RDP、真实 SSH/VNC/WebDAV 互通或实际
VoiceOver 朗读，因此不把这些项目标记为通过。本轮不创建版本标签。
