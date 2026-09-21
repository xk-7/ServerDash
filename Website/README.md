# ServerDash Website

ServerDash 官网是一个无构建依赖的中英双语静态站点。

## 本地预览

请通过本地 HTTP 服务器预览，不要直接打开 `file://` 地址：

```bash
cd Website
python3 -m http.server 4173
```

然后访问 <http://localhost:4173>。

## 文件

- `index.html`：语义化页面结构与双语内容
- `styles.css`：设计令牌、响应式布局和视觉样式
- `site.js`：语言/主题偏好、可访问性标签、公共导航和 GitHub Release 下载链接
- `release-notes.js`：正式 Releases 历史读取、缓存、安全 Markdown 渲染和版本筛选
- `assets/serverdash-mark.svg`：官网标记与 favicon
- `releases.html`：独立的 GitHub 正式版本更新日志
- `docs/index.html`：文档中心入口与模块导航
- `docs/*.html`：八个中英双语功能模块页
- `docs/releases.html`：旧更新日志地址的兼容跳转
- `docs/docs.css`：文档侧栏、正文、提示框、矩阵和移动目录

## 文档信息架构

文档以 ServerDash 1.0.4（Build 9）为稳定基线，分为：

1. 安装与快速开始
2. 机器与连接
3. 资源监控
4. 终端工作区
5. 文件与 SFTP
6. macOS 高级功能
7. 安全与隐私
8. 平台与已知限制

每个页面都同时包含中文和英文内容，沿用 `.lang-zh` / `.lang-en` 与 `site.js` 的语言偏好。新增页面时，需要在 `<html>` 上提供 `data-title-zh`、`data-title-en`、`data-description-zh` 和 `data-description-en`，并同步更新桌面侧栏、移动目录及前后页导航。

全站顶部主导航固定为“首页、文档、更新日志、下载”。更新日志属于站点一级页面，不进入文档侧栏；`site.js` 会根据当前目录生成正确的 Project Pages 相对路径和当前页状态。

主题默认跟随系统 `prefers-color-scheme`。各页 `<head>` 内有一段同步启动脚本，在样式表生效前写入 `data-theme` 和 `lang`，避免暗色或英文偏好先闪浅色中文。用户点击顶栏的日/月图标后，选择会以 `serverdash-theme` 保存到浏览器本地，并在首页、文档和更新日志之间保持；主题切换同时更新 `color-scheme` 和浏览器 `theme-color`。首页能力区以 2×2 展示监控、SSH、SFTP 和开发中的 RDP，RDP 不得写成稳定功能。

文档页面位于 `docs/`，资源和首页链接必须使用相对路径，例如 `../styles.css`、`../assets/serverdash-mark.svg` 和 `../#download`。不要使用 `/docs/` 形式的站点根路径，因为 GitHub Project Pages 部署在 `/ServerDash/` 前缀下。

功能事实的引用优先级：

1. 最新稳定发布说明与版本元数据
2. 当前功能说明
3. QA 中已执行/未执行的验收边界
4. 当前源码与平台门控
5. ADR 和产品范围文档

`CHANGELOG.md` 的未发布内容不能写入稳定功能。开发中的 RDP、真实服务/硬件尚未验收的能力，以及移动端分发限制，必须在相关功能旁直接说明。

## 更新版本

页面会在浏览器中读取 GitHub 的 latest release，并按文件名后缀匹配 macOS DMG、iPhone/iPad Simulator ZIP 和 SHA-256 文件。请求失败时回退到 `site.js` 中的 `FALLBACK_VERSION` 及 `index.html` 内对应的已验证直链。

Release API 只在包含 `#release-status` 的首页执行；文档页只复用语言和页面元数据逻辑，不发送 Release 查询。

更新日志页单独读取：

```text
https://api.github.com/repos/xk-7/ServerDash/releases?per_page=100
```

页面只显示 `draft === false` 且 `prerelease === false` 的正式版本，并按 `published_at` 倒序排列。最近一次成功结果在浏览器本地缓存一小时，用于减少匿名 API 限流；请求失败或返回空列表时保留 `releases.html` 内置的 1.0.0–1.0.4 双语摘要。Release 正文使用 DOM 文本节点安全渲染，不直接写入 `innerHTML`。

正常发布新的正式 GitHub Release 后无需修改更新日志页。只有回退基线、分发限制或数据结构变化时，才需要同步更新内置摘要和脚本。

发布新版本时应同时更新：

1. `site.js` 中的 `FALLBACK_VERSION`；
2. `index.html` 中的回退版本号与所有 Release 直链；
3. 下载区的签名、公证和分发限制说明（如状态有变化）。

移动 ZIP 仅适用于 Xcode Simulator，不得描述为实体 iPhone 或 iPad 安装包。

## 部署

`.github/workflows/website.yml` 在 `main` 分支的 `Website/` 内容变化后发布 GitHub Pages，也可手动触发。仓库首次部署前，需要在 GitHub 的 **Settings → Pages → Build and deployment** 中将 Source 设为 **GitHub Actions**。
