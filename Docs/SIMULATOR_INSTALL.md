# ServerDash iPhone / iPad Simulator 安装说明

此附件仅适用于安装了 Xcode 26 的 macOS，不能安装到实体 iPhone 或 iPad。

1. 在 Xcode 中启动一个 iOS 18 或更高版本的 iPhone / iPad Simulator。
2. 解压下载的 ZIP 文件。
3. 将 `ServerDashMobile.app` 拖入已启动的 Simulator，或在解压目录执行：

```bash
xcrun simctl install booted ServerDashMobile.app
xcrun simctl launch booted com.serverdash.app.ios
```

iPhone 与 iPad 使用同一个通用移动端 Target，但发布时分别构建和验证；iPad 包限定为左右横屏，并使用双栏导航。
