# ServerDash

**English** | [简体中文](README.zh-CN.md)

ServerDash is a native macOS monitoring, SSH terminal, and SFTP client for Linux VPS hosts. It is built with SwiftUI, requires macOS 14 or later, and does not require a server-side agent.

## Features

### Linux Resource Monitoring

- Overall and per-core CPU usage, temperature, load averages, memory, swap, processes, and logged-in users.
- Live network interface rates, cumulative traffic, and hourly/daily/weekly/monthly/yearly vnStat history.
- Filesystem capacity, block device throughput, IOPS, and read/write latency.
- NVIDIA GPU utilization, VRAM, temperature, fan speed, power, and GPU processes.
- Docker version, container states, images, and runtime details.
- Reorderable and hideable monitoring cards with automatic capability-based visibility.
- Capability probing, SSH latency, last-success timestamps, data age, and stale-data indicators.
- Non-overlapping collection per server with configurable 1–60 second refresh intervals or manual mode.

Primary targets are Ubuntu LTS, Debian Stable, AlmaLinux, and Rocky Linux. Alpine and BusyBox-based environments have limited support.

### SSH Connectivity and Security

- Uses macOS `/usr/bin/ssh` with unified timeout, cancellation, concurrency, and process lifecycle management.
- Supports passwords, SSH private keys, encrypted-key passphrases, and key-first password fallback.
- Private keys can reference external files or be imported into macOS Keychain.
- Passwords, private-key contents, and passphrases are never stored in SwiftData or placed on command lines.
- App-specific `known_hosts` with first-use fingerprint confirmation, changed-key comparison, and trusted-host management.
- Server profiles can be saved offline, while SSH tests report results independently.

### Persistent Multi-Session Terminal

- Built on the repository-pinned SwiftTerm 1.11.2 package and OpenSSH PTY.
- Sessions are independent from the SwiftUI view lifecycle, so switching tabs, servers, or features does not disconnect SSH.
- Supports ANSI output, wide characters, and interactive programs such as `vim`, `top`, `htop`, and `tmux`.
- Includes 20 local light/dark themes and discovers installed macOS monospaced fonts.
- Configurable font size, line height, character spacing, active/inactive cursors, blinking, scrollbar, and Terminal Bell.
- Global appearance settings affect new sessions only; active sessions can be customized independently.
- `⌘T` opens a terminal, `⌘+` / `⌘-` adjust the current session font size, and `⌘0` resets it.

### SFTP

- Upload and download files and folders.
- Create files/folders, rename, move, and recursively delete items.
- Byte progress, speed, remaining time, cancellation, and retry support.
- Conflict handling for overwrite, skip, or automatic rename.
- Supports Chinese characters, spaces, special-character paths, and per-server default directories.

### Data and Diagnostics

- SwiftData persistence for servers, identities, SSH key references, snippets, trusted hosts, and terminal history.
- Versioned schemas with retry, backup, and rebuild options when the database cannot be opened.
- OSLog categories for App, Data, SSH, Monitoring, Terminal, and SFTP.
- Per-server event logs and previewable, copyable, redacted SSH diagnostics.
- IP hiding applies to the UI, Markdown exports, and diagnostics. Disabling location collection prevents remote requests to `ipinfo.io`.

See [CHANGELOG.md](CHANGELOG.md) for the complete update history.

## Requirements

- macOS 14 or later
- Xcode 26
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

The project uses the local `Vendor/SwiftTerm` package and does not download SwiftTerm separately.

## Build and Run

```bash
xcodegen generate
open ServerDash.xcodeproj
```

Select the `ServerDash` scheme in Xcode, or build from the command line:

```bash
xcodebuild \
  -project ServerDash.xcodeproj \
  -scheme ServerDash \
  -destination 'platform=macOS' \
  -skipPackagePluginValidation \
  build
```

Run the complete test suite:

```bash
xcodebuild \
  -project ServerDash.xcodeproj \
  -scheme ServerDash \
  -destination 'platform=macOS' \
  -skipPackagePluginValidation \
  test
```

## Project Layout

```text
Sources/                    SwiftUI app, connection services, and data models
Tests/                      Unit and foundation integration tests
Resources/TerminalThemes/   Local terminal themes and licensing notes
Vendor/SwiftTerm/           Pinned and extended SwiftTerm 1.11.2
project.yml                 XcodeGen project definition
```

## Technology

- UI: SwiftUI, Swift Charts, MapKit
- Data: SwiftData
- Credentials: Security / Keychain Services, LocalAuthentication
- SSH/SFTP: macOS system OpenSSH
- Terminal: local SwiftTerm 1.11.2 package
- Logging: OSLog

## Distribution and Scope

ServerDash launches OpenSSH/SFTP subprocesses, so App Sandbox is currently disabled. The current architecture targets direct Developer ID distribution and is not suitable for the Mac App Store without changes. Production signing/notarization, iCloud, alerts, Mosh, port forwarding, and a full Docker operations panel are outside the current scope.
