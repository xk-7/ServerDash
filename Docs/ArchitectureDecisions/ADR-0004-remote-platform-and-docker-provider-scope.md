# ADR-0004: Remote platform and Docker provider scope

- Status: Accepted
- Date: 2026-08-25
- Decisions: D-06, D-07

## Context

Monitoring commands and parsing differ across Linux distributions, init systems,
package layouts, shells, and Docker deployments. Claiming broad support without
capability evidence would make failures difficult to classify and unsafe remote
writes harder to constrain.

## Decision

1. Ubuntu LTS and Debian Stable are the primary supported remote platforms for
   the 1.0 internal-test line.
2. Other Linux systems, including AlmaLinux and Rocky Linux, are compatibility
   targets only. Features are enabled from observed capabilities, not merely from
   a distribution name. Alpine, BusyBox-based systems, non-Linux hosts, and
   unusual shells are unsupported unless a later compatibility matrix says
   otherwise.
3. Unsupported or missing capabilities produce explicit unavailable/unsupported
   states. They must not silently run a command intended for a different platform
   or be interpreted as zero-valued healthy data.
4. Initial Docker support uses the remote Docker CLI through the same SSH trust,
   immutable connection configuration, process supervision, and operation audit
   boundaries as other remote work.
5. Docker Engine API support is a separate experiment. It is not an automatic
   fallback, is not exposed as a production provider in 1.0, and requires its own
   transport/authentication/threat validation before a later decision can enable
   it.
6. The 1.0 scope includes Docker discovery/read-only status only. A complete
   Docker operations panel and broad write controls are non-goals.

## Consequences

- Documentation must say “primary support” only for Ubuntu/Debian and must label
  other distributions as compatibility targets.
- Capability probes and fixtures take precedence over distro-name assumptions.
- Remote Docker writes, if later admitted to scope, must use the Operations Center
  safety model rather than invoking CLI commands directly from a page.

## Rejected alternatives

- Declaring every Linux distribution supported because it has SSH.
- Enabling Docker Engine API as a silent fallback from CLI failure.
- Treating missing tools or parser fields as healthy zero metrics.
