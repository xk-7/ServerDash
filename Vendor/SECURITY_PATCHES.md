# Vendored mobile SSH provenance and security patches

## Pinned sources

- Citadel 0.12.1: `ae8562f895de06ccb86fdb1cbb65fd99c8976e12`
- Wellz26/swift-nio-ssh 0.3.6:
  `a05e6bbe6b141ee68da3030e00275504c0595d4d`
- Applied Apple swift-nio-ssh fix:
  `31cdc3c3391a10460dedf1170530cf651d2ca496`

Citadel is resolved from `Vendor/Citadel`; NIOSSH is resolved from
`Vendor/swift-nio-ssh`. `ServerDash.xcodeproj/project.xcworkspace/xcshareddata/
swiftpm/Package.resolved` locks the remaining SwiftPM dependencies.

Citadel's `SSHAlgorithms` and nested `Modification` containers are marked
`@unchecked Sendable` in the local copy. They contain immutable algorithm
metatypes, including NIOSSH's RSA registration pair, whose upstream protocols
do not declare `Sendable`; the annotation removes a Swift 6 migration warning
without changing the enabled algorithms or runtime behavior.

## GHSA-998x-vgvp-xwpc / CVE-2026-43798

The upstream issue allows malformed ECDSA signatures containing oversized `r`
or `s` integers to reach Crypto code that traps. ServerDash backports the
upstream bounds check to:

`Vendor/swift-nio-ssh/Sources/NIOSSH/Keys And Signatures/NIOSSHSignature.swift`

Both components must fit the selected curve point size or decoding throws
`NIOSSHError.invalidSSHMessage`. Regression coverage is in
`Vendor/swift-nio-ssh/Tests/NIOSSHTests/NIOSSHSignatureSecurityTests.swift` and
uses 4096-byte `r` and `s` payloads.

Run the focused security gate from `Vendor/swift-nio-ssh`:

```bash
env CLANG_MODULE_CACHE_PATH=/tmp/serverdash-module-cache \
    SWIFTPM_MODULECACHE_OVERRIDE=/tmp/serverdash-module-cache \
swift test \
  --scratch-path /tmp/serverdash-swiftpm-niossh \
  --filter NIOSSHSignatureSecurityTests
```

Do not ship or enable real mobile SSH when this test fails. Do not replace the
local package with an unpatched release and do not weaken host-key validation as
a workaround.
