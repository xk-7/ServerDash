# ServerDash Architecture Decisions

This directory contains the product and architecture decisions frozen for the
small-group internal-test release. An accepted decision is a constraint on later
implementation; it is not evidence that the corresponding implementation stage
has passed.

| Decision | Status | Implementation owner |
| --- | --- | --- |
| [ADR-0001: Internal distribution and SSH engine](ADR-0001-internal-distribution-and-ssh-engine.md) | Accepted | S01, S03, S06 |
| [ADR-0002: Single workspace window and task ownership](ADR-0002-single-window-and-task-ownership.md) | Accepted | S04, S05 |
| [ADR-0003: Monitoring runtime commitment](ADR-0003-monitoring-runtime-commitment.md) | Accepted | S04, later alert work |
| [ADR-0004: Remote platform and Docker provider scope](ADR-0004-remote-platform-and-docker-provider-scope.md) | Accepted | capability work after the foundation stages |
| [ServerDash 1.0 scope and non-goals](../PRODUCT_SCOPE_1.0.md) | Frozen | S01-S06 and later product planning |

## Decision identifiers covered by S00

- `D-01`: ADR-0001
- `D-02`: ADR-0002
- `D-03`: ADR-0003
- `D-06`: ADR-0004
- `D-07`: ADR-0004
- Location collection default and consent: `PRODUCT_SCOPE_1.0.md`
- Core/experimental boundary and absence of paid tiers: `PRODUCT_SCOPE_1.0.md`

Changes to an accepted decision require a new superseding ADR. Editing history
to make a changed decision look as though it was always in force is prohibited.
