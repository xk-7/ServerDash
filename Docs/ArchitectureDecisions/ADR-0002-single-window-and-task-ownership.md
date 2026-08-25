# ADR-0002: Single workspace window and task ownership

- Status: Accepted
- Date: 2026-08-25
- Decision: D-02

## Context

Multiple independent business windows make selection, trust prompts, terminal
sessions, monitoring, transfers, and quit behavior ambiguous. ServerDash needs
predictable ownership before it adds more long-running operations.

## Decision

1. ServerDash 1.0 has one business workspace window. The macOS Settings scene,
   sheets, alerts, and transient panels are not additional business windows.
2. Navigation selection and the currently presented route belong to a
   `WindowState`-equivalent owner scoped to that workspace.
3. Monitoring, terminal sessions, transfers, trust coordination, and remote
   operation records are app-scoped. Closing or navigating away from a view must
   not implicitly destroy them.
4. Long-lived unstructured tasks require an explicit app-scoped owner. Views may
   request, observe, or cancel work through that owner but must not be the sole
   owner of work intended to survive navigation.
5. Application quit enters a bounded drain: reject new work, stop schedulers,
   cancel owned work, terminate owned process groups, and clean app-owned
   temporary files. Work that cannot be proven complete is persisted or surfaced
   as interrupted/unknown, never success.

## Consequences

- The current `WindowGroup` does not by itself enforce the single-business-window
  decision. Enforcement, app-scoped lifecycle ownership, and quit draining are
  S04 acceptance work.
- SFTP transfers become app-scoped in S05. A page disappearing is not a transfer
  cancellation signal.
- A future multi-window product requires a superseding ADR that defines sharing,
  isolation, trust-prompt routing, and task presentation between windows.

## Rejected alternatives

- One independent set of monitoring/terminal/transfer owners per view.
- Treating SwiftUI view disappearance as application-task cancellation.
- Supporting multiple business windows before task and prompt ownership is
  explicit.
