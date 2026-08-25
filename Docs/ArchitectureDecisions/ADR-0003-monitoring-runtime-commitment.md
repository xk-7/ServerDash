# ADR-0003: Monitoring runtime commitment

- Status: Accepted
- Date: 2026-08-25
- Decision: D-03

## Context

A desktop client using local OpenSSH subprocesses cannot truthfully promise
continuous monitoring while the Mac is asleep, powered off, disconnected, or the
application is not running. Product language and lifecycle behavior need the same
boundary.

## Decision

1. ServerDash 1.0 promises monitoring while the app is running and macOS permits
   execution. The primary supported experience is the foreground workspace.
2. Sleep and loss of connectivity suspend new monitoring work and cancel active
   monitoring subprocesses. Wake or network restoration may resume scheduling
   with bounded concurrency and staggered retries.
3. A menu bar presence and login item may later keep the app conveniently
   available, but neither changes the sleep/power/network limitation or creates a
   24×7 availability promise.
4. ServerDash does not advertise guaranteed alerts, background-daemon uptime,
   service-level objectives, or monitoring while the Mac sleeps.
5. Timestamps and stale-data presentation must distinguish the last confirmed
   sample from current reachability. Missing time ranges are not backfilled as if
   they had been observed.

## Consequences

- Existing sleep/wake and network suspension in `MonitoringCoordinator` aligns
  with the decision, but app-wide drain and lifecycle acceptance remain in S04.
- Reliable 24×7 monitoring or alert delivery would require a separately designed
  always-on component or service and a superseding product decision.
- Test plans must include sleep, wake, offline, quit, and restart behavior without
  claiming remote or power-state coverage from unit tests alone.

## Rejected alternatives

- Marketing the Mac client as an always-on monitoring service.
- Continuing probes during known sleep/offline transitions.
- Adding an undocumented daemon, helper, or remote agent to simulate continuity.
