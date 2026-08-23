# ServerDash Apple Native Review

Adapted from [naplesblue/apple-design-skill](https://github.com/naplesblue/apple-design-skill), MIT License.

## Surface

- Use the cool system window background and solid content surfaces.
- Group same-kind rows in one panel or native `List`/`Table` with hairline separators.
- Reserve separate cards for independently selectable VPS objects.
- Use material only on overlapping sidebar, toolbar, sheet, or popover chrome.

## Type and color

- Use SF system text styles and PingFang fallback; avoid hard-coded feature-view font sizes.
- Use weight and grayscale for hierarchy.
- Use the system accent only for selection and primary actions.
- Use green, orange, and red only for real live, warning, and error states.
- Use `monospacedDigit()` for changing metrics and `monospaced()` only for hosts, commands, and terminal data.

## Shape and motion

- Use only the named 6/12/18/22/26 radius tiers.
- Shadows must be subtle and layered; lists and tables should not cast individual shadows.
- Press and selection feedback must be immediate and interruptible.
- Avoid entrance fades on refreshed metrics.
- Respect Reduce Motion, Reduce Transparency, and Increase Contrast.

## macOS behavior

- Prefer native sidebar selection, unified toolbar, `Table`, `Form`, context menus, keyboard shortcuts, and help labels.
- Keep destructive confirmation only where undo is unavailable.
- Provide empty, loading, validation, and failure states without layout jumps.
- Check light and dark mode, narrow and wide windows, long Chinese/Latin labels, keyboard focus, and VoiceOver.

## Completion gate

- No raw theme colors or one-off radius values outside `DesignSystem.swift`.
- No obsolete duplicate views.
- All CRUD screens persist, reload, and protect Keychain data correctly.
- `xcodebuild test` passes.
- Core views are visually checked in both appearances.
