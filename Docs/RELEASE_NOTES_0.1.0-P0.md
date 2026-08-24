# ServerDash 0.1.0 P0 Test Build

This is an ad-hoc signed, non-notarized preview build of ServerDash for macOS 14 or later. It contains the first five independently verified P0 performance-hardening batches.

## Highlights

- Added privacy-safe OS Signposts for launch, database, monitoring, host trust, subprocesses, dashboard updates, terminal operations, and SFTP.
- Reworked subprocess handling around bounded 32 KiB streaming reads, explicit output limits, FIFO capacity, scoped cancellation, and process-group TERM → KILL cleanup.
- Removed steady-state `ssh-keyscan` work for trusted hosts while preserving strict host-key verification and changed-key blocking.
- Added one central monitoring coordinator with per-server deduplication, priority scheduling, dynamic refill, capped backoff, low-power behavior, and sleep/network suspension.
- Split monitoring presentation into independent per-server RuntimeState objects with atomic result publication and incremental fleet summaries.
- Added explicit first-snapshot waiting states and preserved the last successful monitoring data after failures.

## Security and privacy

- SSH and SFTP continue to enforce `StrictHostKeyChecking=yes` with the application-specific `known_hosts` file.
- Host-key changes remain blocking until the matching immutable trust request is explicitly accepted.
- Performance markers and touched diagnostic paths do not record hosts, users, paths, commands, fingerprints, or credentials.

## Validation

- Universal Release build: passed for `arm64` and `x86_64`.
- Automated tests: 77 passed, 0 failed, 0 skipped.
- Ad-hoc application signature: verified.
- DMG filesystem checksum: verified with `hdiutil verify`.
- SHA-256: `24280a7d27975b77240fbda52a4f50f3bf2a8c3d4742b2b3a688880d19033046`.

## Known limitations

- This test build is ad-hoc signed and is not notarized. On first launch, use Control-click → Open or allow the app in System Settings → Privacy & Security.
- SFTP progress/task-model work, terminal interactive-readiness/context work, and terminal resource budgets remain in later P0 batches.
- SwiftUI body-update counts, long-running RSS, Energy Log, real-server keyscan counts, SFTP connection counts, and terminal echo latency remain pending Instruments or real-server validation.
- The current Swift 5.9 build reports an SFTP concurrency-capture warning that must be resolved before enabling Swift 6 language mode.

Full engineering status and acceptance coverage are documented in [P0_IMPLEMENTATION_STATUS.md](P0_IMPLEMENTATION_STATUS.md).
