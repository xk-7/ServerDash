# ADR-0005: Native iOS/iPadOS app and dual SSH engines

- Status: Accepted
- Date: 2026-09-05
- Decision: D-12
- Supersedes: ADR-0001 decision 1 for iOS/iPadOS only

## Context

ServerDash needs a native iPhone and iPad experience without Mac Catalyst. The
macOS implementation depends on `Process` and system OpenSSH, neither of which is
an iOS transport. The monitoring parser, models, host-trust semantics, and most
business rules should remain shared. Mobile lifecycle rules also prohibit an
assumption that SSH sessions can remain alive indefinitely in the background.

## Decision

1. `ServerDashMobile` is one universal iOS application target with bundle ID
   `com.serverdash.app.ios` and iOS/iPadOS 18 as its minimum deployment target.
2. The target uses SwiftUI directly. iPhone uses a bottom `TabView` and
   `NavigationStack`; iPad uses a collapsible `NavigationSplitView`. Mac Catalyst
   is not enabled.
3. Shared code depends on `RemoteConnectionEngine`, `RemoteSession`,
   `RemoteShellSession`, and `RemoteFileClient`. macOS continues to use the
   system-OpenSSH process stack. iOS/iPadOS uses locally pinned Citadel 0.12.1.
4. Mobile NIOSSH is locally pinned from 0.3.6 and carries the upstream
   `31cdc3c3391a10460dedf1170530cf651d2ca496` malformed-ECDSA-signature fix for
   GHSA-998x-vgvp-xwpc. Real mobile SSH delivery is blocked if this regression
   test fails or the patch cannot be maintained safely.
5. Host-key verification always fails closed. The SSH handshake pauses for an
   explicit decision when a key is unknown or changed. A rejection closes the
   connection. There is no global accept-all mode.
6. Mobile authentication supports passwords and imported OpenSSH Ed25519/RSA
   private keys. Passwords, private keys, and passphrases use
   `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. External key paths, SSH Agent,
   SSH Config, jump hosts, proxies, and forwarding are not presented on mobile.
7. The mobile app uses the V3 SwiftData schema in its own sandbox container with
   CloudKit disabled. It does not migrate, import, or synchronize the Mac store.
8. On background entry, new monitoring work stops and live SSH/SFTP resources are
   closed. Monitoring may reconnect after foregrounding. Terminals and file
   transfers require an explicit new attempt; remote process recovery and
   resumable transfer are not promised.
9. SwiftServer is an interaction and product reference only. No SwiftServer code,
   text, or assets are copied.

## Consequences

- Mobile and Mac can share models, parsing, diagnostics, capability descriptions,
  and connection contracts while retaining platform-correct transports.
- A user who owns both apps has two independent local data stores and Keychain
  access groups. Cross-device sync requires a future storage/security decision.
- Mobile SFTP uses Files import/export and never persists an external
  security-scoped path after import.
- Port forwarding, proxies, jump hosts, SSH Agent, external identity paths, and a
  local terminal remain Mac-only capabilities.
- TestFlight, App Store distribution, StoreKit, widgets, Live Activities, and
  background-resident SSH remain outside this decision.

## Rejected alternatives

- Mac Catalyst, because it would preserve desktop assumptions instead of native
  compact/regular-size-class behavior.
- Shelling out to OpenSSH on iOS, because iOS does not provide the supported
  process environment required by the Mac implementation.
- Accepting unknown host keys automatically, even for convenience or testing.
- Shipping an unpatched NIOSSH revision or suppressing the security regression.
- Sharing the Mac database by copying its files or adding CloudKit implicitly.
