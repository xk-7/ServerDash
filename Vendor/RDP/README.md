# Pinned native RDP dependencies

macOS only. The application links a local static universal XCFramework; it never
launches an external RDP client or passes passwords through command-line arguments.

## Provenance

- FreeRDP and WinPR **3.31.0**, tag `3.31.0`, source commit
  `aa8650b300aa4cabd85d9c72b431301509b9043f`. Official release archive:
  https://pub.freerdp.com/releases/freerdp-3.31.0.tar.gz
- OpenSSL **3.5.8**, tag `openssl-3.5.8`, source commit
  `f4dc4d58b48d346a8270183f89acf826d459b0ca`. Official release archive:
  https://github.com/openssl/openssl/releases/download/openssl-3.5.8/openssl-3.5.8.tar.gz
- Build tool CMake **3.31.12**, official universal macOS archive. CMake is not
  distributed inside the app. Xcode and the macOS SDK are supplied by the builder.

`dependencies.sha256` contains the pinned official archive SHA-256 values.
GitHub tag metadata was checked on 2026-09-08; archive hashes are checked on every
dependency build. The OpenSSL GitHub tag reports an unknown signing key on GitHub;
we do not claim independent PGP verification. Downloads use HTTPS and pinned hashes.

## Security decision

The originally proposed 3.30.0 is **not used**. With the user's approval, the
baseline was updated to the [3.31.0 security release](https://github.com/FreeRDP/FreeRDP/releases/tag/3.31.0),
including fixes for [negotiation heap overflow](https://github.com/FreeRDP/FreeRDP/security/advisories/GHSA-r9pv-ffph-6gg6),
[NSCodec invalid data](https://github.com/FreeRDP/FreeRDP/security/advisories/GHSA-ffjr-p229-hpch)
and [AVC444 processing](https://github.com/FreeRDP/FreeRDP/security/advisories/GHSA-m85m-3qxv-63h5).
This is a dated review, not a promise of freedom from unknown vulnerabilities.
Recheck upstream advisories before distributing an RDP-enabled release.

There are no downstream edits to the downloaded FreeRDP/WinPR/OpenSSL sources.
ServerDash's Objective-C bridge, restricted drive service and clipboard service
are in `Native/` and `Sources/RDP*.swift`; they replace the upstream Mac client,
not the RDP protocol library. TLS 1.2+ and NLA are required. Debug logging,
automatic certificate acceptance, old RDP/TLS-only login, gateways and redirection
to a different target are disabled. Only a cryptographically valid self-signed
certificate may be accepted manually, after date checks and fingerprint review.

## Reproducible build procedure

From the repository root:

```sh
bash Scripts/build-rdp-dependencies.sh
xcodegen generate
```

The script downloads archives to `.build/rdp/downloads`, extracts sources under
`.build/rdp/sources`, compiles arm64 and x86_64 for macOS 14, merges static
archives and creates `.build/rdp/ServerDashRDP.xcframework`. Generated files are
ignored by Git. For a clean verification, run in a fresh checkout; incremental
builds reuse the extracted source trees and OpenSSL archives. This is a pinned
source/build recipe, not a claim of byte-identical output across Xcode versions.

Important build choices: static libraries, LTO disabled, client common/channels
enabled, standalone clients/servers disabled, Mac Audio enabled. Optional
Homebrew JSON/FFmpeg/H.264/JPEG/Opus/URI/Kerberos/CUPS/PCSC/FUSE integrations,
microphone/printer/smart-card/USB/video channels and native protocol debug output
are disabled. JSON is explicitly disabled to avoid ambient Homebrew linkage.
Runtime uses Apple's frameworks plus statically linked OpenSSL/FreeRDP/WinPR;
Homebrew is not a runtime dependency.

## Licenses

FreeRDP/WinPR and OpenSSL use Apache-2.0; full license texts are preserved here.
The WinPR bundled CPU-feature implementation's notice is also retained. These
files are copied into the macOS app's resources. Original source archives retain
all per-file copyright and license notices. The app's own adapter code does not
change upstream licensing.
