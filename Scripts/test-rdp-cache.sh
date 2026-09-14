#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENSURE="$ROOT/Scripts/ensure-rdp-dependencies.sh"
BUILDER="$ROOT/Scripts/build-rdp-dependencies.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/serverdash-rdp-cache-tests.XXXXXX")"

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_equal() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    [[ "$actual" == "$expected" ]] || fail "$message (expected '$expected', got '$actual')"
}

assert_exists() {
    [[ -e "$1" || -L "$1" ]] || fail "$2 ($1)"
}

assert_missing() {
    [[ ! -e "$1" && ! -L "$1" ]] || fail "$2 ($1)"
}

assert_artifact_payload_only() {
    local artifact="$1"
    local entries

    entries="$(find "$artifact" -mindepth 1 -maxdepth 1 -print \
        | sed 's#.*/##' \
        | LC_ALL=C sort \
        | paste -sd, -)"
    assert_equal \
        "Headers,ServerDashRDP.xcframework,build-manifest.json" \
        "$entries" \
        "cache artifact contains files outside the immutable payload"
}

assert_usage_record() {
    local cache="$1"
    local key="$2"
    local value

    assert_exists "$cache/usage/$key" "cache usage sidecar was not published"
    value="$(cat "$cache/usage/$key")"
    case "$value" in
        ''|*[!0-9]*) fail "cache usage sidecar is not a Unix timestamp ($cache/usage/$key)" ;;
    esac
}

assert_no_usage_staging_files() {
    local cache="$1"

    if find "$cache/usage" -maxdepth 1 -name '.last-used.*' -print | grep -q .; then
        fail "cache usage directory contains an unpublished staging file"
    fi
}

assert_cache_owned() {
    local cache="$1"
    assert_exists "$cache/.serverdash-rdp-cache-v1" "cache ownership marker was not created"
    assert_equal \
        "com.serverdash.app.native-rdp-cache-v1" \
        "$(cat "$cache/.serverdash-rdp-cache-v1")" \
        "cache ownership marker has unexpected content"
}

FAKE_BUILDER="$TEST_ROOT/fake-builder.sh"
FAKE_LIPO="$TEST_ROOT/fake-lipo.sh"
BUILD_COUNTER="$TEST_ROOT/build-counter"

cat > "$FAKE_BUILDER" <<'EOF'
#!/bin/bash
set -euo pipefail

if [[ "${FAKE_EXPECT_SANITIZED_ENV:-0}" == "1" ]]; then
    for variable_name in \
        DRIVERKIT_DEPLOYMENT_TARGET \
        IPHONEOS_DEPLOYMENT_TARGET \
        TVOS_DEPLOYMENT_TARGET \
        WATCHOS_DEPLOYMENT_TARGET \
        XROS_DEPLOYMENT_TARGET \
        XCODE_DEVELOPER_DIR_PATH \
        SWIFT_DEBUG_INFORMATION_FORMAT \
        SWIFT_DEBUG_INFORMATION_VERSION; do
        if [[ -n "${!variable_name+x}" ]]; then
            printf 'inherited Xcode variable was not removed: %s\n' "$variable_name" >&2
            exit 43
        fi
    done
    [[ "${MACOSX_DEPLOYMENT_TARGET:-}" == "14.0" ]] || exit 44
fi

printf '%s\n' "$$" >> "$FAKE_BUILD_COUNTER"
if [[ "${FAKE_BUILD_DELAY:-0}" != "0" ]]; then
    sleep "$FAKE_BUILD_DELAY"
fi

mkdir -p \
    "$RDP_OUTPUT_DIR/ServerDashRDP.xcframework/macos-arm64_x86_64/Headers" \
    "$RDP_OUTPUT_DIR/universal/Headers/freerdp3/freerdp" \
    "$RDP_OUTPUT_DIR/universal/Headers/winpr3/winpr" \
    "$RDP_OUTPUT_DIR/universal/Headers/openssl"

# Deliberately leave a partial output so failure cleanup and publication are tested.
if [[ "${FAKE_BUILD_FAIL:-0}" == "1" ]]; then
    printf 'partial' > "$RDP_OUTPUT_DIR/ServerDashRDP.xcframework/partial"
    exit 42
fi

if [[ "${FAKE_PAYLOAD_LEAK:-0}" == "1" ]]; then
    printf 'machine-local /Users/fixture/cache/.staging.bad/build path\n' \
        > "$RDP_OUTPUT_DIR/ServerDashRDP.xcframework/macos-arm64_x86_64/libServerDashRDP.a"
else
    printf 'fixture archive\n' > "$RDP_OUTPUT_DIR/ServerDashRDP.xcframework/macos-arm64_x86_64/libServerDashRDP.a"
fi
cat > "$RDP_OUTPUT_DIR/ServerDashRDP.xcframework/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>AvailableLibraries</key>
    <array>
        <dict>
            <key>HeadersPath</key>
            <string>Headers</string>
            <key>LibraryIdentifier</key>
            <string>macos-arm64_x86_64</string>
            <key>LibraryPath</key>
            <string>libServerDashRDP.a</string>
            <key>SupportedArchitectures</key>
            <array>
                <string>arm64</string>
                <string>x86_64</string>
            </array>
            <key>SupportedPlatform</key>
            <string>macos</string>
        </dict>
    </array>
</dict>
</plist>
PLIST
printf 'fixture\n' > "$RDP_OUTPUT_DIR/universal/Headers/freerdp3/freerdp/freerdp.h"
printf 'fixture\n' > "$RDP_OUTPUT_DIR/universal/Headers/winpr3/winpr/wtypes.h"
printf 'fixture\n' > "$RDP_OUTPUT_DIR/universal/Headers/openssl/ssl.h"
EOF

cat > "$FAKE_LIPO" <<'EOF'
#!/bin/bash
set -euo pipefail
[[ "$1" == "-archs" && -s "$2" ]]
printf '%s\n' "${FAKE_LIPO_ARCHITECTURES:-x86_64 arm64}"
EOF

chmod +x "$FAKE_BUILDER" "$FAKE_LIPO"
: > "$BUILD_COUNTER"

run_ensure() {
    local cache="$1"
    local worktree="$2"
    local toolchain="$3"
    shift 3
    env \
        SERVERDASH_RDP_CACHE_DIR="$cache" \
        _SERVERDASH_RDP_WORKTREE_DIR="$worktree" \
        _SERVERDASH_RDP_BUILDER="$FAKE_BUILDER" \
        _SERVERDASH_RDP_LIPO="$FAKE_LIPO" \
        _SERVERDASH_RDP_TEST_TOOLCHAIN_FINGERPRINT="$toolchain" \
        FAKE_BUILD_COUNTER="$BUILD_COUNTER" \
        /bin/bash "$ENSURE" "$@"
}

cache_key() {
    local toolchain="$1"
    env \
        _SERVERDASH_RDP_BUILDER="$FAKE_BUILDER" \
        _SERVERDASH_RDP_TEST_TOOLCHAIN_FINGERPRINT="$toolchain" \
        /bin/bash "$ENSURE" --print-key
}

build_count() {
    wc -l < "$BUILD_COUNTER" | tr -d '[:space:]'
}

artifact_count() {
    local cache="$1"
    local count=0
    local artifact
    for artifact in "$cache/artifacts"/*; do
        if [[ -d "$artifact" || -L "$artifact" ]]; then
            count=$((count + 1))
        fi
    done
    printf '%s\n' "$count"
}

CACHE="$TEST_ROOT/cache"
WORKTREE="$TEST_ROOT/worktree-rdp"
KEY_V1="$(cache_key fixture-v1)"
KEY_V2="$(cache_key fixture-v2)"
[[ "$KEY_V1" != "$KEY_V2" ]] || fail "toolchain fingerprint must affect the content key"

# Diagnostic mode must not create cache or worktree state.
READ_ONLY_CACHE="$TEST_ROOT/read-only-cache"
READ_ONLY_WORKTREE="$TEST_ROOT/read-only-worktree"
if run_ensure "$READ_ONLY_CACHE" "$READ_ONLY_WORKTREE" read-only --verify-only --quiet >/dev/null 2>&1; then
    fail "verify-only unexpectedly accepted a missing cache"
fi
assert_missing "$READ_ONLY_CACHE" "verify-only created the cache root"
assert_missing "$READ_ONLY_WORKTREE" "verify-only created worktree links"

# An unrelated non-empty directory can never be adopted as a cache root, and
# the lower-level producer refuses an unowned output directory before download.
UNOWNED_CACHE="$TEST_ROOT/unowned-cache"
mkdir -p "$UNOWNED_CACHE"
printf 'keep\n' > "$UNOWNED_CACHE/sentinel"
if run_ensure "$UNOWNED_CACHE" "$TEST_ROOT/unowned-worktree" unowned --quiet >/dev/null 2>&1; then
    fail "unowned non-empty cache root was accepted"
fi
assert_exists "$UNOWNED_CACHE/sentinel" "cache root rejection removed an unrelated file"
assert_missing "$UNOWNED_CACHE/artifacts" "cache root rejection created managed directories"

UNOWNED_OUTPUT="$TEST_ROOT/unowned-output"
mkdir -p "$UNOWNED_OUTPUT"
printf 'keep\n' > "$UNOWNED_OUTPUT/sentinel"
if env \
    RDP_BUILD_ROOT="$TEST_ROOT/builder-guard-build" \
    RDP_DOWNLOAD_CACHE="$TEST_ROOT/builder-guard-downloads" \
    RDP_OUTPUT_DIR="$UNOWNED_OUTPUT" \
    /bin/bash "$BUILDER" >/dev/null 2>&1; then
    fail "lower-level builder accepted an unowned output directory"
fi
assert_exists "$UNOWNED_OUTPUT/sentinel" "builder guard removed an unrelated file"

# An interrupted download must remove its private temporary and must never
# publish a partial archive into the shared, manifest-addressed download set.
INTERRUPTED_BUILD="$TEST_ROOT/interrupted-builder"
INTERRUPTED_DOWNLOADS="$TEST_ROOT/interrupted-downloads"
INTERRUPTED_OUTPUT="$TEST_ROOT/interrupted-output"
FAKE_CURL_DIRECTORY="$TEST_ROOT/interrupted-curl-bin"
mkdir -p "$FAKE_CURL_DIRECTORY"
cat > "$FAKE_CURL_DIRECTORY/curl" <<'EOF'
#!/bin/bash
set -euo pipefail
output=""
while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--output" && $# -ge 2 ]]; then
        output="$2"
        shift 2
    else
        shift
    fi
done
[[ -n "$output" ]]
printf 'interrupted archive bytes\n' > "$output"
exit 56
EOF
chmod +x "$FAKE_CURL_DIRECTORY/curl"
if env \
    PATH="$FAKE_CURL_DIRECTORY:$PATH" \
    RDP_BUILD_ROOT="$INTERRUPTED_BUILD" \
    RDP_DOWNLOAD_CACHE="$INTERRUPTED_DOWNLOADS" \
    RDP_OUTPUT_DIR="$INTERRUPTED_OUTPUT" \
    /bin/bash "$BUILDER" >/dev/null 2>&1; then
    fail "interrupted dependency download unexpectedly succeeded"
fi
if find "$INTERRUPTED_DOWNLOADS" -maxdepth 1 \
    \( -name '*.tar.gz' -o -name '.*.download.*' \) -print | grep -q .; then
    fail "interrupted dependency download left a partial or published archive"
fi

# Cold build publishes a JSON manifest, materializes only consumer links, and
# strips the unrelated platform settings inherited by an Xcode pre-action.
FAKE_EXPECT_SANITIZED_ENV=1 \
DRIVERKIT_DEPLOYMENT_TARGET=20.4 \
IPHONEOS_DEPLOYMENT_TARGET=18.0 \
TVOS_DEPLOYMENT_TARGET=15.6 \
WATCHOS_DEPLOYMENT_TARGET=8.7 \
XROS_DEPLOYMENT_TARGET=1.3 \
XCODE_DEVELOPER_DIR_PATH=relative-invalid-path \
SWIFT_DEBUG_INFORMATION_FORMAT=dwarf \
SWIFT_DEBUG_INFORMATION_VERSION=5 \
MACOSX_DEPLOYMENT_TARGET=10.13 \
    run_ensure "$CACHE" "$WORKTREE" fixture-v1 --quiet
assert_equal "1" "$(build_count)" "cold cache did not build exactly once"
assert_exists "$CACHE/artifacts/$KEY_V1/build-manifest.json" "manifest was not published"
assert_exists "$WORKTREE/ServerDashRDP.xcframework" "XCFramework link was not materialized"
assert_exists "$WORKTREE/universal/Headers" "header link was not materialized"
assert_exists "$WORKTREE/build-manifest.json" "manifest link was not materialized"
assert_equal "$KEY_V1" "$(/usr/bin/plutil -extract cacheKey raw -o - "$CACHE/artifacts/$KEY_V1/build-manifest.json")" "manifest cache key is wrong"
assert_artifact_payload_only "$CACHE/artifacts/$KEY_V1"
assert_usage_record "$CACHE" "$KEY_V1"
assert_no_usage_staging_files "$CACHE"
run_ensure "$CACHE" "$WORKTREE" fixture-v1 --verify-only --quiet

# A cache hit must skip the builder, even when that builder would fail if invoked.
FAKE_BUILD_FAIL=1 run_ensure "$CACHE" "$WORKTREE" fixture-v1 --quiet
assert_equal "1" "$(build_count)" "cache hit invoked the builder"

# Removing local links must be repaired without rebuilding the cached payload.
rm -rf "$WORKTREE"
run_ensure "$CACHE" "$WORKTREE" fixture-v1 --quiet
assert_cache_owned "$CACHE"
assert_equal "1" "$(build_count)" "link repair rebuilt the cached payload"
assert_exists "$WORKTREE/ServerDashRDP.xcframework" "link repair did not restore the XCFramework"

# Payload corruption must be detected and rebuilt.
printf 'corrupt\n' >> "$CACHE/artifacts/$KEY_V1/ServerDashRDP.xcframework/macos-arm64_x86_64/libServerDashRDP.a"
if run_ensure "$CACHE" "$WORKTREE" fixture-v1 --verify-only --quiet >/dev/null 2>&1; then
    fail "verify-only accepted a corrupted archive"
fi
run_ensure "$CACHE" "$WORKTREE" fixture-v1 --quiet
assert_equal "2" "$(build_count)" "corrupted cache was not rebuilt"
assert_artifact_payload_only "$CACHE/artifacts/$KEY_V1"
assert_usage_record "$CACHE" "$KEY_V1"
run_ensure "$CACHE" "$WORKTREE" fixture-v1 --verify-only --quiet

# Force mode always runs the source builder and leaves a fully verified entry.
run_ensure "$CACHE" "$WORKTREE" fixture-v1 --force-source-build --quiet
assert_equal "3" "$(build_count)" "force mode did not invoke the builder"
run_ensure "$CACHE" "$WORKTREE" fixture-v1 --verify-only --quiet

# Extra artifact entries and symlink substitutions must invalidate the otherwise
# correctly hashed payload rather than remaining eligible for a cache hit.
printf 'unexpected\n' > "$CACHE/artifacts/$KEY_V1/.last-used"
if run_ensure "$CACHE" "$WORKTREE" fixture-v1 --verify-only --quiet >/dev/null 2>&1; then
    fail "verify-only accepted an extra artifact entry"
fi
run_ensure "$CACHE" "$WORKTREE" fixture-v1 --quiet
assert_equal "4" "$(build_count)" "extra artifact entry did not trigger a rebuild"
assert_artifact_payload_only "$CACHE/artifacts/$KEY_V1"

# A failed builder may not publish a final entry or leave a staging directory.
FAILED_KEY="$(cache_key fixture-failure)"
FAILED_BUILD_LOG="$TEST_ROOT/failed-build.log"
if FAKE_BUILD_FAIL=1 run_ensure "$CACHE" "$TEST_ROOT/failure-worktree" fixture-failure --quiet >"$FAILED_BUILD_LOG" 2>&1; then
    fail "failing builder unexpectedly succeeded"
fi
if ! grep -Fq './Scripts/macos-dev.sh bootstrap' "$FAILED_BUILD_LOG"; then
    fail "failed source build did not provide the documented repair command"
fi
assert_missing "$CACHE/artifacts/$FAILED_KEY" "failed build published a cache entry"
assert_missing "$CACHE/usage/$FAILED_KEY" "failed build published a cache usage sidecar"
if find "$CACHE" -maxdepth 1 -name ".staging.$FAILED_KEY.*" -print | grep -q .; then
    fail "failed build left a staging directory"
fi

# A freshly built payload with a machine-local prefix must fail before publish.
LEAKED_KEY="$(cache_key fixture-leaked-prefix)"
if FAKE_PAYLOAD_LEAK=1 run_ensure "$CACHE" "$TEST_ROOT/leaked-worktree" fixture-leaked-prefix --quiet >/dev/null 2>&1; then
    fail "machine-local build path was published in a cache payload"
fi
assert_missing "$CACHE/artifacts/$LEAKED_KEY" "path-leaking build published a cache entry"
assert_missing "$CACHE/usage/$LEAKED_KEY" "path-leaking build published a usage sidecar"

# Two simultaneous requests for one key must serialize into one build.
CONCURRENT_CACHE="$TEST_ROOT/concurrent-cache"
CONCURRENT_COUNTER="$TEST_ROOT/concurrent-counter"
: > "$CONCURRENT_COUNTER"
env SERVERDASH_RDP_CACHE_DIR="$CONCURRENT_CACHE" _SERVERDASH_RDP_WORKTREE_DIR="$TEST_ROOT/concurrent-a" \
    _SERVERDASH_RDP_BUILDER="$FAKE_BUILDER" _SERVERDASH_RDP_LIPO="$FAKE_LIPO" \
    _SERVERDASH_RDP_TEST_TOOLCHAIN_FINGERPRINT=concurrent FAKE_BUILD_COUNTER="$CONCURRENT_COUNTER" \
    FAKE_BUILD_DELAY=1 /bin/bash "$ENSURE" --quiet &
PID_A=$!
env SERVERDASH_RDP_CACHE_DIR="$CONCURRENT_CACHE" _SERVERDASH_RDP_WORKTREE_DIR="$TEST_ROOT/concurrent-b" \
    _SERVERDASH_RDP_BUILDER="$FAKE_BUILDER" _SERVERDASH_RDP_LIPO="$FAKE_LIPO" \
    _SERVERDASH_RDP_TEST_TOOLCHAIN_FINGERPRINT=concurrent FAKE_BUILD_COUNTER="$CONCURRENT_COUNTER" \
    FAKE_BUILD_DELAY=1 /bin/bash "$ENSURE" --quiet &
PID_B=$!
wait "$PID_A"
wait "$PID_B"
assert_equal "1" "$(wc -l < "$CONCURRENT_COUNTER" | tr -d '[:space:]')" "concurrent ensure calls built more than once"

# Active worktree leases prevent a third concurrent toolchain cache from
# deleting payloads still referenced by an ongoing Xcode build.
run_ensure "$CACHE" "$TEST_ROOT/worktree-v2" fixture-v2 --quiet
sleep 1
run_ensure "$CACHE" "$WORKTREE" fixture-v1 --quiet
sleep 1
KEY_V3="$(cache_key fixture-v3)"
run_ensure "$CACHE" "$TEST_ROOT/worktree-v3" fixture-v3 --quiet
assert_equal "3" "$(artifact_count "$CACHE")" "active worktree lease did not preserve all referenced artifacts"
assert_exists "$CACHE/artifacts/$KEY_V2" "actively referenced cache was pruned"

# Once a prior worktree disappears, maintenance drops its stale lease and
# returns to the current payload plus the most recently used prior payload.
rm -rf "$TEST_ROOT/worktree-v2"
run_ensure "$CACHE" "$TEST_ROOT/worktree-v3" fixture-v3 --quiet
assert_equal "2" "$(artifact_count "$CACHE")" "cache retention did not keep exactly two artifacts"
assert_exists "$CACHE/artifacts/$KEY_V1" "most recently used prior artifact was pruned"
assert_exists "$CACHE/artifacts/$KEY_V3" "current artifact was pruned"
assert_missing "$CACHE/artifacts/$KEY_V2" "older artifact was retained"
assert_usage_record "$CACHE" "$KEY_V1"
assert_usage_record "$CACHE" "$KEY_V3"
assert_missing "$CACHE/usage/$KEY_V2" "pruned artifact retained its usage sidecar"
assert_artifact_payload_only "$CACHE/artifacts/$KEY_V1"
assert_artifact_payload_only "$CACHE/artifacts/$KEY_V3"
assert_no_usage_staging_files "$CACHE"

# A stale lease for the current cache key is removed even when there are no
# older artifacts that require reference checks during pruning.
STALE_CURRENT_WORKTREE="$TEST_ROOT/stale-current-worktree"
run_ensure "$CACHE" "$STALE_CURRENT_WORKTREE" fixture-v3 --quiet
STALE_CURRENT_LEASE_ID="$(printf '%s' "$STALE_CURRENT_WORKTREE" | shasum -a 256 | awk '{ print $1 }')"
assert_exists "$CACHE/leases/$STALE_CURRENT_LEASE_ID.json" "current-key worktree lease was not recorded"
rm -rf "$STALE_CURRENT_WORKTREE"
run_ensure "$CACHE" "$TEST_ROOT/worktree-v3" fixture-v3 --quiet
assert_missing "$CACHE/leases/$STALE_CURRENT_LEASE_ID.json" "stale current-key lease was retained"

# Bootstrap-only edits are informational and must not change the native cache key.
KEY_TEST_REPO="$TEST_ROOT/key-test-repo"
mkdir -p "$KEY_TEST_REPO/Scripts" "$KEY_TEST_REPO/Vendor/RDP"
cp "$ENSURE" "$KEY_TEST_REPO/Scripts/ensure-rdp-dependencies.sh"
cp "$FAKE_BUILDER" "$KEY_TEST_REPO/Scripts/build-rdp-dependencies.sh"
cp "$ROOT/Vendor/RDP/dependencies.sha256" "$KEY_TEST_REPO/Vendor/RDP/dependencies.sha256"
KEY_BEFORE="$(env _SERVERDASH_RDP_TEST_TOOLCHAIN_FINGERPRINT=key-test /bin/bash "$KEY_TEST_REPO/Scripts/ensure-rdp-dependencies.sh" --print-key)"
printf '\n# Informational bootstrap-only change.\n' >> "$KEY_TEST_REPO/Scripts/ensure-rdp-dependencies.sh"
KEY_AFTER="$(env _SERVERDASH_RDP_TEST_TOOLCHAIN_FINGERPRINT=key-test /bin/bash "$KEY_TEST_REPO/Scripts/ensure-rdp-dependencies.sh" --print-key)"
assert_equal "$KEY_BEFORE" "$KEY_AFTER" "bootstrap implementation hash changed the native cache key"

printf 'RDP cache tests passed.\n'
