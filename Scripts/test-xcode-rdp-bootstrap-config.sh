#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PROJECT_SPEC="${ROOT_DIR}/project.yml"
PROJECT_FILE="${ROOT_DIR}/ServerDash.xcodeproj/project.pbxproj"

fail() {
    printf 'Xcode RDP bootstrap configuration test failed: %s\n' "$*" >&2
    exit 1
}

expect_count() {
    local expected="$1"
    local pattern="$2"
    local file="$3"
    local actual

    actual="$(grep -F -c -- "$pattern" "$file" || true)"
    [[ "$actual" == "$expected" ]] || \
        fail "expected ${expected} occurrences of '${pattern}' in ${file}, found ${actual}"
}

if grep -Fq -- 'framework: .build/rdp/ServerDashRDP.xcframework' "$PROJECT_SPEC"; then
    fail 'project.yml must not register the ignored XCFramework as a build-graph dependency'
fi
if grep -Fq -- 'path = .build/rdp/ServerDashRDP.xcframework' "$PROJECT_FILE"; then
    fail 'the generated project must not contain an ignored XCFramework file reference'
fi

expect_count 2 '    preBuildScripts:' "$PROJECT_SPEC"
expect_count 2 'if ! /bin/bash "${SRCROOT}/Scripts/ensure-rdp-dependencies.sh" --verify-only' "$PROJECT_SPEC"
expect_count 2 '$(SRCROOT)/.build/rdp/ServerDashRDP.xcframework/macos-arm64_x86_64' "$PROJECT_SPEC"
expect_count 2 '          - -lServerDashRDP' "$PROJECT_SPEC"
expect_count 2 'name = "Prepare verified RDP dependencies";' "$PROJECT_FILE"
expect_count 4 '"$(SRCROOT)/.build/rdp/ServerDashRDP.xcframework/macos-arm64_x86_64",' "$PROJECT_FILE"
expect_count 4 '"-lServerDashRDP",' "$PROJECT_FILE"

printf 'Xcode RDP bootstrap configuration is self-starting and generated project settings match.\n'
