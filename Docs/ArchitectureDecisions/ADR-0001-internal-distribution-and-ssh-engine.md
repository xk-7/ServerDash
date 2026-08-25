# ADR-0001: Internal distribution and SSH engine

- Status: Accepted
- Date: 2026-08-25
- Decision: D-01
- Audience: the owner and a small number of known testers

## Context

ServerDash launches interactive and non-interactive SSH/SFTP subprocesses and is
not intended for public distribution in the 1.0 internal-test line. The owner
will not purchase Apple Developer Program membership. The release design must
therefore not depend on Developer ID, notarization, the Mac App Store, StoreKit,
or a privileged helper.

## Decision

1. ServerDash uses the macOS system OpenSSH executables as its only 1.0 SSH and
   SFTP engine. A bundled SSH implementation, helper, agent, or remote daemon is
   not part of this release line.
2. Local development and small-group builds use ad-hoc code signing. App Sandbox
   remains disabled because the current OpenSSH subprocess architecture requires
   capabilities that are not represented by the existing sandbox design.
3. Builds are shared manually with known testers. S06 may add Sparkle 2 updates,
   but those updates must use HTTPS and Sparkle EdDSA archive signatures and must
   retain a documented manual-download fallback. Sparkle signing does not turn an
   ad-hoc build into a notarized public-distribution build.
4. No Developer ID certificate, Apple notarization, Mac App Store submission, or
   paid Apple entitlement is a prerequisite for architecture, storage, testing,
   backup, or recovery.
5. Host verification always uses strict checking and an app-owned trust file.
   Missing or changed host keys fail closed. Distribution limitations must never
   be compensated for by weakening SSH verification.
6. Product data is rooted below
   `Application Support/ServerDash/`; the durable database target is
   `Application Support/ServerDash/Data/default.store`. Backups, staging files,
   recovery, and deletion must remain inside app-owned directories. This path
   contract is independent of code-signing identity and is implemented in S01.
7. Secrets remain in the macOS Keychain. Durable SwiftData records contain only
   references and metadata; temporary private-key material uses app-owned,
   per-launch protected directories and is implemented in S02.

## Consequences

- Testers may need to confirm first launch through macOS security UI and should
  install the app in `/Applications`. These limitations must be documented and
  must not be presented as public-release security.
- A later move to Developer ID, notarization, sandboxing, or a different SSH
  engine requires a superseding ADR and a new threat/data-migration review.
- `project.yml` currently matches the ad-hoc/no-sandbox direction. The storage,
  migration, update-signature, and recovery guarantees are acceptance work for
  S01 and S06, not claims made by this ADR.

## Rejected alternatives

- Purchasing Apple Developer Program membership for this internal-test release.
- Treating macOS code signing as the SSH trust root.
- Disabling `StrictHostKeyChecking` or falling back to global known-host entries.
- Publishing unsigned ZIP updates or placing an EdDSA private key in the repo,
  build log, or update server.
