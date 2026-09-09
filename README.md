# ServerDash

**English** | [简体中文](README.zh-CN.md)

ServerDash is a native macOS, iPhone, and iPad monitoring, SSH terminal, and SFTP client for Linux VPS hosts. It is built with SwiftUI, requires macOS 14 or iOS/iPadOS 18, and does not require a server-side agent.

## Features

### RDP remote desktop (macOS, in development)

- RDP machines live alongside SSH machines, with protocol filtering and dedicated desktop session tabs.
- Embedded FreeRDP/WinPR 3.31.0 and OpenSSL 3.5.8; NLA/CredSSP and TLS 1.2+ only, certificate fingerprint confirmation and optional local Keychain password storage.
- Resolution/color requests, fullscreen/multi-display configuration, keyboard modes, opt-in clipboard/directory redirection and audio configuration are implemented for controlled testing.
- **Windows login, audio, file exchange, real multi-display operation and performance remain unverified.** This is not a completed RDP release. See [usage and current limits](Docs/RDP.md) and [acceptance record](Docs/RDP_QA.md).
- iPhone/iPad do not gain RDP in this iteration. RDP does not enter SSH monitoring, identity, recording, AI or export flows.

### AI assistant (macOS)

- Open **Sessions → ✨ → AI** for a right-side Ops assistant, alongside the existing status and snippet inspector. **AI → Open general conversation** opens an independent window without terminal context.
- **Settings → AI Assistant** supports OpenAI, Anthropic/Claude, Gemini, DeepSeek, Qwen, Volcengine/Ark, Ollama and custom OpenAI-compatible APIs. Each provider keeps its own endpoint, Keychain credential, model and parameters; built-in account-based access is not included.
- Search/refresh the model list or enter a model/endpoint ID manually. Configure Temperature where supported, positive Max Tokens (4096 for new profiles), and 1–50 historical messages (default 20, excluding the current question). Model availability depends on your service/account.
- Switch provider in the AI panel to create a separate conversation without forwarding old history. Changing a provider URL clears its credential association and requires a new conversation; the inspector still defaults to **Status**. Native Claude/Gemini/Ollama streaming is supported alongside Chat Completions.
- Terminal context requires permission per SSH connection and is captured only when sending. Right-click a terminal selection to prepare **Send to AI** or **AI Explain**, then review and send. Attachments are bounded and are not saved with chats; visible output and AI replies can still contain secrets.
- Keep up to 50 local conversations, search their names, copy/delete messages and clear conversations. The configurable request history defaults to the latest 20 messages. No automatic deletion, cloud sync or background terminal upload.
- Single-line shell suggestions can fill the command bar or execute after explicit target/command confirmation. Finished replies are bound to their original pane and connection; scripts can be copied, but are not automatically executed. API keys use a dedicated device-only Keychain item.
- macOS only; iPhone/iPad and offline command completion are unchanged. See [setup, privacy and limitations](Docs/AI_ASSISTANT.md) and [verification status](Docs/AI_ASSISTANT_QA.md).

### Session recording (macOS)

- Record each connected SSH pane independently from the existing terminal toolbar; tab/page changes keep recording. Stop saves automatically to `~/Documents/ServerDash/recordings`, configurable in Settings → Recording.
- Replay local `.sdrec` recordings with pause, 0.25×–8× speed, idle skipping and timeline seeking. Export up to five-minute GIF clips with 1–30 FPS, quality scaling and optional text watermark.
- Captures the initial visible screen and subsequent output, not raw keystrokes or hidden password input. Screen/output can still contain secrets; review before sharing. No automatic upload, reliable redaction or tamper-proof audit guarantee.
- Recording is macOS-only; iPhone/iPad are unchanged. See [usage, format and safety](Docs/SESSION_RECORDING.md) and [verification status](Docs/SESSION_RECORDING_QA.md).

### Multi-tab terminal workspace

- Shared macOS/iPhone/iPad SSH tabs with no fixed tab-count limit; memory and server limits still apply. The **+** menu also opens SFTP and monitoring tabs. macOS adds embedded RDP, local Shell and serial tabs, and launches VNC with system Screen Sharing.
- Drag to reorder, use tab context menus to close current/other/all tabs, and scroll fixed-width tabs with previous/next controls.
- **Ctrl+Tab / Ctrl+Shift+Tab** switch tabs. **Ctrl+Shift+D** splits right, **Ctrl+Shift+E** splits below, and **Ctrl+Shift+W** closes the active pane. Mobile shortcuts require a hardware keyboard.
- Each SSH pane owns its connection and scrollback. Choose another server from **+ → server → split**; maximum 16 panes per tab. Drag dividers, arrange as a grid up to 4×4, or maximize one pane without disconnecting the others.
- **Ctrl+F** (also **Cmd+F** on Mac) searches retained scrollback and highlights visible same-row matches. Fifteen presets, custom regex rules and twelve colors decorate text without modifying output.
- Command suggestions use local history, Linux commands and saved snippets. The command bar asks for confirmation before submitting; selecting history only fills text.
- Direct-terminal automatic history and suggestions require OSC 133 shell integration. Choose **… → Enable automatic command history**, select Bash 4.4+ or Zsh and confirm sending at a shell prompt. Only the current shell is modified, not remote startup files; unsupported shells use the command bar.
- Local history retains up to 2,000 commands with disable/clear controls. Raw keystrokes and password responses are not recorded. Leading spaces, control characters, assignments and recognized sensitive keywords suppress recording. The filter cannot identify every secret: disable history for other confidential arguments. History is not synced or exported.
- **Sessions → Choose server** opens the terminal workspace directly. Selecting a host reuses its most recently selected SSH pane, including disconnected panes; only **New tab** or **Split** allocates an independent connection. Canceling the picker leaves the workspace unchanged. Ordinary machine rows still open monitoring details.
- Layouts are in-memory. Foreground navigation retains SSH, SFTP and transfers through workspace-owned controllers. Mac SFTP transfers continue after closing a file tab; RDP asks before interrupting its active transfers. Mobile downloads remain available for explicit export even when completed off-screen.
- Mobile backgrounding interrupts connections. Reconnect explicitly starts a new shell with current configuration and trust checks; it does not restore remote processes or resume partially transferred files. See [navigation verification status](Docs/SESSION_NAVIGATION_QA.md) for the final test gate.

The Mac workbench includes hierarchical host groups and tag management, native grid/Table views, multi-selection, privacy mode, and a resizable inspector for CPU, GPU, memory, disk, network, files, AI and snippets. Batch commands preview a fixed list of connected SSH panes before submission. Settings use nine native categories. See [connection behavior](Docs/WORKBENCH_CONNECTIONS.md), [file editing and directory sync](Docs/WORKBENCH_FILES.md), and [workspace design](Docs/TERMINAL_WORKSPACE.md).

### Encrypted configuration sync (macOS)

- Opt-in WebDAV sync previews baseline changes, deletions and conflicts before applying them. Strong ETag conditions protect concurrent writes; failed conditions require a fresh preview.
- Versioned AES-GCM packages contain host, group, tag, snippet and connection configuration. Recovery keys live in Keychain with explicit export/import.
- Passwords, private keys, trust, history, recordings, monitoring, local folder authorization and serial device bindings remain local. Imported connection commands remain disabled until explicitly enabled on this Mac.

Mixed-protocol host configuration files can also be exported/imported locally with a separate identity namespace and conflict preview. Local files are plaintext configuration, contain addresses, and never delete hosts omitted from the file. See [sync behavior](Docs/WORKBENCH_SYNC.md) and [workbench verification](Docs/WORKBENCH_UI_QA.md).

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

### Session Import and Export

- The Machines screen on macOS, iPhone, and iPad imports XShell, SecureCRT, MobaXterm, FinalShell, XTerminal, PuTTY, ServerDash JSON, and OpenSSH Config sessions.
- On macOS, choose a file, directory, or ZIP, or explicitly inspect known SecureCRT, FinalShell, PuTTY, and OpenSSH locations. iPhone and iPad use the system Files picker.
- Import flow:
  1. Click **Import** in Machines.
  2. Choose the previous terminal client or automatic detection.
  3. Select its configuration/export file, directory, or ZIP.
  4. Review the hosts and click **Confirm**.
- Exact host/port/username duplicates are skipped by default and never overwrite an existing profile; individual rows can be imported as copies.
- Plaintext-password import is off by default and, when explicitly enabled, writes only to this device's Keychain. Proprietary encrypted client passwords are never decrypted.
- Export targets are ServerDash JSON, OpenSSH Config, XShell, MobaXterm, XTerminal, and PuTTY. Native SecureCRT and FinalShell export remains marked as awaiting real-client validation.
- Every export excludes passwords, private-key bodies, passphrases, trusted hosts, terminal/monitoring history, proxies, jump hosts, and forwarding rules.

| Client / format | Import | Export | Current validation boundary |
| --- | --- | --- | --- |
| XShell 8 | `.xsh`, directory, ZIP | Password-free `.xsh` ZIP | Sanitized fixture and ServerDash round trip; real XShell import pending |
| SecureCRT 9.6+ | XML, CSV/text wizard, `Config/Sessions/*.ini` | Disabled | Sanitized fixture covered; native export remains gated |
| MobaXterm | `MobaXterm.ini`, `.mxtsessions` | `.mxtsessions` | Sanitized fixture and ServerDash round trip; real MobaXterm import pending |
| FinalShell 3.9–4.6 | `conn/*.json`, directory, ZIP | Disabled | Sanitized fixture covered; native export remains gated |
| XTerminal | Official JSON and text formats | JSON | Official syntax fixtures and ServerDash round trip; real XTerminal import pending |
| PuTTY 0.84 | UTF-16LE `.reg`, Unix session directory | UTF-16LE `.reg` | Sanitized fixture and ServerDash round trip; real PuTTY import pending |
| ServerDash | `com.serverdash.sessions` JSON v1 | JSON v1 | Automated round trip |
| OpenSSH | Concrete `Host` blocks | SSH config | Automated round trip; `Include`, `Match`, proxy, script, and forwarding behavior is reported but not reproduced |

Export flow:

1. Click **Export** in Machines.
2. Choose all hosts, one group, or individual hosts.
3. Choose the target client; gated formats cannot be selected.
4. Save the generated file, import it in the target client, and configure credentials there.

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
| RDP remote desktop | Development implementation; Windows validation pending | No |
| SFTP browse/upload/download/rename/move/delete | Yes | Yes; Files import/export |
| Password and imported private-key authentication | Yes | Yes |
| Multi-client session import/export | Files, directories, ZIP, and explicit local discovery | Files import/export |
| External private-key path / SSH Agent / SSH Config | Yes | No |
| Jump hosts and SOCKS5 / HTTP CONNECT proxies | Yes | No |
| Local, remote, and dynamic forwarding | Yes | No |
| Local terminal | Yes | No |
| Encrypted WebDAV configuration sync | Yes; opt-in | No |

### Performance and Process Lifecycle

- Server browsers compute filtering/sorting once per view update and read sort keys before comparing, avoiding per-row re-sorts and repeated SwiftData reads. Mobile monitoring responses are parsed off the main actor.
- stdout and stderr are consumed in bounded 32 KiB chunks; output-limit, timeout, cancellation, and natural exit remain distinct outcomes.
- Cancellation targets the owned process group, escalates from TERM to KILL, and can be scoped to one server without affecting another server's work.
- Monitoring capacity uses continuation-backed FIFO waiters instead of polling and refills immediately when a slot becomes available.
- The central scheduler prioritizes manual, selected, and visible-server work, rate-limits new starts, staggers retries, and suspends monitoring across sleep or network loss.
- Fixed-name, metadata-free OS Signposts cover launch, database, monitoring, host trust, subprocess, dashboard, terminal, and SFTP boundaries.

### Data and Diagnostics

- SwiftData persistence for servers, identities, SSH key references, connection routes, forwarding rules, snippets, trusted hosts, terminal history, monitoring samples, aggregates, and Data Gaps.
- Versioned V1–V5 schemas. V5 adds organization, VNC, serial, SSH advanced settings, directory sync tasks and remote configuration mappings without changing existing connection UUIDs or credential references. Existing databases are backed up before upgrade. Migration failures do not automatically clear or rebuild the database.
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

The project uses local `Vendor/SwiftTerm`, `Vendor/Citadel`, `Vendor/swift-nio-ssh`, and `Vendor/ZIPFoundation` packages. SwiftPM still resolves their pinned transitive dependencies from `Package.resolved`.

## Development Status

The universal `ServerDashMobile` target builds for iPhone and iPad Simulator. Its focused suite currently contains 65 tests, including 41 shared session-migration cases for format mapping, malformed-input handling, duplicate detection, skipped-session reporting, ZIP traversal/symlink hardening, secret omission, Keychain authorization, cancellation, and rollback; the remaining tests cover connection contracts, local Citadel password/key/PTY integration, actionable authentication-error mapping, host trust and cancellation, monitoring concurrency/backoff, background recovery/deletion cleanup, metadata search, fleet summaries, card rendering, platform capability gating, and secret redaction. The vendored NIOSSH suite adds two malformed-ECDSA-signature regression tests. Physical-device SSH/SFTP and accessibility checks remain explicitly unexecuted; see the [mobile device checklist](Docs/MOBILE_DEVICE_TEST_CHECKLIST.md).

The existing macOS S11 professional SSH routes and tunnels remain available and continue to use system OpenSSH. Production multi-hop, authenticated proxies, Remote Forward, hardware keys, and long-running stability still require isolated or real-device validation.

See [Docs/S11_IMPLEMENTATION_STATUS.md](Docs/S11_IMPLEMENTATION_STATUS.md) for requirement-to-code mapping, batch results, acceptance coverage, and the remaining isolated/real-device checks.

The internal-test product and architecture constraints are recorded in the [architecture decision index](Docs/ArchitectureDecisions/README.md) and [1.0 scope/non-goals](Docs/PRODUCT_SCOPE_1.0.md).

Latest stable release: [ServerDash 1.0.0](https://github.com/xk-7/ServerDash/releases/tag/v1.0.0) (build 5). See the [release announcement](Docs/RELEASE_NOTES_1.0.0.md) for installation and artifact details. The macOS artifact is ad-hoc signed and not notarized; iPhone and iPad artifacts are Xcode Simulator builds, while physical-device distribution still requires Apple signing and TestFlight/App Store delivery.

## Build and Run

Before the first macOS build, build the pinned native dependency locally:

```bash
bash Scripts/build-rdp-dependencies.sh
```

This requires network access for hash-verified official archives and builds both Mac architectures.
The iOS targets do not link these libraries. [Dependency provenance and licenses](Vendor/RDP/README.md).

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
Vendor/ZIPFoundation/       Pinned ZIPFoundation 0.9.20
Vendor/RDP/                 FreeRDP/WinPR/OpenSSL hashes, provenance, licenses
Native/                     macOS RDP bridge and restricted directory service
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

The macOS app launches OpenSSH/SFTP subprocesses, so App Sandbox remains disabled. The iOS/iPadOS app uses its own sandbox container and an independent SwiftData V5 database; it does not synchronize Mac data. Desktop connection types are shared metadata only on mobile and cannot enter its connection or monitoring pages. Mobile connections are foreground-scoped: monitoring reconnects after foregrounding, while terminals and interrupted transfers require explicit user restart and do not promise process recovery or transfer resume. CloudKit, TestFlight, StoreKit, widgets, Live Activities, paid tiers, guaranteed 24×7 alerts, and Mosh remain outside the current scope. See [ADR-0005](Docs/ArchitectureDecisions/ADR-0005-native-ios-and-dual-ssh-engine.md).
