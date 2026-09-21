# Windows client alignment

Status: **P1 core landed** on `windows/align-macos`. This is not a shipped
Windows product. Rows marked Planned or partial are not complete desktop
equivalents of macOS.

The Windows client is a new WinUI 3 / C# workbench under [`Windows/`](../Windows/).
It mirrors macOS desktop capabilities (not the iPhone/iPad subset). See
[ADR-0007](ArchitectureDecisions/ADR-0007-windows-winui-client.md).

Build and OpenSSH prerequisites: [Windows/README.md](../Windows/README.md).

## Feature matrix

| Capability | macOS 14+ | Planned Windows | Status on this branch |
| --- | --- | --- | --- |
| Hosts, identities, groups, tags | Yes | Yes | P1: JSON host catalog (no group/tag UI) |
| Fail-closed host trust / app `known_hosts` | Yes | Yes | P1: ssh-keyscan TOFU; Trust once / Store / Reject |
| Password and imported private key | Yes | Yes | P1: Credential Manager + ASKPASS / temp key |
| Linux monitoring and Data Gap | Yes | Yes | P1: probe + fallback parse; no history/Data Gap UI |
| Multi-tab SSH terminal | Yes | Yes | P1: one basic `ssh -tt` stream; no VT / splits |
| SFTP browse / transfer (success after verify) | Yes | Yes | P1: list / get / put; success only if local target exists |
| External key path / SSH Agent / SSH Config | Yes | Yes | Planned (P2) |
| Jump hosts, SOCKS5, HTTP CONNECT | Yes | Yes | Planned (P2) |
| Local / remote / dynamic forwarding | Yes | Yes | Planned (P2) |
| Workbench inspector, batch commands, privacy mode | Yes | Yes | Window shell only (P3) |
| Local terminal | Yes | Yes (ConPTY) | Planned (P4) |
| Serial | Yes | Yes | Planned (P4) |
| VNC | Yes (Screen Sharing) | Yes (embedded or helper) | Planned (P4) |
| Encrypted WebDAV configuration sync | Yes | Yes | Planned (P4) |
| Session recording | Yes | Yes | Planned (P4) |
| AI assistant | Yes | Yes | Planned (P4) |
| RDP remote desktop | In development | In development | Not started (P5) |

iPhone/iPad remain a separate, reduced surface. Windows is not that surface.

## P1 foundation

- `PlatformCapabilities.Windows` matches `PlatformCapabilities.macOS`.
- Hosts persist in `%LOCALAPPDATA%\ServerDash\Data\hosts.json`. Secrets are not
  written to that file.
- `OpenSshLocator` fails closed when `ssh` / `sftp` are missing. Unknown hosts
  fail closed if `ssh-keyscan` is missing.
- Launch arguments always set `StrictHostKeyChecking=yes` and an app-owned
  `UserKnownHostsFile`. `accept-new` and `no` are rejected.
- Interactive SSH is a raw byte stream plus an input line. It is not SwiftTerm.
- Monitoring uses the fallback collector script and `MonitoringResponseParser`.
  GPU/Docker values may parse into the model; the window only shows CPU, memory,
  load, disk, network, and processes.
- SFTP downloads throw if the local target is absent after `get`.
- RDP is not offered in the window.

## Explicitly not done

- Jump hosts, proxies, forwarding, SSH Config, Agent.
- Complete VT terminal, pane splits, session recording.
- Monitoring history / Data Gap charts.
- Remote edit, directory sync, WebDAV, AI, serial, VNC, local ConPTY.
- No entry in the Apple README platform table or the public website.
