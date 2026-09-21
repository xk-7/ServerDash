# ServerDash branch policy / 分支政策

## English

`main` is the Apple product mainline. It contains the native macOS app, the
native iPhone/iPad app, and the documentation, website, CI, tests, vendored
dependencies, and build tooling that directly support those products.

The independent Windows client lives on long-lived `windows/*` branches. Apple
mainline changes may be merged or cherry-picked into a Windows branch. A
Windows client branch, its product tree, and its commit history must never be
merged back into `main`. A generally useful fix discovered on Windows must be
recreated or selectively applied from a new branch based on `main` and pass the
Apple checks.

This boundary does not prohibit Apple-client support for remote Windows hosts.
The macOS RDP implementation, FreeRDP/WinPR bridge, Windows certificate
fixtures, remote OS detection, and their documentation remain Apple-mainline
code.

Pull requests into `main` must pass the required check
`Apple main scope / Validate Apple-only tree`. The check rejects independent
Windows-client source, build projects, release workflows, and Windows branches
as pull-request sources. The `main` ruleset must require pull requests and this
check, disallow force pushes and deletion, and provide no administrator bypass.

## 中文

`main` 是 Apple 产品主线，只承载原生 macOS 应用、原生 iPhone/iPad 应用，
以及直接支撑这些产品的文档、网站、CI、测试、固定依赖和构建工具。

独立 Windows 客户端长期保留在 `windows/*` 分支。允许将 Apple 主线改动合并
或挑选到 Windows 分支；禁止将 Windows 客户端分支、产品目录或其提交历史反向
合入 `main`。如果 Windows 开发中发现通用修复，应从 `main` 新建 Apple 分支
重新实现或选择性应用，并重新通过 Apple 检查。

该边界不限制 Apple 客户端连接远端 Windows 主机。macOS RDP、FreeRDP/WinPR
桥接、Windows 证书夹具、远端系统识别及其说明仍属于 Apple 主线。

所有目标为 `main` 的拉取请求必须通过
`Apple main scope / Validate Apple-only tree`。该检查拒绝独立 Windows 客户端
源码、工程、发布工作流，以及来自 Windows 分支的拉取请求。`main` 的仓库规则
应要求通过拉取请求和该检查，禁止强制推送、删除及管理员绕过。
