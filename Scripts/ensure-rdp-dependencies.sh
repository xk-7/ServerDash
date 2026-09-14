#!/bin/bash
set -euo pipefail

SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
RDP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RDP_BUILDER="${_SERVERDASH_RDP_BUILDER:-$RDP_ROOT/Scripts/build-rdp-dependencies.sh}"
RDP_DEPENDENCIES="$RDP_ROOT/Vendor/RDP/dependencies.sha256"
RDP_DEPLOYMENT_TARGET_VALUE="14.0"
RDP_ARCHITECTURES_VALUE="arm64,x86_64"
DEFAULT_RDP_CACHE_ROOT="$HOME/Library/Caches/com.serverdash.app/Native/RDP"
RDP_CACHE_ROOT="${SERVERDASH_RDP_CACHE_DIR:-$DEFAULT_RDP_CACHE_ROOT}"
RDP_WORKTREE_DIR="${_SERVERDASH_RDP_WORKTREE_DIR:-$RDP_ROOT/.build/rdp}"
RDP_LOCK_TIMEOUT="${SERVERDASH_RDP_LOCK_TIMEOUT_SECONDS:-1200}"
RDP_CACHE_MARKER_NAME=".serverdash-rdp-cache-v1"
RDP_CACHE_MARKER_VALUE="com.serverdash.app.native-rdp-cache-v1"

QUIET=0
VERIFY_ONLY=0
PRINT_KEY=0
FORCE_SOURCE_BUILD="${SERVERDASH_RDP_FORCE_SOURCE_BUILD:-0}"
ORIGINAL_ARGUMENTS=(ensure "$@")

usage() {
    cat <<'EOF'
Usage: Scripts/ensure-rdp-dependencies.sh [ensure] [options]

Options:
  --verify-only         Verify the current cache entry and worktree links.
  --print-key           Print the content cache key and exit.
  --force-source-build  Rebuild the current entry from pinned source archives.
  --quiet               Suppress informational output.
  -h, --help            Show this help.

Environment:
  SERVERDASH_RDP_CACHE_DIR             Override the shared cache root.
  SERVERDASH_RDP_FORCE_SOURCE_BUILD=1  Equivalent to --force-source-build.
  SERVERDASH_RDP_LOCK_TIMEOUT_SECONDS  Lock wait limit (default: 1200).
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        ensure) ;;
        --verify-only) VERIFY_ONLY=1 ;;
        --print-key) PRINT_KEY=1 ;;
        --force-source-build) FORCE_SOURCE_BUILD=1 ;;
        --quiet) QUIET=1 ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

case "$RDP_LOCK_TIMEOUT" in
    ''|*[!0-9]*)
        printf 'SERVERDASH_RDP_LOCK_TIMEOUT_SECONDS must be a non-negative integer.\n' >&2
        exit 2
        ;;
esac

# Shared-scheme pre-actions inherit deployment targets for every Apple
# platform. Clang interprets those variables as simultaneous target requests,
# and some Xcode tools warn about Swift-only debug settings. This bootstrap is
# a macOS-only process, so normalize its environment before invoking any tools.
unset \
    DRIVERKIT_DEPLOYMENT_TARGET \
    IPHONEOS_DEPLOYMENT_TARGET \
    TVOS_DEPLOYMENT_TARGET \
    WATCHOS_DEPLOYMENT_TARGET \
    XROS_DEPLOYMENT_TARGET \
    XCODE_DEVELOPER_DIR_PATH \
    SWIFT_DEBUG_INFORMATION_FORMAT \
    SWIFT_DEBUG_INFORMATION_VERSION
export MACOSX_DEPLOYMENT_TARGET="$RDP_DEPLOYMENT_TARGET_VALUE"

log() {
    if [[ "$QUIET" -eq 0 ]]; then
        printf '%s\n' "$*"
    fi
}

fail() {
    printf 'RDP dependency bootstrap failed: %s\n' "$*" >&2
    exit 1
}

sha256_file() {
    shasum -a 256 "$1" | awk '{ print $1 }'
}

sha256_text() {
    shasum -a 256 | awk '{ print $1 }'
}

[[ -f "$RDP_BUILDER" ]] || fail "build script is missing at $RDP_BUILDER"
[[ -f "$RDP_DEPENDENCIES" ]] || fail "dependency manifest is missing at $RDP_DEPENDENCIES"

DEPENDENCY_MANIFEST_SHA256="$(sha256_file "$RDP_DEPENDENCIES")"
BUILD_SCRIPT_SHA256="$(sha256_file "$RDP_BUILDER")"
BOOTSTRAP_SCRIPT_SHA256="$(sha256_file "$SCRIPT_PATH")"

if [[ -n "${_SERVERDASH_RDP_TEST_TOOLCHAIN_FINGERPRINT:-}" ]]; then
    XCODE_VERSION_TEXT="test-xcode"
    SWIFT_VERSION_TEXT="test-swift"
    SDK_VERSION_TEXT="test-sdk"
    SDK_BUILD_TEXT="test-sdk-build"
    TOOLCHAIN_DESCRIPTION="$_SERVERDASH_RDP_TEST_TOOLCHAIN_FINGERPRINT"
else
    command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild was not found; install or select Xcode first"
    command -v xcrun >/dev/null 2>&1 || fail "xcrun was not found; install or select Xcode first"
    XCODE_VERSION_TEXT="$(xcodebuild -version 2>&1 | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    # sed consumes the complete stream. `head` can terminate the producer with
    # SIGPIPE under Xcode scheme pre-actions, which is fatal with pipefail.
    SWIFT_VERSION_TEXT="$(xcrun swiftc --version 2>&1 | sed -n '1p')"
    SDK_VERSION_TEXT="$(xcrun --sdk macosx --show-sdk-version)"
    SDK_BUILD_TEXT="$(xcrun --sdk macosx --show-sdk-build-version 2>/dev/null || printf 'unknown')"
    TOOLCHAIN_DESCRIPTION="$XCODE_VERSION_TEXT|$SWIFT_VERSION_TEXT|macosx-$SDK_VERSION_TEXT-$SDK_BUILD_TEXT"
fi

TOOLCHAIN_SHA256="$(printf '%s' "$TOOLCHAIN_DESCRIPTION" | sha256_text)"
CONTENT_KEY="$(printf '%s\n' \
    "schema=1" \
    "dependencies=$DEPENDENCY_MANIFEST_SHA256" \
    "builder=$BUILD_SCRIPT_SHA256" \
    "toolchain=$TOOLCHAIN_SHA256" \
    "deployment=$RDP_DEPLOYMENT_TARGET_VALUE" \
    "architectures=$RDP_ARCHITECTURES_VALUE" | sha256_text)"

if [[ "$PRINT_KEY" -eq 1 ]]; then
    printf '%s\n' "$CONTENT_KEY"
    exit 0
fi

RDP_DOWNLOADS="$RDP_CACHE_ROOT/downloads"
RDP_DOWNLOAD_SET="$RDP_DOWNLOADS/$DEPENDENCY_MANIFEST_SHA256"
RDP_ARTIFACTS="$RDP_CACHE_ROOT/artifacts"
RDP_LOCKS="$RDP_CACHE_ROOT/locks"
RDP_USAGE="$RDP_CACHE_ROOT/usage"
RDP_LEASES="$RDP_CACHE_ROOT/leases"
RDP_ARTIFACT="$RDP_ARTIFACTS/$CONTENT_KEY"
RDP_LOCK_FILE="$RDP_LOCKS/$CONTENT_KEY.lock"
RDP_DOWNLOAD_LOCK_FILE="$RDP_LOCKS/download-$DEPENDENCY_MANIFEST_SHA256.lock"
RDP_MAINTENANCE_LOCK_FILE="$RDP_LOCKS/maintenance.lock"
RDP_LIPO="${_SERVERDASH_RDP_LIPO:-$(command -v lipo || true)}"

validate_cache_root_path() {
    local canonical_root
    local canonical_home
    local canonical_repository

    case "$RDP_CACHE_ROOT" in
        /*) ;;
        *) fail "SERVERDASH_RDP_CACHE_DIR must be an absolute path: $RDP_CACHE_ROOT" ;;
    esac
    [[ ! -L "$RDP_CACHE_ROOT" ]] || fail "cache root must not be a symbolic link: $RDP_CACHE_ROOT"
    [[ -d "$RDP_CACHE_ROOT" ]] || return 1

    canonical_root="$(cd "$RDP_CACHE_ROOT" && pwd -P)"
    canonical_home="$(cd "$HOME" && pwd -P)"
    canonical_repository="$(cd "$RDP_ROOT" && pwd -P)"
    case "$canonical_root" in
        /|"$canonical_home"|"$canonical_repository")
            fail "cache root resolves to an unsafe directory: $canonical_root"
            ;;
    esac
}

verify_cache_ownership() {
    local marker="$RDP_CACHE_ROOT/$RDP_CACHE_MARKER_NAME"
    local directory

    validate_cache_root_path || return 1
    [[ -f "$marker" && ! -L "$marker" ]] || return 1
    [[ "$(cat "$marker")" == "$RDP_CACHE_MARKER_VALUE" ]] || return 1
    for directory in downloads artifacts locks usage leases; do
        if [[ -e "$RDP_CACHE_ROOT/$directory" || -L "$RDP_CACHE_ROOT/$directory" ]]; then
            [[ -d "$RDP_CACHE_ROOT/$directory" && ! -L "$RDP_CACHE_ROOT/$directory" ]] || return 1
        fi
    done
}

initialize_cache_root() {
    local marker
    local marker_staging
    local entry
    local name

    case "$RDP_CACHE_ROOT" in
        /*) ;;
        *) fail "SERVERDASH_RDP_CACHE_DIR must be an absolute path: $RDP_CACHE_ROOT" ;;
    esac
    [[ ! -L "$RDP_CACHE_ROOT" ]] || fail "cache root must not be a symbolic link: $RDP_CACHE_ROOT"
    mkdir -p "$RDP_CACHE_ROOT"
    validate_cache_root_path || fail "cache root could not be initialized: $RDP_CACHE_ROOT"
    marker="$RDP_CACHE_ROOT/$RDP_CACHE_MARKER_NAME"

    if [[ ! -e "$marker" ]]; then
        for entry in "$RDP_CACHE_ROOT"/* "$RDP_CACHE_ROOT"/.[!.]* "$RDP_CACHE_ROOT"/..?*; do
            [[ -e "$entry" || -L "$entry" ]] || continue
            name="$(basename "$entry")"
            case "$name" in
                downloads|artifacts|locks|usage|leases|.cache-marker.*)
                    ;;
                *)
                    fail "cache root is non-empty and has no valid ownership marker: $RDP_CACHE_ROOT"
                    ;;
            esac
            case "$name" in
                downloads|artifacts|locks|usage|leases)
                    [[ -d "$entry" && ! -L "$entry" ]] || fail "cache directory is invalid: $entry"
                    ;;
            esac
        done

        marker_staging="$(mktemp "$RDP_CACHE_ROOT/.cache-marker.XXXXXX")"
        printf '%s\n' "$RDP_CACHE_MARKER_VALUE" > "$marker_staging"
        if ! ln "$marker_staging" "$marker" 2>/dev/null; then
            [[ -f "$marker" && ! -L "$marker" ]] || fail "cache ownership marker could not be initialized: $marker"
            [[ "$(cat "$marker")" == "$RDP_CACHE_MARKER_VALUE" ]] || fail "cache ownership marker has unexpected content: $marker"
        fi
        rm -f "$marker_staging"
    fi

    verify_cache_ownership || fail "cache ownership marker or managed directories are invalid: $RDP_CACHE_ROOT"
    mkdir -p "$RDP_DOWNLOADS" "$RDP_ARTIFACTS" "$RDP_LOCKS" "$RDP_USAGE" "$RDP_LEASES"
    verify_cache_ownership || fail "cache managed directories could not be initialized safely: $RDP_CACHE_ROOT"
}

plist_value() {
    /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null
}

tree_sha256() {
    local root="$1"
    (
        cd "$root"
        # Preserve the original path<TAB>hash manifest format while hashing
        # files in batches; this keeps existing verified cache entries valid.
        find . -type f -exec shasum -a 256 {} + \
            | awk '{
                hash = substr($0, 1, 64)
                path = substr($0, 67)
                if (substr(path, 1, 1) == "*") {
                    path = substr(path, 2)
                }
                print path "\t" hash
            }' \
            | LC_ALL=C sort
    ) | sha256_text
}

normalized_architectures() {
    printf '%s\n' $1 | LC_ALL=C sort | paste -sd, -
}

verify_structure() {
    local artifact="$1"
    local xcframework="$artifact/ServerDashRDP.xcframework"
    local headers="$artifact/Headers"
    local info="$xcframework/Info.plist"
    local identifier
    local library_path
    local archive
    local actual_architectures
    local plist_architectures
    local forbidden_paths_pattern
    local payload_symlinks

    [[ -f "$info" ]] || return 1
    /usr/bin/plutil -lint "$info" >/dev/null 2>&1 || return 1
    [[ "$(plist_value "$info" AvailableLibraries)" == "1" ]] || return 1
    [[ "$(plist_value "$info" AvailableLibraries.0.SupportedPlatform)" == "macos" ]] || return 1
    [[ "$(plist_value "$info" AvailableLibraries.0.SupportedArchitectures)" == "2" ]] || return 1
    plist_architectures="$(plist_value "$info" AvailableLibraries.0.SupportedArchitectures.0) $(plist_value "$info" AvailableLibraries.0.SupportedArchitectures.1)" || return 1
    [[ "$(normalized_architectures "$plist_architectures")" == "$RDP_ARCHITECTURES_VALUE" ]] || return 1

    identifier="$(plist_value "$info" AvailableLibraries.0.LibraryIdentifier)" || return 1
    library_path="$(plist_value "$info" AvailableLibraries.0.LibraryPath)" || return 1
    [[ "$library_path" == "libServerDashRDP.a" ]] || return 1
    archive="$xcframework/$identifier/$library_path"
    [[ -s "$archive" ]] || return 1

    [[ -n "$RDP_LIPO" && -x "$RDP_LIPO" ]] || return 1
    actual_architectures="$($RDP_LIPO -archs "$archive" 2>/dev/null)" || return 1
    [[ "$(normalized_architectures "$actual_architectures")" == "$RDP_ARCHITECTURES_VALUE" ]] || return 1

    [[ -f "$headers/freerdp3/freerdp/freerdp.h" ]] || return 1
    [[ -f "$headers/winpr3/winpr/wtypes.h" ]] || return 1
    [[ -f "$headers/openssl/ssl.h" ]] || return 1

    payload_symlinks="$(find "$xcframework" "$headers" -type l -print)"
    [[ -z "$payload_symlinks" ]] || return 1

    # Cache payloads must remain portable across users and worktrees. Stable
    # system paths such as /usr/lib are valid; machine-local build prefixes are
    # never valid in generated headers or the static archive.
    forbidden_paths_pattern='(/Users/|/private/(tmp|var/folders)/|/opt/homebrew/|/usr/local/|\.staging\.)'
    if /usr/bin/strings "$archive" | LC_ALL=C awk -v pattern="$forbidden_paths_pattern" '
        $0 ~ pattern { found = 1 }
        END { exit(found ? 0 : 1) }
    '; then
        return 1
    fi
    if LC_ALL=C grep -R -I -E "$forbidden_paths_pattern" "$headers" >/dev/null; then
        return 1
    fi
}

verify_payload() {
    local artifact="$1"
    local expected_key="$2"
    local manifest="$artifact/build-manifest.json"
    local xcframework_sha256
    local headers_sha256
    local archive_sha256
    local identifier
    local archive
    local entries

    [[ -d "$artifact" && ! -L "$artifact" ]] || return 1
    entries="$(find "$artifact" -mindepth 1 -maxdepth 1 -print \
        | sed 's#.*/##' \
        | LC_ALL=C sort \
        | paste -sd, -)"
    [[ "$entries" == "Headers,ServerDashRDP.xcframework,build-manifest.json" ]] || return 1
    [[ -f "$manifest" && ! -L "$manifest" ]] || return 1
    [[ -d "$artifact/Headers" && ! -L "$artifact/Headers" ]] || return 1
    [[ -d "$artifact/ServerDashRDP.xcframework" && ! -L "$artifact/ServerDashRDP.xcframework" ]] || return 1
    [[ "$(plist_value "$manifest" schemaVersion)" == "1" ]] || return 1
    [[ "$(plist_value "$manifest" cacheKey)" == "$expected_key" ]] || return 1
    verify_structure "$artifact" || return 1

    identifier="$(plist_value "$artifact/ServerDashRDP.xcframework/Info.plist" AvailableLibraries.0.LibraryIdentifier)" || return 1
    archive="$artifact/ServerDashRDP.xcframework/$identifier/libServerDashRDP.a"
    archive_sha256="$(sha256_file "$archive")"
    xcframework_sha256="$(tree_sha256 "$artifact/ServerDashRDP.xcframework")"
    headers_sha256="$(tree_sha256 "$artifact/Headers")"

    [[ "$(plist_value "$manifest" archiveSHA256)" == "$archive_sha256" ]] || return 1
    [[ "$(plist_value "$manifest" xcframeworkSHA256)" == "$xcframework_sha256" ]] || return 1
    [[ "$(plist_value "$manifest" headersSHA256)" == "$headers_sha256" ]] || return 1
}

verify_current_artifact() {
    local artifact="$1"
    local manifest="$artifact/build-manifest.json"

    verify_payload "$artifact" "$CONTENT_KEY" || return 1
    [[ "$(plist_value "$manifest" dependencyManifestSHA256)" == "$DEPENDENCY_MANIFEST_SHA256" ]] || return 1
    [[ "$(plist_value "$manifest" buildScriptSHA256)" == "$BUILD_SCRIPT_SHA256" ]] || return 1
    [[ "$(plist_value "$manifest" toolchainSHA256)" == "$TOOLCHAIN_SHA256" ]] || return 1
    [[ "$(plist_value "$manifest" deploymentTarget)" == "$RDP_DEPLOYMENT_TARGET_VALUE" ]] || return 1
    [[ "$(plist_value "$manifest" architectures)" == "$RDP_ARCHITECTURES_VALUE" ]] || return 1
}

write_manifest() {
    local artifact="$1"
    local info="$artifact/ServerDashRDP.xcframework/Info.plist"
    local identifier
    local archive
    local manifest="$artifact/build-manifest.json"

    identifier="$(plist_value "$info" AvailableLibraries.0.LibraryIdentifier)"
    archive="$artifact/ServerDashRDP.xcframework/$identifier/libServerDashRDP.a"

    /usr/bin/plutil -create xml1 "$manifest"
    /usr/bin/plutil -insert schemaVersion -integer 1 "$manifest"
    /usr/bin/plutil -insert cacheKey -string "$CONTENT_KEY" "$manifest"
    /usr/bin/plutil -insert createdAt -string "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$manifest"
    /usr/bin/plutil -insert dependencyManifestSHA256 -string "$DEPENDENCY_MANIFEST_SHA256" "$manifest"
    /usr/bin/plutil -insert buildScriptSHA256 -string "$BUILD_SCRIPT_SHA256" "$manifest"
    /usr/bin/plutil -insert bootstrapScriptSHA256 -string "$BOOTSTRAP_SCRIPT_SHA256" "$manifest"
    /usr/bin/plutil -insert toolchainSHA256 -string "$TOOLCHAIN_SHA256" "$manifest"
    /usr/bin/plutil -insert xcodeVersion -string "$XCODE_VERSION_TEXT" "$manifest"
    /usr/bin/plutil -insert swiftVersion -string "$SWIFT_VERSION_TEXT" "$manifest"
    /usr/bin/plutil -insert sdkVersion -string "$SDK_VERSION_TEXT" "$manifest"
    /usr/bin/plutil -insert sdkBuild -string "$SDK_BUILD_TEXT" "$manifest"
    /usr/bin/plutil -insert deploymentTarget -string "$RDP_DEPLOYMENT_TARGET_VALUE" "$manifest"
    /usr/bin/plutil -insert architectures -string "$RDP_ARCHITECTURES_VALUE" "$manifest"
    /usr/bin/plutil -insert archiveSHA256 -string "$(sha256_file "$archive")" "$manifest"
    /usr/bin/plutil -insert xcframeworkSHA256 -string "$(tree_sha256 "$artifact/ServerDashRDP.xcframework")" "$manifest"
    /usr/bin/plutil -insert headersSHA256 -string "$(tree_sha256 "$artifact/Headers")" "$manifest"
    /usr/bin/plutil -convert json "$manifest"
}

links_are_current() {
    [[ -L "$RDP_WORKTREE_DIR/ServerDashRDP.xcframework" ]] || return 1
    [[ -L "$RDP_WORKTREE_DIR/universal/Headers" ]] || return 1
    [[ -L "$RDP_WORKTREE_DIR/build-manifest.json" ]] || return 1
    [[ "$(readlink "$RDP_WORKTREE_DIR/ServerDashRDP.xcframework")" == "$RDP_ARTIFACT/ServerDashRDP.xcframework" ]] || return 1
    [[ "$(readlink "$RDP_WORKTREE_DIR/universal/Headers")" == "$RDP_ARTIFACT/Headers" ]] || return 1
    [[ "$(readlink "$RDP_WORKTREE_DIR/build-manifest.json")" == "$RDP_ARTIFACT/build-manifest.json" ]] || return 1
}

atomic_swap_paths() {
    local first="$1"
    local second="$2"
    local helper_dir
    local helper_source
    local helper_binary
    local status

    helper_dir="$(mktemp -d "$RDP_CACHE_ROOT/.atomic-swap.XXXXXX")" || return 1
    helper_source="$helper_dir/atomic-swap.c"
    helper_binary="$helper_dir/atomic-swap"
    cat > "$helper_source" <<'EOF'
#include <fcntl.h>
#include <stdio.h>
#include <sys/stdio.h>

int main(int argc, const char *argv[]) {
    if (argc != 3) {
        fprintf(stderr, "usage: atomic-swap <first> <second>\n");
        return 64;
    }
    if (renameatx_np(AT_FDCWD, argv[1], AT_FDCWD, argv[2], RENAME_SWAP) != 0) {
        perror("renameatx_np(RENAME_SWAP)");
        return 1;
    }
    return 0;
}
EOF
    if ! xcrun clang -Os -Wall -Wextra -Werror "$helper_source" -o "$helper_binary"; then
        rm -rf "$helper_dir"
        return 1
    fi
    if "$helper_binary" "$first" "$second"; then
        status=0
    else
        status=$?
    fi
    rm -rf "$helper_dir"
    return "$status"
}

materialize_worktree_links() {
    local parent
    local staging

    if links_are_current; then
        return
    fi

    parent="$(dirname "$RDP_WORKTREE_DIR")"
    mkdir -p "$parent"
    staging="$(mktemp -d "$parent/.rdp-links.XXXXXX")"
    mkdir -p "$staging/universal"
    ln -s "$RDP_ARTIFACT/ServerDashRDP.xcframework" "$staging/ServerDashRDP.xcframework"
    ln -s "$RDP_ARTIFACT/Headers" "$staging/universal/Headers"
    ln -s "$RDP_ARTIFACT/build-manifest.json" "$staging/build-manifest.json"

    if [[ -e "$RDP_WORKTREE_DIR" || -L "$RDP_WORKTREE_DIR" ]]; then
        if ! atomic_swap_paths "$staging" "$RDP_WORKTREE_DIR"; then
            rm -rf "$staging"
            return 1
        fi
        rm -rf "$staging"
    elif ! mv "$staging" "$RDP_WORKTREE_DIR"; then
        rm -rf "$staging"
        return 1
    fi
    log "Materialized RDP dependency links in $RDP_WORKTREE_DIR"
}

STAGING_ROOT=""
cleanup_staging() {
    if [[ -n "$STAGING_ROOT" && -d "$STAGING_ROOT" ]]; then
        rm -rf "$STAGING_ROOT"
    fi
}
trap cleanup_staging EXIT

publish_candidate() {
    local candidate="$1"

    if [[ -e "$RDP_ARTIFACT" || -L "$RDP_ARTIFACT" ]]; then
        if ! atomic_swap_paths "$candidate" "$RDP_ARTIFACT"; then
            return 1
        fi
        rm -rf "$candidate"
    elif ! mv "$candidate" "$RDP_ARTIFACT"; then
        return 1
    fi
}

build_current_artifact() {
    local build_root
    local output_root
    local candidate

    STAGING_ROOT="$(mktemp -d "$RDP_CACHE_ROOT/.staging.$CONTENT_KEY.XXXXXX")"
    build_root="$STAGING_ROOT/build"
    output_root="$STAGING_ROOT/output"
    candidate="$STAGING_ROOT/artifact"
    mkdir -p "$build_root" "$output_root" "$candidate"

    log "Building pinned RDP dependencies for cache key $CONTENT_KEY"
    if /usr/bin/lockf -k -t "$RDP_LOCK_TIMEOUT" "$RDP_DOWNLOAD_LOCK_FILE" \
        /usr/bin/env \
            RDP_BUILD_ROOT="$build_root" \
            RDP_DOWNLOAD_CACHE="$RDP_DOWNLOAD_SET" \
            RDP_OUTPUT_DIR="$output_root" \
            RDP_DEPLOYMENT_TARGET="$RDP_DEPLOYMENT_TARGET_VALUE" \
            RDP_ARCHITECTURES="arm64 x86_64" \
            /bin/bash "$RDP_BUILDER"; then
        :
    else
        builder_status=$?
        if [[ "$builder_status" -eq 75 ]]; then
            fail "timed out after ${RDP_LOCK_TIMEOUT}s waiting for dependency download set $DEPENDENCY_MANIFEST_SHA256"
        fi
        fail "source build exited with status ${builder_status}. Check network access, then retry with: ./Scripts/macos-dev.sh bootstrap"
    fi

    [[ -d "$output_root/ServerDashRDP.xcframework" ]] || fail "builder did not produce ServerDashRDP.xcframework"
    [[ -d "$output_root/universal/Headers" ]] || fail "builder did not produce universal headers"
    mv "$output_root/ServerDashRDP.xcframework" "$candidate/ServerDashRDP.xcframework"
    mv "$output_root/universal/Headers" "$candidate/Headers"

    verify_structure "$candidate" || fail "newly built RDP payload failed structural validation"
    write_manifest "$candidate"
    verify_current_artifact "$candidate" || fail "newly built RDP payload failed manifest or hash validation"
    publish_candidate "$candidate" || fail "could not atomically publish RDP cache entry"
    log "Published RDP dependency cache: $RDP_ARTIFACT"

    rm -rf "$STAGING_ROOT"
    STAGING_ROOT=""
}

remove_artifact_if_unlocked() {
    local key="$1"
    local artifact="$2"
    local lock_file="$RDP_LOCKS/$key.lock"

    if /usr/bin/lockf -k -t 0 "$lock_file" /bin/rm -rf "$artifact" >/dev/null 2>&1; then
        rm -f "$RDP_USAGE/$key"
        return 0
    fi
    return 1
}

valid_content_name() {
    [[ ${#1} -eq 64 && "$1" != *[!0-9a-f]* ]]
}

write_worktree_lease() {
    local lease_id
    local lease
    local staging

    lease_id="$(printf '%s' "$RDP_WORKTREE_DIR" | sha256_text)"
    lease="$RDP_LEASES/$lease_id.json"
    staging="$(mktemp "$RDP_LEASES/.lease.$lease_id.XXXXXX")"
    /usr/bin/plutil -create xml1 "$staging"
    /usr/bin/plutil -insert schemaVersion -integer 1 "$staging"
    /usr/bin/plutil -insert cacheKey -string "$CONTENT_KEY" "$staging"
    /usr/bin/plutil -insert worktreeRDPDirectory -string "$RDP_WORKTREE_DIR" "$staging"
    /usr/bin/plutil -convert json "$staging"
    mv -f "$staging" "$lease"
}

cleanup_stale_leases() {
    local lease
    local lease_key
    local lease_worktree

    for lease in "$RDP_LEASES"/*.json; do
        [[ -e "$lease" || -L "$lease" ]] || continue
        if [[ ! -f "$lease" || -L "$lease" ]]; then
            rm -f "$lease"
            continue
        fi
        lease_key="$(plist_value "$lease" cacheKey || true)"
        lease_worktree="$(plist_value "$lease" worktreeRDPDirectory || true)"
        if [[ -z "$lease_key" || -z "$lease_worktree" \
            || ! -L "$lease_worktree/ServerDashRDP.xcframework" \
            || "$(readlink "$lease_worktree/ServerDashRDP.xcframework")" \
                != "$RDP_ARTIFACTS/$lease_key/ServerDashRDP.xcframework" ]]; then
            rm -f "$lease"
            continue
        fi
    done
}

artifact_is_referenced() {
    local key="$1"
    local lease
    local lease_key
    local expected_target="$RDP_ARTIFACTS/$key/ServerDashRDP.xcframework"
    local registered_worktree
    local registered_link

    cleanup_stale_leases
    for lease in "$RDP_LEASES"/*.json; do
        [[ -f "$lease" && ! -L "$lease" ]] || continue
        lease_key="$(plist_value "$lease" cacheKey || true)"
        [[ "$lease_key" == "$key" ]] && return 0
    done

    # Preserve links created before lease sidecars existed and worktrees that
    # are registered by this repository but have not run the new bootstrap yet.
    while IFS= read -r registered_worktree; do
        registered_link="$registered_worktree/.build/rdp/ServerDashRDP.xcframework"
        if [[ -L "$registered_link" && "$(readlink "$registered_link")" == "$expected_target" ]]; then
            return 0
        fi
    done < <(git -C "$RDP_ROOT" worktree list --porcelain 2>/dev/null \
        | awk '/^worktree / { sub(/^worktree /, ""); print }')
    return 1
}

update_usage_record() {
    local usage_file
    local value
    local maximum=0
    local candidate
    local staging

    rm -f "$RDP_USAGE"/.last-used.* "$RDP_LEASES"/.lease.* 2>/dev/null || true
    for usage_file in "$RDP_USAGE"/*; do
        [[ -f "$usage_file" && ! -L "$usage_file" ]] || continue
        value="$(cat "$usage_file" 2>/dev/null || printf '0')"
        case "$value" in ''|*[!0-9]*) value=0 ;; esac
        if [[ "$value" -gt "$maximum" ]]; then
            maximum="$value"
        fi
    done
    candidate=$(( $(date +%s) * 1000000 ))
    if [[ "$candidate" -le "$maximum" ]]; then
        candidate=$((maximum + 1))
    fi
    staging="$(mktemp "$RDP_USAGE/.last-used.$CONTENT_KEY.XXXXXX")"
    printf '%s\n' "$candidate" > "$staging"
    mv -f "$staging" "$RDP_USAGE/$CONTENT_KEY"
}

prune_artifacts() {
    local artifact
    local key
    local last_used
    local newest_other=""
    local newest_timestamp=-1

    for artifact in "$RDP_ARTIFACTS"/*; do
        [[ -d "$artifact" || -L "$artifact" ]] || continue
        key="$(basename "$artifact")"
        valid_content_name "$key" || continue
        [[ "$key" != "$CONTENT_KEY" ]] || continue
        if verify_payload "$artifact" "$key"; then
            last_used="$(cat "$RDP_USAGE/$key" 2>/dev/null || printf '0')"
            case "$last_used" in ''|*[!0-9]*) last_used=0 ;; esac
            if [[ "$last_used" -gt "$newest_timestamp" ]]; then
                newest_timestamp="$last_used"
                newest_other="$key"
            fi
        elif ! artifact_is_referenced "$key"; then
            remove_artifact_if_unlocked "$key" "$artifact" || true
        fi
    done

    for artifact in "$RDP_ARTIFACTS"/*; do
        [[ -d "$artifact" || -L "$artifact" ]] || continue
        key="$(basename "$artifact")"
        valid_content_name "$key" || continue
        [[ "$key" == "$CONTENT_KEY" || "$key" == "$newest_other" ]] && continue
        artifact_is_referenced "$key" && continue
        remove_artifact_if_unlocked "$key" "$artifact" || true
    done

    for last_used in "$RDP_USAGE"/*; do
        [[ -f "$last_used" && ! -L "$last_used" ]] || continue
        key="$(basename "$last_used")"
        valid_content_name "$key" || continue
        [[ -e "$RDP_ARTIFACTS/$key" || -L "$RDP_ARTIFACTS/$key" ]] || rm -f "$last_used"
    done
}

download_set_is_needed() {
    local dependency_key="$1"
    local artifact
    local manifest_dependency

    [[ "$dependency_key" == "$DEPENDENCY_MANIFEST_SHA256" ]] && return 0
    for artifact in "$RDP_ARTIFACTS"/*; do
        [[ -d "$artifact" && ! -L "$artifact" ]] || continue
        manifest_dependency="$(plist_value "$artifact/build-manifest.json" dependencyManifestSHA256 || true)"
        [[ "$manifest_dependency" == "$dependency_key" ]] && return 0
    done
    return 1
}

prune_download_sets() {
    local download_set
    local dependency_key
    local lock_file

    for download_set in "$RDP_DOWNLOADS"/*; do
        [[ -d "$download_set" && ! -L "$download_set" ]] || continue
        dependency_key="$(basename "$download_set")"
        valid_content_name "$dependency_key" || continue
        download_set_is_needed "$dependency_key" && continue
        lock_file="$RDP_LOCKS/download-$dependency_key.lock"
        /usr/bin/lockf -k -t 0 "$lock_file" /bin/rm -rf "$download_set" >/dev/null 2>&1 || true
    done
}

run_maintenance() {
    update_usage_record
    write_worktree_lease
    cleanup_stale_leases
    prune_artifacts
    prune_download_sets
}

if [[ "${_SERVERDASH_RDP_MAINTENANCE_ONLY:-}" == "$CONTENT_KEY" ]]; then
    verify_cache_ownership || fail "cache ownership is missing or invalid: $RDP_CACHE_ROOT"
    verify_current_artifact "$RDP_ARTIFACT" || fail "cache entry changed before maintenance: $CONTENT_KEY"
    run_maintenance
    exit 0
fi

if [[ "$VERIFY_ONLY" -eq 1 ]]; then
    verify_cache_ownership || fail "cache ownership is missing or invalid: $RDP_CACHE_ROOT"
    verify_current_artifact "$RDP_ARTIFACT" || fail "cache entry $CONTENT_KEY is missing, stale, or corrupt"
    links_are_current || fail "worktree RDP links are missing or point at a different cache entry"
    log "RDP dependency cache verified: $CONTENT_KEY"
    exit 0
fi

initialize_cache_root

if [[ "${_SERVERDASH_RDP_LOCK_HELD:-}" != "$CONTENT_KEY" ]]; then
    export _SERVERDASH_RDP_LOCK_HELD="$CONTENT_KEY"
    if /usr/bin/lockf -k -t "$RDP_LOCK_TIMEOUT" "$RDP_LOCK_FILE" /bin/bash "$SCRIPT_PATH" "${ORIGINAL_ARGUMENTS[@]}"; then
        exit 0
    else
        lock_status=$?
    fi
    if [[ "$lock_status" -eq 75 ]]; then
        fail "timed out after ${RDP_LOCK_TIMEOUT}s waiting for cache lock $RDP_LOCK_FILE"
    fi
    exit "$lock_status"
fi

if [[ "$FORCE_SOURCE_BUILD" == "1" ]] || ! verify_current_artifact "$RDP_ARTIFACT"; then
    build_current_artifact
    verify_current_artifact "$RDP_ARTIFACT" || fail "published cache entry did not pass final verification"
else
    log "Using verified RDP dependency cache: $CONTENT_KEY"
fi

materialize_worktree_links || fail "could not materialize worktree RDP links"
export _SERVERDASH_RDP_MAINTENANCE_ONLY="$CONTENT_KEY"
if /usr/bin/lockf -k -t "$RDP_LOCK_TIMEOUT" "$RDP_MAINTENANCE_LOCK_FILE" \
    /bin/bash "$SCRIPT_PATH" --quiet; then
    :
else
    maintenance_status=$?
    if [[ "$maintenance_status" -eq 75 ]]; then
        fail "timed out after ${RDP_LOCK_TIMEOUT}s waiting for cache maintenance"
    fi
    exit "$maintenance_status"
fi

log "RDP dependencies are ready: $RDP_ARTIFACT"
