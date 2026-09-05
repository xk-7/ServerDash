# Third-Party Notices

## Mobile SSH dependencies

ServerDash vendors the following source packages for the native iPhone/iPad SSH
implementation:

- Citadel 0.12.1, upstream commit
  `ae8562f895de06ccb86fdb1cbb65fd99c8976e12`, © 2022 Orlandos, MIT License.
  The complete license is preserved at `Vendor/Citadel/LICENSE`.
- swift-nio-ssh fork 0.3.6, upstream commit
  `a05e6bbe6b141ee68da3030e00275504c0595d4d`, based on the SwiftNIO SSH
  project, Apache License 2.0. The complete license is preserved at
  `Vendor/swift-nio-ssh/LICENSE.txt`.

ServerDash changes Citadel's package manifest to resolve the local NIOSSH copy,
removes its unused server example dependency, and annotates its immutable
algorithm-metatype containers for Swift concurrency compatibility. ServerDash
changes NIOSSH's package manifest to omit the documentation plugin from
application builds and backports Apple's security fix
`31cdc3c3391a10460dedf1170530cf651d2ca496` for
[GHSA-998x-vgvp-xwpc](https://github.com/apple/swift-nio-ssh/security/advisories/GHSA-998x-vgvp-xwpc).
Patch provenance and verification commands are recorded in
`Vendor/SECURITY_PATCHES.md`.

SwiftTerm 1.11.2 remains vendored under its existing license and notices in
`Vendor/SwiftTerm`.

## Apple-native design guidance

ServerDash's Apple-native design rules were adapted from
[naplesblue/apple-design-skill](https://github.com/naplesblue/apple-design-skill).
Everything else in that design skill is © 2026 naplesblue and distributed under the MIT License.
ServerDash does not copy its Lucide icon paths and uses native SF Symbols instead.

## MIT License

Copyright (c) 2026 naplesblue

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

Not affiliated with or endorsed by Apple Inc. Apple, macOS, and related marks
belong to Apple Inc. No Apple assets are included.
