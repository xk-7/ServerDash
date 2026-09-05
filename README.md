# ServerDash

**English** | [简体中文](README.zh-CN.md)

ServerDash is a native macOS, iPhone, and iPad monitoring, SSH terminal, and SFTP client for Linux VPS hosts. It is built with SwiftUI, requires macOS 14 or iOS/iPadOS 18, and does not require a server-side agent.

## Features

### Linux Resource Monitoring

- Overall and per-core CPU usage, temperature, load averages, memory, swap, processes, and logged-in users.
- Live network interface rates, cumulative traffic, and hourly/daily/weekly/monthly/yearly vnStat history.
- Filesystem capacity, block device throughput, IOPS, and read/write latency.
- NVIDIA GPU utilization, VRAM, temperature, fan speed, power, and GPU processes.
- Docker version, container states, images, and runtime details.
- Reorderable and hideable monitoring cards with automatic capability-based visibility.
- Shared dashboard/machine search, group/tag/monitoring filters, and name/group/creation-date sorting on all three platforms. Space-separated terms match across names, addresses, usernames, tags, and notes without changing monitoring scope. Retry failed monitoring from the Mac toolbar (`⌘⇧R`).
- Capability probing, SSH latency, last-success timestamps, data age, and stale-data indicators.
- The Mac monitoring coordinator provides per-server deduplication, priority scheduling, capped retry backoff, low-power behavior, and configurable 1–60 second refresh intervals or manual mode.
- Independent per-server runtime state, incremental fleet summaries, explicit first-snapshot waiting UI, and preservation of the last successful data after a collection failure.
- Mobile distinguishes online, attention-needed, pending, and paused hosts, with pull-to-refresh, failed-host retry, direct server creation, network rates, and stale-data labels. iPad uses an adaptive grid; accessibility text sizes switch cards to a vertical layout.
- Mobile monitoring is owned by the root view and continues when switching pages in the foreground. At most three hosts collect concurrently, with per-host deduplication and slots held until SSH closes. Choose manual mode or a 5/15/30/60-second delay after each completed round; failed-host backoff caps at five minutes and manual refresh bypasses it.
- Pause individual hosts in the mobile editor. Deleting a host cancels its queued/running monitoring and closes its terminal; late results cannot restore deleted state. Cancelling a host-trust request dismisses that request and unblocks the next host.

### Local Monitoring History and Data Gaps

- Persists CPU, memory, load, swap, disk, and network-rate samples locally with server ID, collection time, collector/version, quality, and source-data age.
- Provides 24-hour, 7-day, 30-day, and custom history ranges with display-width-aware raw, 1-minute, and 15-minute resolution.
- Shows collection gaps as explicit shaded intervals and splits chart lines at every gap instead of connecting stale values across missing data.
- Distinguishes timeout, unreachable host, authentication failure, host-key change, Mac sleep, local network loss, collector stop, unsupported collector, and unknown failures.
- Aggregates `min`/`max`/`avg`/`last`/`sampleCount`, downsamples to the available pixel width, and automatically maintains retention and storage limits.
- Defaults to 24 hours of raw samples, 30 days of 1-minute aggregates, one year of 15-minute aggregates, and a 512 MiB monitoring-history quota.

Primary targets are Ubuntu LTS and Debian Stable. AlmaLinux and Rocky Linux are capability-gated compatibility targets; Alpine and BusyBox-based environments are unsupported unless a later compatibility matrix says otherwise.

### SSH Connectivity and Security

- Uses macOS `/usr/bin/ssh` on Mac and the repository-pinned Citadel 0.12.1 native SSH engine on iPhone/iPad.
- Both engines implement the shared `RemoteConnectionEngine` / `RemoteSession` contracts for commands, PTY shells, SFTP, cancellation, and closure while preserving the existing macOS process behavior.
- Imports SSH Config with final-value/source/unsupported reports and supports multi-hop ProxyJump routes with per-hop identity, trust, and timeout.
- Supports structured SOCKS5/HTTP CONNECT proxies plus Local, Remote, and Dynamic forwarding; loopback is the default and remote/wildcard listeners require confirmation.
- Supports passwords, SSH private keys, encrypted-key passphrases, and key-first password fallback.
- Private keys can reference external files or be imported into macOS Keychain.
- Passwords, private-key contents, and passphrases are never stored in SwiftData or placed on command lines.
- App-specific `known_hosts` with first-use fingerprint confirmation, changed-key comparison, and trusted-host management.
- Trusted hosts use a steady-state `known_hosts` fast path; `ssh-keyscan` is limited to first use, explicit revalidation, and recovery from a host-key error.
- Server profiles can be saved offline, while SSH tests report results independently.
- iPhone/iPad fail closed on every unknown or changed host key and never expose an “accept all hosts” mode.
- Mobile authentication is limited to passwords and imported OpenSSH Ed25519/RSA private keys. Secrets use this-device-only Keychain accessibility; external key paths, SSH Agent, SSH Config, proxies, jump hosts, and forwarding are hidden.
- The local NIOSSH 0.3.6 source includes Apple's `31cdc3c` fix and regression tests for [GHSA-998x-vgvp-xwpc](https://github.com/apple/swift-nio-ssh/security/advisories/GHSA-998x-vgvp-xwpc); mobile SSH is not release-ready if that security gate fails.

### Persistent Multi-Session Terminal

- Built on the repository-pinned SwiftTerm 1.11.2 package, with OpenSSH PTY on macOS and Citadel PTY on iPhone and iPad.
- Sessions are independent from the SwiftUI view lifecycle, so switching tabs, servers, or features does not disconnect SSH.
- Supports ANSI output, wide characters, and interactive programs such as `vim`, `top`, `htop`, and `tmux`.
- Includes 20 local light/dark themes and discovers installed macOS monospaced fonts.
- Configurable font size, line height, character spacing, active/inactive cursors, blinking, scrollbar, and Terminal Bell.
- Global appearance settings affect new sessions only; active sessions can be customized independently.
- `⌘T` opens a terminal; `⌘+` / `⌘=` and `⌘-` adjust the current session font size; `⌘0` restores its initial size.
- `⌘F` searches terminal output, `⌃Tab` / `⌃⇧Tab` switch tabs, and `⌘⇧,` opens terminal appearance settings. These shortcuts are listed in the Terminal menu.
- `⌘⌥I` toggles a Status / Snippets inspector with resource snapshots, stale-data notices, and searchable commands. Execution and multiline insertion require confirmation and stay bound to the original session.
- iPhone uses the SwiftTerm UIKit terminal full-screen with snippets/status in sheets; iPad can keep the terminal and inspector side by side and supports pointer and hardware-keyboard input.

### SFTP

- Upload and download files and folders.
- Create files/folders, rename, move, and recursively delete items.
- Byte progress, speed, remaining time, cancellation, and retry support.
- Conflict handling for overwrite, skip, or automatic rename.
- Supports Chinese characters, spaces, special-character paths, and per-server default directories.
- iPhone uses a compact list and iPad an adaptive grid. System file import/export provides local-file access without persisting external security-scoped paths.

## Platform Matrix

| Capability | macOS 14+ | iPhone / iPadOS 18+ |
| --- | --- | --- |
| Dashboard and Linux monitoring | Yes | Yes; foreground refresh |
| Multiple remote terminals | Yes | Yes; interrupted in background |
| SFTP browse/upload/download/rename/move/delete | Yes | Yes; Files import/export |
| Password and imported private-key authentication | Yes | Yes |
| External private-key path / SSH Agent / SSH Config | Yes | No |
| Jump hosts and SOCKS5 / HTTP CONNECT proxies | Yes | No |
| Local, remote, and dynamic forwarding | Yes | No |
| Local terminal | Yes | No |
| CloudKit or cross-device data sync | No | No |

### Performance and Process Lifecycle

- Server browsers compute filtering/sorting once per view update and read sort keys before comparing, avoiding per-row re-sorts and repeated SwiftData reads. Mobile monitoring responses are parsed off the main actor.
- stdout and stderr are consumed in bounded 32 KiB chunks; output-limit, timeout, cancellation, and natural exit remain distinct outcomes.
- Cancellation targets the owned process group, escalates from TERM to KILL, and can be scoped to one server without affecting another server's work.
- Monitoring capacity uses continuation-backed FIFO waiters instead of polling and refills immediately when a slot becomes available.
- The central scheduler prioritizes manual, selected, and visible-server work, rate-limits new starts, staggers retries, and suspends monitoring across sleep or network loss.
- Fixed-name, metadata-free OS Signposts cover launch, database, monitoring, host trust, subprocess, dashboard, terminal, and SFTP boundaries.

### Data and Diagnostics

- SwiftData persistence for servers, identities, SSH key references, connection routes, forwarding rules, snippets, trusted hosts, terminal history, monitoring samples, aggregates, and Data Gaps.
- Versioned V1/V2/V3 schemas with V1-to-V2 and V2-to-V3 migration stages, plus retry, backup, and rebuild options when the database cannot be opened.
- OSLog categories for App, Data, SSH, Monitoring, Terminal, and SFTP.
- Per-server event logs and previewable, copyable, redacted SSH diagnostics.
- IP hiding applies to the UI, Markdown exports, and diagnostics. The frozen 1.0 privacy contract makes remote location lookup opt-in; its current UI/default enforcement is tracked as pre-release work.
- Performance markers and touched diagnostic paths do not record hosts, users, paths, commands, fingerprints, or credentials.

See [CHANGELOG.md](CHANGELOG.md) for the complete update history.

## Product Experience Reference

The [SwiftServer product page](https://swiftserver.app/) and [official documentation](https://swiftserver.app/docs) are the primary experience references for server organization, monitoring cards, adaptive multi-device navigation, the terminal inspector, SFTP, and connection diagnostics. ServerDash retains its own identity, implementation, copy, assets, and security constraints. This does not claim feature parity or implicitly add paid limits or iCloud.

## Requirements

- macOS 14 or later
- iOS or iPadOS 18 or later for `ServerDashMobile`
- Xcode 26
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

The project uses local `Vendor/SwiftTerm`, `Vendor/Citadel`, and `Vendor/swift-nio-ssh` packages. SwiftPM still resolves their pinned transitive dependencies from `Package.resolved`.

## Development Status

The universal `ServerDashMobile` target builds for iPhone and iPad Simulator. Its focused suite currently contains 23 tests covering connection contracts, local Citadel password/key/PTY integration, host trust and cancellation, monitoring concurrency/backoff, background recovery/deletion cleanup, metadata search, fleet summaries, card rendering, platform capability gating, and secret redaction. The vendored NIOSSH suite adds two malformed-ECDSA-signature regression tests. Physical-device SSH/SFTP and accessibility checks remain explicitly unexecuted; see the [mobile device checklist](Docs/MOBILE_DEVICE_TEST_CHECKLIST.md).

The existing macOS S11 professional SSH routes and tunnels remain available and continue to use system OpenSSH. Production multi-hop, authenticated proxies, Remote Forward, hardware keys, and long-running stability still require isolated or real-device validation.

See [Docs/S11_IMPLEMENTATION_STATUS.md](Docs/S11_IMPLEMENTATION_STATUS.md) for requirement-to-code mapping, batch results, acceptance coverage, and the remaining isolated/real-device checks.

The internal-test product and architecture constraints are recorded in the [architecture decision index](Docs/ArchitectureDecisions/README.md) and [1.0 scope/non-goals](Docs/PRODUCT_SCOPE_1.0.md).

Latest stable release: [ServerDash 1.0.0](https://github.com/xk-7/ServerDash/releases/tag/v1.0.0) (build 5). See the [release announcement](Docs/RELEASE_NOTES_1.0.0.md) for installation and artifact details. The macOS artifact is ad-hoc signed and not notarized; iPhone and iPad artifacts are Xcode Simulator builds, while physical-device distribution still requires Apple signing and TestFlight/App Store delivery.

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

Build the universal iPhone/iPad app for Simulator:

```bash
xcodebuild \
  -project ServerDash.xcodeproj \
  -scheme ServerDashMobile \
  -destination 'generic/platform=iOS Simulator' \
  build
```

To install on an iPhone or iPad, open the project, select `ServerDashMobile`, choose your development team, connect a device running iOS/iPadOS 18 or later, and Run. A free Apple ID can be used for local development signing subject to Apple's normal provisioning limits. No TestFlight or App Store package is provided.

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

Build the macOS, iPhone Simulator, and iPad Simulator GitHub Release artifacts, plus an unsigned iOS Device Release compile check:

```bash
./Scripts/build-release-artifacts.sh 1.0.0
```

Artifacts and SHA-256 checksums are written to `dist/v1.0.0/`. See the [Simulator installation guide](Docs/SIMULATOR_INSTALL.md) for the mobile ZIP files.

## Project Layout

```text
Sources/                    SwiftUI app, connection services, and data models
Mobile/Sources/             Native iPhone/iPad app, adaptive UI, and Citadel adapter
Mobile/Tests/               Mobile contracts, security, trust, and lifecycle tests
Tests/                      Unit and foundation integration tests
Docs/                       Architecture decisions, implementation status, and release notes
Resources/TerminalThemes/   Local terminal themes and licensing notes
Vendor/SwiftTerm/           Pinned and extended SwiftTerm 1.11.2
Vendor/Citadel/             Locally pinned Citadel 0.12.1
Vendor/swift-nio-ssh/       Locally pinned NIOSSH 0.3.6 plus security backport
project.yml                 XcodeGen project definition
```

## Technology

- UI: SwiftUI, Swift Charts, MapKit
- Data: SwiftData
- Credentials: Security / Keychain Services, LocalAuthentication
- SSH/SFTP: macOS system OpenSSH; Citadel 0.12.1 + NIOSSH 0.3.6 on iOS/iPadOS
- Terminal: local SwiftTerm 1.11.2 package
- Logging: OSLog

## Distribution and Scope

The macOS app launches OpenSSH/SFTP subprocesses, so App Sandbox remains disabled. The iOS/iPadOS app uses its own sandbox container and an independent SwiftData V3 database; it does not migrate or synchronize Mac data. Mobile connections are foreground-scoped: monitoring reconnects after foregrounding, while terminals and interrupted transfers require explicit user restart and do not promise process recovery or transfer resume. CloudKit, TestFlight, StoreKit, widgets, Live Activities, paid tiers, guaranteed 24×7 alerts, and Mosh remain outside the current scope. See [ADR-0005](Docs/ArchitectureDecisions/ADR-0005-native-ios-and-dual-ssh-engine.md).
