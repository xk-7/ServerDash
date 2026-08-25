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
- A single bounded monitoring coordinator with per-server deduplication, priority scheduling, capped retry backoff, low-power behavior, and configurable 1–60 second refresh intervals or manual mode.
- Independent per-server runtime state, incremental fleet summaries, explicit first-snapshot waiting UI, and preservation of the last successful data after a collection failure.

Primary targets are Ubuntu LTS and Debian Stable. AlmaLinux and Rocky Linux are capability-gated compatibility targets; Alpine and BusyBox-based environments are unsupported unless a later compatibility matrix says otherwise.

### SSH Connectivity and Security

- Uses macOS `/usr/bin/ssh` with unified timeout, cancellation, concurrency, and process lifecycle management.
- Supports passwords, SSH private keys, encrypted-key passphrases, and key-first password fallback.
- Private keys can reference external files or be imported into macOS Keychain.
- Passwords, private-key contents, and passphrases are never stored in SwiftData or placed on command lines.
- App-specific `known_hosts` with first-use fingerprint confirmation, changed-key comparison, and trusted-host management.
- Trusted hosts use a steady-state `known_hosts` fast path; `ssh-keyscan` is limited to first use, explicit revalidation, and recovery from a host-key error.
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

### Performance and Process Lifecycle

- stdout and stderr are consumed in bounded 32 KiB chunks; output-limit, timeout, cancellation, and natural exit remain distinct outcomes.
- Cancellation targets the owned process group, escalates from TERM to KILL, and can be scoped to one server without affecting another server's work.
- Monitoring capacity uses continuation-backed FIFO waiters instead of polling and refills immediately when a slot becomes available.
- The central scheduler prioritizes manual, selected, and visible-server work, rate-limits new starts, staggers retries, and suspends monitoring across sleep or network loss.
- Fixed-name, metadata-free OS Signposts cover launch, database, monitoring, host trust, subprocess, dashboard, terminal, and SFTP boundaries.

### Data and Diagnostics

- SwiftData persistence for servers, identities, SSH key references, snippets, trusted hosts, and terminal history.
- Versioned schemas with retry, backup, and rebuild options when the database cannot be opened.
- OSLog categories for App, Data, SSH, Monitoring, Terminal, and SFTP.
- Per-server event logs and previewable, copyable, redacted SSH diagnostics.
- IP hiding applies to the UI, Markdown exports, and diagnostics. The frozen 1.0 privacy contract makes remote location lookup opt-in; its current UI/default enforcement is tracked as pre-release work.
- Performance markers and touched diagnostic paths do not record hosts, users, paths, commands, fingerprints, or credentials.

See [CHANGELOG.md](CHANGELOG.md) for the complete update history.

## Requirements

- macOS 14 or later
- Xcode 26
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

The project uses the local `Vendor/SwiftTerm` package and does not download SwiftTerm separately.

## Development Status

P0 performance hardening is being delivered in independently verifiable batches. Measurement, subprocess lifecycle, trusted-host coordination, the central monitoring scheduler, and per-server RuntimeState have passed a Universal Release build and the complete 77-test suite. Instruments and real-server performance thresholds are intentionally tracked as pending rather than reported as complete.

See [Docs/P0_IMPLEMENTATION_STATUS.md](Docs/P0_IMPLEMENTATION_STATUS.md) for requirement-to-code mapping, batch results, acceptance coverage, and the remaining real-device checks.

The internal-test product and architecture constraints are recorded in the [architecture decision index](Docs/ArchitectureDecisions/README.md) and [1.0 scope/non-goals](Docs/PRODUCT_SCOPE_1.0.md).

Latest internal preview: [ServerDash 0.1.0 test.3](https://github.com/xk-7/ServerDash/releases/tag/v0.1.0-test.3) (build 2). Read the [release notes](Docs/RELEASE_NOTES_0.1.0-TEST.3.md) before installing; this build is ad-hoc signed, not notarized, and intended only for known testers.

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

Run only the application test bundle while iterating:

```bash
xcodebuild \
  -project ServerDash.xcodeproj \
  -scheme ServerDash \
  -destination 'platform=macOS' \
  -skipPackagePluginValidation \
  -only-testing:ServerDashTests \
  test
```

The checked-in Xcode project is generated from `project.yml`. Run `xcodegen generate` after changing the project definition; ordinary source-only changes do not require regeneration.

Create an ad-hoc signed test DMG (no Apple Developer account required):

```bash
./Scripts/build-test-dmg.sh
```

The DMG is written to `dist/`. On another Mac, open the app with Control-click → **Open**, or allow it under **System Settings → Privacy & Security** when Gatekeeper reports that the developer cannot be verified.

## Project Layout

```text
Sources/                    SwiftUI app, connection services, and data models
Tests/                      Unit and foundation integration tests
Docs/                       Design reviews and P0 implementation/verification status
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

ServerDash launches OpenSSH/SFTP subprocesses, so App Sandbox is currently disabled. The 1.0 internal-test line uses local ad-hoc signing and manual sharing with a small number of known testers; it does not require Apple Developer Program membership, Developer ID, notarization, or the Mac App Store. CloudKit, paid tiers, guaranteed 24×7 alerts, Mosh, port forwarding, and a full Docker operations panel are outside the current scope. See the [accepted distribution and SSH decision](Docs/ArchitectureDecisions/ADR-0001-internal-distribution-and-ssh-engine.md).
