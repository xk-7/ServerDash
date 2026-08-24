# P0 implementation status

Updated: 2026-08-24

This file records the checked implementation, the intended small-batch changes, and the verification boundary. The performance requirement document is treated as a baseline, not as an instruction to rewrite the application.

## Checked repository state

- No repository `AGENTS.md` was found.
- The worktree was clean before this effort started.
- The app is a macOS 14 SwiftUI application generated from `project.yml`, with a checked-in Xcode project and a local SwiftTerm package.
- The unmodified Debug test run executed 49 tests with no failures. The cold-DerivedData `xcodebuild test` invocation took 46.60 seconds; test execution took 0.543 seconds; the xcodebuild process reported a maximum RSS of about 216 MiB.
- That build baseline is only a reproducibility reference. It is not an app launch, frame-time, energy, or long-running RSS result.

## Requirement-to-code mapping

### P0-1: Measurement points and baseline

- Current code: `Sources/Diagnostics.swift` provides OSLog, but had no performance intervals. The test target had no XCTest performance baseline.
- Change: add fixed-name, metadata-free OSSignposter intervals/events; instrument launch, database, process, host-key, monitoring, dashboard, terminal, and SFTP boundaries; add a deterministic parser performance test.
- Acceptance: markers contain no runtime strings or connection identifiers; all existing tests pass; Instruments can select the documented operation names.
- AC coverage: enables measurement for AC-PERF-01 through AC-PERF-12 and AC-UI-06/10. Numeric UI and real-network SLOs remain pending device validation.

### P0-2: Streaming subprocesses, caps, cancellation, and process ownership

- Current code: `Sources/ConnectionEngine.swift` reads both pipes to EOF before checking limits, polls capacity every 120 ms, sends a single termination on task cancellation, and ignores the server filter in `terminateAll(for:)`.
- Change: bounded chunk reads with immediate termination, structured run records, TERM-to-KILL escalation, timeout/cancel/output-limit terminal reasons, server-scoped termination, and a FIFO continuation queue.
- Acceptance: AC-PERF-04, 05, 06, and 07 with local subprocess regression tests; residual-child validation on a real process tree remains an integration check.

### P0-3: Steady-state trust and trust-request queue

- Current code: `Sources/TrustedHosts.swift` always scans during inspect; `Sources/AppState.swift` holds one mutable prompt and resumes work from selected/global state.
- Change: known-hosts lookup first, keyscan only for first use/change/reverify, preserve strict OpenSSH checking, and queue immutable requests bound to their operation.
- Acceptance: AC-PERF-03 and AC-FLOW-05/06; changed keys must still block.

### P0-4: Single monitoring coordinator

- Current code: `Sources/DashboardViews.swift` owns a page loop while `Sources/AppState.swift` owns another selected-server loop and a three-server chunk barrier.
- Change: one bounded coordinator with deduplication, priority, jitter, backoff, and immediate queue refill; views only subscribe and request priorities.
- Acceptance: AC-PERF-02 and AC-UI-01/04; sleep, wake, and poor-network cases require integration validation.

### P0-5: Per-server runtime state and atomic publication

- Current code: `Sources/AppState.swift` publishes fleet-wide dictionaries and mutates several values per result; dashboard cards observe the full object.
- Change: a per-server observable render state and one result commit, with incremental fleet totals.
- Acceptance: AC-PERF-01 and AC-UI-02/03, plus SwiftUI Body Updates on the standard 100-card dataset.

### P0-6: SFTP progress model

- Current code: `Sources/SFTPService.swift` measures uploads through additional remote listings every 400 ms and downloads by repeated local tree scans.
- Change: derive progress from the single transfer process/events, coalesce UI publication to at most 4 Hz, and keep task state outside the page.
- Acceptance: AC-PERF-08/09 and AC-FLOW-10 through 13, plus network/file-activity validation.

### P0-7: Terminal state and cross-server context

- Current code: `Sources/TerminalSessions.swift` marks connected immediately after process launch; `Sources/AppState.swift` chooses the last remaining tab and does not atomically resynchronize every context on close.
- Change: model preparation/authentication/PTY-interactive states and move the interactive marker to a real readiness signal; enforce the selected-session/server/route invariant and adjacent-tab close behavior.
- Acceptance: AC-FLOW-07/08/09/14 and AC-UI-06. High-output latency requires a real terminal load.

### P0-8: Test/save semantics and terminal resource budgets

- Current code: `Sources/EditorAndSettingsViews.swift` persists secrets and the server during SSH test and can reset verification on ordinary saves. Terminal controllers have no explicit fleet budget.
- Change: in-memory test credentials and no persistence, connection-field change detection, status preservation, and explicit session/scrollback/image/pending-output budgets.
- Acceptance: AC-FLOW-01/02/03 and AC-PERF-10/11; memory ceilings require Instruments.

## Dependency order and batches

1. Measurement points and reproducible local baseline.
2. Subprocess streaming/lifecycle and FIFO capacity.
3. Steady-state trust plus the request queue.
4. Central monitoring coordinator.
5. Per-server runtime state and atomic publish.
6. SFTP progress/task model.
7. Terminal state/context and test/save semantics.
8. Terminal resource budgets and final P0 stress pass.

The process layer precedes trust, monitoring, and SFTP because all three use it. The runtime-state split follows the coordinator so there is only one result owner. Terminal and editor work can be verified independently after the shared trust flow is stable.

## Batch 1 scope and validation

- Changed measurement boundaries: `Sources/Diagnostics.swift`, `Sources/ServerDashApp.swift`, `Sources/ContentView.swift`, `Sources/Persistence.swift`, `Sources/ConnectionEngine.swift`, `Sources/TrustedHosts.swift`, `Sources/Services.swift`, `Sources/AppState.swift`, `Sources/DashboardViews.swift`, `Sources/SFTPService.swift`, and `Sources/TerminalSessions.swift`.
- Changed regression/performance tests: `Tests/FoundationTests.swift`.
- No SSH security option is changed. Strict host-key checking remains enabled.
- No signpost accepts runtime metadata. Source logging touched by this batch no longer records the subprocess executable path.
- Pending device validation: launch-to-frame, launch-to-interactive, SwiftUI body fan-out, frame p95, wakeups, actual app RSS, keyscan count on a trusted real server, SFTP connection count, terminal echo latency, and one-hour stability.

### Batch 1 actual result

- Debug application build: passed.
- Targeted tests: performance marker allow-list, parser performance baseline, and process cancellation all passed (3 tests, 0 failures).
- Full suite: 51 tests passed with 0 failures.
- Parser baseline on this development Mac: 100 parses of a synthetic 16-core/100-process payload averaged 0.087–0.088 seconds across two runs; CPU time averaged 0.083–0.084 seconds. This is approximately 0.87–0.88 ms per parse in a Debug test host and is below the 20 ms parse/publish target for this synthetic payload only.
- XCTest physical-memory delta was too small and noisy to use as a threshold. Absolute test-host peak memory is not treated as app RSS or per-parse allocation.
- AC-PERF: no end-to-end AC is claimed complete in this measurement-only batch. AC-PERF-01/03/06 now have direct marker support; AC-PERF-02/04/05/07 through 12 require the later behavior batches and/or real workloads.
- AC-FLOW: unchanged by this batch; the existing flow/model tests remain green, but AC-FLOW-01 through 14 are not claimed complete.
- AC-UI: `dashboard.card_body_update`, launch, and terminal tab-switch markers are available. AC-UI-06/10 and frame thresholds remain pending Instruments validation.
- `terminal.interactive` is reserved in the fixed marker allow-list but is intentionally not emitted yet: the current code has no truthful PTY-ready signal. The terminal-state batch must attach it to real readiness rather than the current premature green status.

## Batch 2: subprocess streaming and lifecycle

### Implemented

- `Sources/ConnectionEngine.swift` now reads stdout and stderr in 32 KiB chunks. A chunk that would cross the configured cap is not retained, and the process is terminated immediately.
- Monitoring stdout is capped at 512 KB; stderr is capped at the smaller of the request cap and 128 KB.
- Active and recent run summaries contain an anonymous run ID, server ID, module, PID, independently verified process-group ID, start time, and structured termination reason. These values are not emitted into logs or signpost metadata.
- Cancellation, timeout, output-limit termination, natural exit, and server-scoped termination remain distinct in the process record. Public errors map to `.cancelled`, `.timeout`, and `.outputLimitExceeded` as applicable.
- Termination signals the process group with SIGTERM and escalates to SIGKILL after one second by default.
- `terminateAll(for:)` filters by the supplied server ID.
- Connection capacity uses a continuation-backed FIFO queue with explicit cancellation and timeout. The previous 120 ms polling loop has been removed.

### Actual validation

- Application build: passed.
- Targeted process/limiter tests: 10 passed, 0 failed.
- Full suite: 60 tests passed, 0 failed.
- Automated coverage includes output below cap, infinite stdout, infinite stderr, timeout classification, user cancellation, TERM-resistant parent/child cleanup, process-group discovery, server-scoped isolation, FIFO order, waiter cancellation, and waiter timeout.
- AC-PERF-04: the infinite stdout and stderr tests both reached the cap and returned `.outputLimitExceeded` within one second. Long-duration RSS behavior is still pending Instruments, so the full AC is not yet claimed.
- AC-PERF-05: the reader retains no more than the configured cap plus one 32 KiB read chunk, but the approximately 4 MB RSS criterion for a 2 MB cap remains pending an isolated memory run.
- AC-PERF-06: automated cancellation completed within one second and a TERM-resistant child process was absent within two seconds. UI-stop timing for real SSH/SFTP remains pending integration validation.
- AC-PERF-07: automated two-server validation passed; cancelling one server left the other process running.
- AC-FLOW/AC-UI: no page-state behavior changed in this batch. Structured `.cancelled` and `.timeout` results are now available for later UI state machines.

## Batch 3: steady-state trust and request queue

### Implemented

- `TrustedHostStore.inspect` returns a probe reconstructed from the application `known_hosts` file when the host is already trusted. Normal checks therefore do not launch `ssh-keyscan`; a scan is limited to first use, explicit revalidation, or recovery from an OpenSSH host-key error.
- OpenSSH and SFTP continue to use `StrictHostKeyChecking=yes`, the application-specific known-hosts file, and no global known-hosts fallback.
- A main-actor `HostTrustCoordinator` owns immutable requests and checked continuations. Requests are displayed FIFO, cancellation only resumes the matching operation, and accepting a request resumes the exact monitoring, terminal, SFTP, or SSH-test operation that was suspended.
- The editor sheet and the main window present the same coordinator request rather than maintaining independent mutable prompts. Only the currently visible presentation layer displays it.
- Monitoring, SFTP, and SSH-test operations retry once after a host-key failure by forcing a fresh scan and user confirmation. SFTP preserves host-key errors instead of wrapping away their type.
- Terminal preflight uses the same queue. A bounded 4 KiB transient detector recognizes a fragmented OpenSSH changed-key warning, requests forced revalidation, and reconnects only the originating terminal session after acceptance. The detector contents are neither logged nor retained after detection/reset.
- Connection diagnostics and touched error-event paths no longer record hosts, usernames, paths, commands, fingerprints, credentials, or raw error strings. Host-key details remain visible only in the confirmation UI where the user must compare them.

### Actual validation

- Application build: passed.
- Targeted trust tests: 8 passed, 0 failed before the final privacy regression was added. Coverage includes 100 trusted inspections with a scan provider that fails if invoked, forced changed-key detection, FIFO order across three servers/sources, rejection isolation, exact-operation continuation, changed-key request context, and fragmented terminal warning detection.
- Final full suite: 66 passed, 0 failed. This includes the diagnostic privacy regression in addition to the trust and terminal-detector tests.
- AC-PERF-03: the deterministic 100-inspection regression proves zero scan-provider invocations on the trusted fast path. Counting real `/usr/bin/ssh-keyscan` launches during 100 live refreshes remains **待实机验证**.
- AC-FLOW-05: FIFO order, server/source binding, cancellation isolation, and exact continuation resumption pass automated tests. Multi-window visual presentation remains **待实机验证**.
- AC-FLOW-06: monitoring, terminal, SFTP, and both SSH-test entry points use the shared preflight/queue in code; the terminal changed-key detector has automated fragmented-output coverage. First-use and changed-key flows against real servers remain **待实机验证**.
- Changed keys remain blocking: a forced-scan regression verifies that the stored key is not replaced before acceptance. The old and new fingerprints remain bound to the immutable prompt.
- Strict checking audit: both SSH and SFTP arguments still contain `StrictHostKeyChecking=yes`; no permissive fallback was introduced.
- Known existing warning: `SFTPService.swift` still captures a mutable `destinations` value in concurrently executing code. It predates this batch and is assigned to the SFTP progress/task batch rather than being mixed into trust work.

## Batch 4: single monitoring coordinator

### Implemented

- `MonitoringCoordinator` is now the only long-lived monitoring scheduler. The dashboard `.task` loop, selected-server loop, and three-server chunk barrier were removed.
- The actor owns one deduplicated entry per server and refills capacity whenever any operation finishes. Default monitoring concurrency is five; low-power mode reduces it to two and doubles the automatic interval without interrupting terminal or SFTP work.
- Queue priority is `manual > selected > visible > background > retry`. A manual request promotes an existing queued item, and a request for an already-running server waits on that operation instead of starting another one.
- Successful operations schedule their next refresh from completion time. Failures use 5, 15, 30, 60, and 300 second capped backoff with up to 20 percent jitter. Initial and resume scheduling are also staggered.
- Dispatches are rate-limited to 24 per second, below the AC-PERF-02 handshake-start ceiling of 25 per second. The connection layer still applies its independent global/per-server concurrency budget.
- macOS sleep and network loss cancel monitoring work; wake and connectivity restoration resume only after every suspension reason has cleared. `NWPathMonitor`, workspace sleep/wake notifications, and the low-power notification feed the coordinator.
- Dashboard cards only publish visibility priority on appearance changes; pages no longer create polling tasks. Fixed privacy-safe signposts record scheduler dispatch and lifecycle cancellation without identifiers.
- Manual refresh marks the affected server IDs as refreshing before awaiting queue capacity, providing immediate UI state even when all worker slots are occupied.

### Actual validation

- Application build: passed.
- Targeted scheduler tests: 6 passed, 0 failed after adding network/sleep composition coverage.
- Automated coverage verifies dynamic refill without a batch barrier, maximum concurrency, manual promotion, running-server deduplication, low-power concurrency reduction, sleep cancellation/restart, network-plus-sleep suspension composition, the complete capped backoff sequence, and the 24-per-second dispatch policy.
- Final full suite: 72 passed, 0 failed.
- AC-PERF-02: concurrency, refill, deduplication, backoff, jitter, and the handshake-start ceiling are enforced in code and covered deterministically. A 100-server five-minute run measuring actual handshakes, remote CPU, wakeups, and scheduler drift remains **待实机验证**.
- AC-UI-01: manual refresh publishes a queued/running indicator synchronously before waiting. Visual latency under load remains **待实机验证**.
- AC-UI-04: visible cards now influence priority and the page no longer launches fleet refreshes, but animation fan-out is part of the per-server runtime-state batch; the full AC is not yet claimed.
- Sleep, wake, real network transitions, and low-power behavior are unit-covered at the scheduler boundary; Energy Log and real SSH behavior remain **待实机验证**.

## Batch 5: per-server runtime state and atomic publication

### Implemented

- Each server now owns an independent `ServerRuntimeState` containing one immutable-at-publication `ServerRenderState`: status, snapshot, history, error, diagnostics, capabilities, refresh state, and last successful sample time.
- A completed monitoring collection assembles the result locally and calls the runtime publisher once. Identical states do not emit. Starting/queued feedback remains a separate intentional publication so AC-UI-01 is not weakened.
- Dashboard cards, machine rows, and the selected server detail observe the corresponding runtime rather than fleet-wide monitoring dictionaries. The old published status/snapshot/history/error/diagnostics/capabilities/refresh collections were removed.
- `FleetMonitoringSummaryState` incrementally subtracts the previous contribution and adds the new contribution. It is an independent observable object, so a summary change no longer emits `AppState.objectWillChange` to terminal and unrelated application views.
- Dashboard cards no longer subscribe directly to the full `AppState`; they receive the refresh interval and visibility callback as stable inputs. Runtime result publication therefore targets the matching card while the independent summary strip observes only aggregate changes.
- A render state explicitly distinguishes an absent first snapshot. The dashboard, machine list, and monitor detail show a waiting/progress state instead of displaying the empty snapshot as real 0% metrics.
- Failure publication changes status/error/diagnostics while retaining the prior snapshot and history, so a previously populated detail does not jump to an empty page.

### Validation status

- Static consistency: `git diff --check` passed; no legacy fleet-wide monitoring dictionary access remains in views or `AppState`.
- Added regression coverage for one atomic Combine emission, no emission for an identical state, isolation across 100 runtime objects, incremental fleet-summary replacement/removal, and retention of the last successful snapshot on failure.
- Universal Release application build: passed for `arm64` and `x86_64`. The ad-hoc signed application and generated DMG both passed verification.
- Full suite after this batch: 77 tests passed, 0 failed, 0 skipped. This includes atomic Combine publication, no-op publication suppression, isolation across 100 runtime objects, incremental fleet-summary replacement/removal, and last-snapshot retention.
- AC-PERF-01: state ownership, target-only publication, and independent aggregate publication pass deterministic tests. SwiftUI Body Updates on the standard 100-card dataset remains **待实机验证**.
- AC-UI-02: all monitoring entry views now branch on `hasSnapshot` and present an explicit wait state; visual inspection and accessibility verification remain **待实机验证**.
- AC-UI-03: state-transition regression code verifies last-snapshot retention, and the monitor keeps its cards alongside the failure banner; visual stability remains **待实机验证**.
- Known build warning: `SFTPService.swift` captures a mutable destination collection in concurrently executing code. It remains assigned to Batch 6 and will become an error under Swift 6 language mode.
- Batch 6 has not started; the verified RuntimeState batch remains an independent boundary.
