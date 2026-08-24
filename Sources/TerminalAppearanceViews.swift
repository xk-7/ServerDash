import AppKit
import SwiftUI

struct TerminalAppearanceSettingsView: View {
    @ObservedObject private var store = TerminalAppearanceStore.shared
    @State private var previewDark = true

    private var profileBinding: Binding<TerminalAppearanceProfile> {
        Binding(
            get: { store.profile },
            set: { store.profile = $0.validated() }
        )
    }

    var body: some View {
        HSplitView {
            ScrollView {
                TerminalAppearanceEditor(
                    profile: profileBinding,
                    previewDark: $previewDark
                )
                .padding(AppleDesign.Spacing.lg)
            }
            .frame(minWidth: 430, idealWidth: 500)

            VStack(alignment: .leading, spacing: AppleDesign.Spacing.md) {
                HStack {
                    Text("终端预览")
                        .font(.title3.weight(.bold))
                    Spacer()
                    Picker("预览外观", selection: $previewDark) {
                        Text("浅色").tag(false)
                        Text("深色").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                }
                TerminalAppearancePreview(
                    profile: store.profile,
                    dark: previewDark
                )
                let theme = store.theme(dark: previewDark)
                if theme.contrastRatio < 4.5 {
                    Label(
                        "前景与背景对比度仅 \(theme.contrastRatio.formatted(.number.precision(.fractionLength(1)))):1，长时间阅读可能较困难。",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(Color.appWarning)
                }
                Spacer()
                HStack {
                    Text("全局设置只应用于之后新建的终端。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("恢复默认", role: .destructive) {
                        store.reset()
                    }
                }
            }
            .padding(AppleDesign.Spacing.lg)
            .frame(minWidth: 390, idealWidth: 460)
        }
    }
}

struct TerminalSessionAppearanceView: View {
    @Environment(\.dismiss) private var dismiss

    let isDark: Bool
    let onApply: (TerminalAppearanceProfile) -> Void
    let onApplyGlobal: () -> Void
    let onReset: () -> Void

    @State private var draft: TerminalAppearanceProfile
    @State private var previewDark: Bool

    init(
        profile: TerminalAppearanceProfile,
        isDark: Bool,
        onApply: @escaping (TerminalAppearanceProfile) -> Void,
        onApplyGlobal: @escaping () -> Void,
        onReset: @escaping () -> Void
    ) {
        self.isDark = isDark
        self.onApply = onApply
        self.onApplyGlobal = onApplyGlobal
        self.onReset = onReset
        _draft = State(initialValue: profile)
        _previewDark = State(initialValue: isDark)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: AppleDesign.Spacing.xxs) {
                    Text("终端外观")
                        .font(.title2.weight(.bold))
                    Text("调整只作用于当前会话，不会重新连接 SSH。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(AppleDesign.Spacing.lg)
            Divider()

            HSplitView {
                ScrollView {
                    TerminalAppearanceEditor(
                        profile: $draft,
                        previewDark: $previewDark
                    )
                    .padding(AppleDesign.Spacing.lg)
                }
                .frame(minWidth: 420)

                VStack(alignment: .leading, spacing: AppleDesign.Spacing.md) {
                    Picker("预览外观", selection: $previewDark) {
                        Text("浅色").tag(false)
                        Text("深色").tag(true)
                    }
                    .pickerStyle(.segmented)
                    TerminalAppearancePreview(profile: draft, dark: previewDark)
                    Spacer()
                }
                .padding(AppleDesign.Spacing.lg)
                .frame(minWidth: 360)
            }

            Divider()
            HStack {
                Button("恢复会话初始值") {
                    onReset()
                    dismiss()
                }
                Button("应用全局默认") {
                    onApplyGlobal()
                    dismiss()
                }
                Spacer()
                Button("应用到当前会话") {
                    onApply(draft.validated())
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(AppleDesign.Spacing.md)
        }
        .frame(width: 900, height: 700)
    }
}

private struct TerminalAppearanceEditor: View {
    @Binding var profile: TerminalAppearanceProfile
    @Binding var previewDark: Bool

    @State private var themeSearch = ""
    @State private var fontSearch = ""

    private var lightThemes: [TerminalColorTheme] {
        TerminalThemeCatalog.shared.filtered(themeSearch, dark: false)
    }

    private var darkThemes: [TerminalColorTheme] {
        TerminalThemeCatalog.shared.filtered(themeSearch, dark: true)
    }

    private var fonts: [TerminalFontOption] {
        let all = TerminalFontCatalog.availableFonts()
        let query = fontSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.displayName.localizedCaseInsensitiveContains(query) ||
            $0.postScriptName.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppleDesign.Spacing.lg) {
            settingsSection("主题", symbol: "paintpalette") {
                TextField("搜索主题", text: $themeSearch)
                    .textFieldStyle(.roundedBorder)
                themePicker(
                    title: "浅色主题",
                    selection: $profile.lightThemeID,
                    themes: lightThemes
                )
                themePicker(
                    title: "深色主题",
                    selection: $profile.darkThemeID,
                    themes: darkThemes
                )
            }

            settingsSection("字体与文本", symbol: "textformat") {
                TextField("搜索等宽字体", text: $fontSearch)
                    .textFieldStyle(.roundedBorder)
                Picker("字体", selection: $profile.fontPostScriptName) {
                    if fonts.isEmpty {
                        Text("没有匹配的等宽字体")
                            .tag(profile.fontPostScriptName)
                    } else {
                        ForEach(fonts) { option in
                            Text(
                                option.isTargetFont
                                    ? "\(option.displayName) · 推荐"
                                    : option.displayName
                            )
                            .tag(option.postScriptName)
                        }
                    }
                }
                valueSlider(
                    title: "字号",
                    value: $profile.fontSize,
                    range: 8...48,
                    step: 1,
                    formatted: "\(Int(profile.fontSize)) pt"
                )
                valueSlider(
                    title: "行高",
                    value: $profile.lineHeight,
                    range: 1...2,
                    step: 0.05,
                    formatted: profile.lineHeight.formatted(
                        .number.precision(.fractionLength(2))
                    )
                )
                valueSlider(
                    title: "字间距",
                    value: $profile.letterSpacing,
                    range: -1...3,
                    step: 0.1,
                    formatted: profile.letterSpacing.formatted(
                        .number.precision(.fractionLength(1))
                    )
                )
                Text("第三方字体请先通过“字体册”安装，重新打开设置后即可发现。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            settingsSection("光标", symbol: "cursorarrow") {
                Picker("活动光标", selection: $profile.activeCursorStyle) {
                    ForEach(TerminalCursorShape.allCases) {
                        Text($0.title).tag($0)
                    }
                }
                Picker("非活动光标", selection: $profile.inactiveCursorStyle) {
                    ForEach(TerminalInactiveCursorStyle.allCases) {
                        Text($0.title).tag($0)
                    }
                }
                Toggle("光标闪烁", isOn: $profile.cursorBlinkEnabled)
            }

            settingsSection("滚动条与声音", symbol: "speaker.wave.2") {
                Picker("滚动条", selection: $profile.scrollbarMode) {
                    ForEach(TerminalScrollbarMode.allCases) {
                        Text($0.title).tag($0)
                    }
                }
                Toggle("Terminal Bell", isOn: $profile.terminalBellEnabled)
            }
        }
    }

    private func themePicker(
        title: String,
        selection: Binding<String>,
        themes: [TerminalColorTheme]
    ) -> some View {
        Picker(title, selection: selection) {
            if themes.isEmpty {
                Text("没有匹配主题").tag(selection.wrappedValue)
            } else {
                ForEach(themes) { theme in
                    HStack {
                        Text(theme.name)
                        Text(theme.contrastRatio.formatted(
                            .number.precision(.fractionLength(1))
                        ))
                    }
                    .tag(theme.id)
                }
            }
        }
    }

    private func valueSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        formatted: String
    ) -> some View {
        HStack {
            Text(title)
                .frame(width: 54, alignment: .leading)
            Slider(value: value, in: range, step: step)
            Text(formatted)
                .font(.caption.monospacedDigit())
                .frame(width: 54, alignment: .trailing)
        }
    }

    private func settingsSection<Content: View>(
        _ title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: AppleDesign.Spacing.sm) {
            Label(title, systemImage: symbol)
                .font(.headline)
            content()
        }
        .applePanel(padding: AppleDesign.Spacing.md, radius: AppleDesign.Radius.card)
    }
}

private struct TerminalAppearancePreview: View {
    let profile: TerminalAppearanceProfile
    let dark: Bool

    private var theme: TerminalColorTheme {
        TerminalThemeCatalog.shared.theme(
            id: dark ? profile.darkThemeID : profile.lightThemeID,
            dark: dark
        )
    }

    private var previewFont: Font {
        Font(
            TerminalFontCatalog.font(
                name: profile.fontPostScriptName,
                size: profile.fontSize
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * profile.lineHeight) {
            previewLine {
                Text("demo@server")
                    .foregroundStyle(theme.ansiColors[2].color)
                Text(":~$ ")
                    .foregroundStyle(theme.foreground.color)
                Text("ls -la")
                    .foregroundStyle(theme.ansiColors[6].color)
            }
            Text("drwxr-xr-x  Documents   Downloads   项目")
            Text("0 O o   1 l I |   { } [ ] ( )")
            Text("=> != == && ||   中文 Emoji 🚀")
            HStack(spacing: AppleDesign.Spacing.md) {
                Text("SUCCESS").foregroundStyle(theme.ansiColors[2].color).bold()
                Text("WARNING").foregroundStyle(theme.ansiColors[3].color)
                Text("ERROR").foregroundStyle(theme.ansiColors[1].color)
            }
            Text("underline").underline()
            Text(" inverse ")
                .foregroundStyle(theme.background.color)
                .background(theme.foreground.color)
            HStack(spacing: 3) {
                ForEach(Array(theme.ansiColors.enumerated()), id: \.offset) { _, color in
                    Rectangle()
                        .fill(color.color)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 18)
        }
        .font(previewFont)
        .tracking(profile.letterSpacing)
        .foregroundStyle(theme.foreground.color)
        .padding(AppleDesign.Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: 330, alignment: .topLeading)
        .background(theme.background.color)
        .clipShape(
            RoundedRectangle(
                cornerRadius: AppleDesign.Radius.card,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: AppleDesign.Radius.card,
                style: .continuous
            )
            .stroke(theme.foreground.color.opacity(0.18))
        }
    }

    private func previewLine<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 0) {
            content()
        }
    }
}
