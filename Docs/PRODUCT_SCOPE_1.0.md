# ServerDash 1.0 internal-test scope and non-goals

- Status: Frozen for S00; mobile amendment accepted by ADR-0005
- Date: 2026-09-05
- Distribution: the owner and a small number of known testers

This document is the product boundary for the 1.0 internal-test line. Inclusion
means a capability may ship only after its owning stage passes; it does not claim
that the current repository has already met that stage's acceptance criteria.

## Core release scope

- One native macOS business workspace plus one universal native iPhone/iPad app
  for managing Linux server profiles; Mac Catalyst is excluded.
- macOS system OpenSSH and iOS/iPadOS Citadel connectivity behind shared session
  contracts, both with strict app-owned host-key verification.
- Ubuntu LTS and Debian Stable as the primary supported remote platforms.
- Resource monitoring with capability-gated presentation and truthful stale/error
  states while ServerDash is running.
- Multiple app-owned SSH terminal sessions whose lifecycle is independent of a
  page transition.
- SFTP browsing and atomic upload/download behavior that never reports success
  before the final target is verified.
- SwiftData metadata in an app-exclusive data directory, Keychain-held secrets,
  versioned migrations, consistent backups, and explicit recovery paths.
- Structured cancellation, timeout, output-limit, remote-exit, interruption, and
  recovery states for subprocesses and long-running operations.
- Ad-hoc signed manual test builds. S06 may add Sparkle 2 HTTPS/EdDSA updates with
  a manual-update fallback after its local and real-Mac gates pass.
- Local redacted diagnostics sufficient for known testers to report problems.
- Mobile machine management, foreground dashboard monitoring, remote terminals,
  SFTP, identities, imported keys, snippets, and trusted-host management.
- Independent per-app SwiftData V3 stores with CloudKit disabled; mobile data is
  not copied from, synchronized with, or merged into the Mac store.

## Privacy decision: location is opt-in

- Remote public-IP/geolocation lookup is disabled by default for new users.
- Enabling it requires a deliberate setting change that explains the remote
  request and identifies the service involved before the first request.
- Disabling it stops new location requests and clears in-memory location cache.
- Location, raw host values, and unredacted IP addresses are not written to
  diagnostics.
- The current UI/default-value enforcement does not yet satisfy this frozen
  contract and must be closed before the internal-test release is accepted.

## Compatibility and limited features

- AlmaLinux and Rocky Linux are capability-gated compatibility targets, not
  primary support commitments.
- Alpine, BusyBox-based systems, non-Linux hosts, and unusual remote shells have
  no 1.0 support commitment.
- Docker 1.0 scope is remote-CLI discovery and read-only status. Docker Engine API
  remains an isolated experiment.
- Menu bar presence and a login item may be evaluated for convenience, but do not
  create an always-on monitoring commitment.
- Mobile supports only direct routes using password or imported OpenSSH
  Ed25519/RSA private-key authentication.
- Mobile background entry interrupts terminals and transfers. Monitoring may
  reconnect after foregrounding; remote-process recovery and resumable transfer
  are not product commitments.

## Explicit non-goals

- Multi-window business workspaces.
- Guaranteed 24×7 monitoring or alerts while the Mac sleeps or the app is not
  running.
- Developer ID signing, notarization, Mac App Store distribution, StoreKit, or
  purchasing Apple Developer Program membership.
- Public or unattended mass distribution.
- CloudKit, team accounts, shared vaults, multi-device secret synchronization, or
  paid feature tiers.
- A privileged helper, bundled remote agent, team backend, SSH CA, SSH
  certificates, hardware-key management, or mandatory Touch ID.
- Full Docker operations, backup automation, AI operations, batch administration,
  approval workflows, or advanced maintenance scheduling.
- Mosh, bidirectional sync, server-to-server transfer, rsync acceleration,
  remote file editing, or Quick Look.
- On iPhone/iPad: port forwarding, jump hosts, proxies, SSH Agent, SSH Config,
  external private-key paths, local terminals, and background-resident SSH.
- iOS 17 and earlier, Mac Catalyst, CloudKit/iCloud sync, TestFlight, App Store
  release, StoreKit, widgets, and Live Activities.

## Scope-change rule

No paid/free split is designed for 1.0. Moving a non-goal into the release or
changing the distribution, privacy, platform, SSH-engine, monitoring-availability,
or window-ownership decisions requires an explicit scope update and, where
applicable, a superseding ADR before implementation starts.
