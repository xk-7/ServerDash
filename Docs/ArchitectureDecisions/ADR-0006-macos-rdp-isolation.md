# ADR-0006: Isolated embedded RDP on macOS

- Date: 2026-09-08
- Decision: accepted for development; interoperability/release gates remain open
- Supersedes the non-Linux exclusion in ADR-0004 only for the RDP desktop scope

RDP is a distinct connection family, not an SSH execution provider. Machine
references include their protocol. The workspace owns each RDP controller and
its immutable per-request configuration; a view never owns the connection.
Ordinary open reuses the most recently selected matching tab without reconnecting.
Each newly requested tab starts an independent client, not necessarily a new
Windows login session. RDP cannot be split or routed into SSH monitoring,
identity, SFTP, recording, AI or session export services.

V4 adds only `RDPConnectionRecord`. The actual store metadata determines whether
an upgrade backup is required; preferences alone are insufficient. A failed
upgrade retains the original database and backup, with no automatic rebuild.
RDP passwords are either transient or separately scoped in this device's Keychain.
Mobile compiles the shared schema but has neither RDP UI nor native libraries.

FreeRDP/WinPR 3.31.0 and OpenSSL 3.5.8 are pinned and built into a static universal
macOS library. The originally planned 3.30.0 was replaced, with approval, because
of subsequently published security fixes. The application requires NLA/TLS1.2+,
rejects gateway/target redirection, owns certificate confirmation and isolates
pins from SSH. Unknown self-signed certificates must have valid signatures and
dates before a person may authorize them. No ignore-all mode exists.

Input stays inside the active AppKit view; no global keyboard tap is installed.
Metal renders bounded frame state independently of SwiftUI ownership. Clipboard
authorization is per connection and only the foreground focused owner accesses
the system pasteboard. Directory mapping uses file-descriptor-relative no-follow
access rather than forwarding unchecked remote paths to the OS.

The current development implementation is not release-complete. In particular,
native file interoperation, per-file mapped-drive progress/cancellation, clipboard
locking, performance and real multi-display behavior require further work or
Windows/hardware verification. See [RDP QA](../RDP_QA.md) and
[dependency provenance](../../Vendor/RDP/README.md). No compatibility claim may
be inferred from a successful build or from the accepted architecture decision.
