# ServerDash 0.1.0 test.3 — S00 decision baseline

ServerDash 0.1.0 test.3 is an ad-hoc signed, non-notarized internal preview for
the owner and a small number of known testers. The application bundle has build
number 2 and requires macOS 14 or later.

## What changed

- Added four accepted architecture decision records covering the internal
  distribution/System OpenSSH route, single-workspace ownership, monitoring
  availability commitment, primary Linux platforms, and the initial Docker CLI
  provider.
- Froze the 1.0 core scope and explicit non-goals. No paid feature split,
  Developer ID dependency, public distribution, CloudKit, team backend, or
  always-on monitoring promise is designed into this release line.
- Defined location lookup as opt-in and disabled by default for new users. The
  current setting/default implementation does not yet enforce the frozen policy
  and remains a documented pre-release item.
- Updated the English and Chinese README files so distribution, platform support,
  privacy, and compatibility claims match the accepted decisions.
- Increased `CFBundleVersion` from 1 to 2 so this package is distinguishable from
  the previous 0.1.0 internal builds.

This release does not claim S01-S06 completion and does not add a new SSH, SFTP,
database, credential, trust, or update implementation.

## Security and privacy

- SSH and SFTP continue to use macOS system OpenSSH and enforce
  `StrictHostKeyChecking=yes` with the application-specific `known_hosts` file.
- The build is ad-hoc signed and not notarized. It is intended only for known
  testers and is not suitable for public distribution.
- No real Keychain credential, database, host configuration, Sparkle private key,
  or external update artifact was used or added to the repository.
- Performance markers and touched diagnostic paths continue to exclude hosts,
  users, paths, commands, fingerprints, and credentials.

## Local validation

- Debug application build: passed.
- Universal Release application build: passed for `arm64` and `x86_64`.
- Automated tests: 77 passed, 0 failed.
- Ad-hoc application signature: verified.
- DMG filesystem checksum: verified with `hdiutil verify`.
- DMG SHA-256: `b36ea5f44fee06e0e1cbe18e721c658dc370ebc2d781bf1d7d25edb534e72004`.

## Installation

1. Download `ServerDash-0.1.0-test.dmg` from this prerelease.
2. Open the DMG and drag ServerDash to `/Applications`.
3. Because this build is not notarized, use Control-click → **Open** on first
   launch, or allow it in **System Settings → Privacy & Security**.
4. Keep a backup of ServerDash data before testing upgrade or recovery paths.

## Known limitations and pending validation

- The current persistence layer does not yet meet the S01 VersionedSchema,
  migration-fixture, app-exclusive-directory, or consistent WAL/SHM backup gates.
- Location lookup is not yet disabled by default in the current UI/settings code.
- The current Swift 5.9 build reports an SFTP concurrency-capture warning that
  becomes an error under Swift 6 language mode.
- Real SSH/SFTP journeys, first launch on another Mac, sleep/wake behavior,
  Instruments measurements, and long-running stability remain pending real-device
  validation.
- This release does not include Sparkle automatic updates. Install it manually;
  do not treat a future update path as verified until S06 passes.

Engineering decision details are in
[ArchitectureDecisions/README.md](ArchitectureDecisions/README.md), and the
frozen product boundary is in [PRODUCT_SCOPE_1.0.md](PRODUCT_SCOPE_1.0.md).
