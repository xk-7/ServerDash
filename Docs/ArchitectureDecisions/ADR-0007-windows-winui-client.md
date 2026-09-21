# ADR-0007: Native Windows client on a long-lived branch

- Status: Accepted for the Windows alignment track
- Date: 2026-09-21
- Decision: D-13
- Branch: `windows/align-macos`
- Does not supersede ADR-0001, ADR-0005, or ADR-0006 on Apple platforms

## Context

ServerDash 1.0.4 ships a native macOS workbench and a native iPhone/iPad app.
There is no Windows client. Mentions of “Windows” in the Apple tree mean RDP
to a remote Windows host, not a ServerDash process running on Windows.

macOS depends on AppKit, system OpenSSH via `Process`, the Keychain, and
SwiftData. Those APIs are not available on Windows. iOS already required a
second SSH engine (Citadel) for the same reason. A third client therefore
needs its own UI stack, storage, and secret store, while matching macOS
*behavior* rather than the iOS capability subset.

## Decision

1. The Windows client lives on `windows/align-macos` under `Windows/`. It is
   not added to `project.yml`, Xcode, or the macOS CI workflow.
2. The UI is WinUI 3 / C# (.NET 8, Windows App SDK). Mac Catalyst, SwiftUI
   on Windows, and Electron are out of scope.
3. Shared Swift sources are not compiled for Windows. C# mirrors the contracts
   in `RemoteConnectionEngine`, `RemoteSession`, `RemoteShellSession`, and
   `RemoteFileClient`, plus `PlatformCapabilities.macOS` (desktop, not mobile).
4. SSH and SFTP use the Windows OpenSSH Client (`ssh.exe` / `sftp.exe`) as
   subprocesses. Missing binaries fail closed. There is no bundled SSH daemon,
   no “accept all hosts” mode, and no `StrictHostKeyChecking=no` / `accept-new`
   fallback. Host keys live in an app-owned `known_hosts` file.
5. Secrets use Windows Credential Manager with local (non-roaming) persist.
   Durable records store only credential references. Temporary key material
   uses an app-owned per-launch directory.
6. Product data is rooted at `%LOCALAPPDATA%\ServerDash\`. The future SQLite
   store is `%LOCALAPPDATA%\ServerDash\Data\`. This store is independent of
   macOS SwiftData and iOS containers; files are not copied or merged.
7. One business workspace window (ADR-0002). Settings, dialogs, and flyouts
   are not additional business windows.
8. RDP on the Windows client remains in development and is scheduled after
   SSH, SFTP, and monitoring. Presence of a window shell is not an RDP
   interoperability claim.
9. Apple README, CHANGELOG, and the website do not list Windows as a shipped
   client until a Windows build exists and a later decision says so.

## Consequences

- WinUI applications build on Windows only. This repository may still hold
  the sources and `ServerDash.Core` tests; a missing Windows machine does not
  make the client releasable.
- `macos-dev.sh doctor --release` continues to require the primary worktree
  on `main`. Release cuts stay on the Apple line.
- Jump hosts, proxies, forwarding, local shell, serial, VNC, WebDAV, recording,
  and AI are planned on this branch to match macOS, but each phase must update
  [WINDOWS.md](../WINDOWS.md) before it is treated as present.
- A later merge to `main` requires a Windows build that at least compiles and
  a review of this ADR against shipping claims.

## Rejected alternatives

- Compiling the existing SwiftUI/AppKit tree with Swift on Windows.
- Reusing the iOS Citadel stack as the Windows SSH engine.
- Sharing or importing the macOS SwiftData file or Keychain items.
- Disabling host-key checking to paper over a missing OpenSSH Client.
- Declaring a Windows client in public docs from the scaffold alone.
