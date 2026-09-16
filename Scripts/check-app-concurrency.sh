#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

fail_configuration() {
    printf 'Invalid strict-concurrency configuration: %s\n' "$*" >&2
    exit 64
}

canonical_directory_path() {
    local label="$1"
    local candidate="$2"
    local existing component parent suffix=""

    [[ -n "${candidate}" ]] || fail_configuration "${label} must not be empty."
    if [[ "${candidate}" != /* ]]; then
        candidate="${ROOT_DIR}/${candidate}"
    fi
    while [[ "${candidate}" != "/" && "${candidate}" == */ ]]; do
        candidate="${candidate%/}"
    done
    case "/${candidate#/}/" in
        */../*) fail_configuration \
            "${label} must not contain '..' path components: ${candidate}" ;;
    esac

    existing="${candidate}"
    while [[ ! -e "${existing}" && ! -L "${existing}" ]]; do
        component="${existing##*/}"
        case "${component}" in
            ""|.) ;;
            *) suffix="/${component}${suffix}" ;;
        esac
        parent="${existing%/*}"
        existing="${parent:-/}"
        while [[ "${existing}" != "/" && "${existing}" == */ ]]; do
            existing="${existing%/}"
        done
    done
    [[ -d "${existing}" ]] || fail_configuration "${label} is not a directory path: ${candidate}"
    existing="$(cd "${existing}" && pwd -P)"
    printf '%s%s\n' "${existing}" "${suffix}"
}

if [[ -L "${ROOT_DIR}/.build" ]]; then
    fail_configuration "${ROOT_DIR}/.build must not be a symbolic link."
fi
if [[ -e "${ROOT_DIR}/.build" && ! -d "${ROOT_DIR}/.build" ]]; then
    fail_configuration "${ROOT_DIR}/.build must be a directory."
fi
if [[ "${SERVERDASH_DERIVED_DATA+x}" == "x" ]]; then
    [[ -n "${SERVERDASH_DERIVED_DATA}" ]] || \
        fail_configuration "SERVERDASH_DERIVED_DATA must not be empty."
fi

BUILD_ROOT="$(canonical_directory_path "Build root" "${ROOT_DIR}/.build")"
DERIVED_DATA="$(canonical_directory_path \
    "SERVERDASH_DERIVED_DATA" \
    "${SERVERDASH_DERIVED_DATA:-${BUILD_ROOT}/concurrency-gate}")"
case "${DERIVED_DATA}" in
    "${BUILD_ROOT}"/*) ;;
    *) fail_configuration \
        "Derived data must resolve below ${BUILD_ROOT}; received ${DERIVED_DATA}" ;;
esac
LOG_FILE="${SERVERDASH_BUILD_LOG:-${DERIVED_DATA}/build.log}"

case "${SERVERDASH_VERIFY_RDP_COLD_BOOTSTRAP:-0}" in
    0)
        "${ROOT_DIR}/Scripts/ensure-rdp-dependencies.sh" --verify-only >/dev/null 2>&1 || \
            "${ROOT_DIR}/Scripts/ensure-rdp-dependencies.sh" --quiet
        ;;
    1)
        # Remove only the ignored worktree links. The content-addressed cache stays
        # intact so the Xcode build itself must materialize and verify the links.
        rm -rf "${ROOT_DIR}/.build/rdp"
        ;;
    *)
        fail_configuration \
            "SERVERDASH_VERIFY_RDP_COLD_BOOTSTRAP must be 0 or 1."
        ;;
esac

if [[ "${REUSE_BUILD:-0}" != "1" ]]; then
    rm -rf "${DERIVED_DATA}"
fi
mkdir -p "${DERIVED_DATA}"
mkdir -p "$(dirname "${LOG_FILE}")"

set +e
xcodebuild \
    -project "${ROOT_DIR}/ServerDash.xcodeproj" \
    -scheme ServerDash \
    -configuration Debug \
    -destination "platform=macOS" \
    -derivedDataPath "${DERIVED_DATA}" \
    -skipPackagePluginValidation \
    -onlyUsePackageVersionsFromResolvedFile \
    -disableAutomaticPackageResolution \
    CODE_SIGNING_ALLOWED=NO \
    COMPILER_INDEX_STORE_ENABLE=NO \
    SWIFT_STRICT_CONCURRENCY=complete \
    build-for-testing >"${LOG_FILE}" 2>&1
BUILD_STATUS=$?
set -e

if [[ ${BUILD_STATUS} -ne 0 ]]; then
    echo "Strict-concurrency build failed. Last 80 log lines:" >&2
    tail -80 "${LOG_FILE}" >&2
    exit ${BUILD_STATUS}
fi

if [[ "${SERVERDASH_VERIFY_RDP_COLD_BOOTSTRAP:-0}" == "1" ]]; then
    "${ROOT_DIR}/Scripts/ensure-rdp-dependencies.sh" --verify-only --quiet
fi

set +e
xcodebuild \
    -project "${ROOT_DIR}/ServerDash.xcodeproj" \
    -scheme ServerDashGlassUITests \
    -configuration Debug \
    -destination "platform=macOS" \
    -derivedDataPath "${DERIVED_DATA}" \
    -skipPackagePluginValidation \
    -onlyUsePackageVersionsFromResolvedFile \
    -disableAutomaticPackageResolution \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGNING_ALLOWED=YES \
    COMPILER_INDEX_STORE_ENABLE=NO \
    SWIFT_STRICT_CONCURRENCY=complete \
    build-for-testing >>"${LOG_FILE}" 2>&1
QA_BUILD_STATUS=$?
set -e

if [[ ${QA_BUILD_STATUS} -ne 0 ]]; then
    echo "Strict-concurrency Mac QA build failed. Last 80 log lines:" >&2
    tail -80 "${LOG_FILE}" >&2
    exit ${QA_BUILD_STATUS}
fi

FIRST_PARTY_WARNINGS="${DERIVED_DATA}/first-party-warnings.txt"
awk -v root="${ROOT_DIR}/" '
    index($0, root "Sources/") || index($0, root "Tests/") || index($0, root "Native/") ||
    index($0, root "MacQA/") || index($0, root "ServerDashGlassUITests/") {
        start = index($0, root)
        relative = substr($0, start + length(root))
        path = relative
        sub(/:[0-9]+(:[0-9]+)?: warning:.*/, "", path)
        if (path ~ /^(Sources|Tests|Native|MacQA|ServerDashGlassUITests)\/.*\.(swift|m|mm|c|cc|cpp|h)$/ && $0 ~ /: warning:/) {
            print $0
        }
    }
    /^@__swiftmacro_.*ServerDash.*: warning:/ {
        print $0
    }
    /(^|[[:space:]"])(Sources|Tests|Native|MacQA|ServerDashGlassUITests)\/[^:]+\.(swift|m|mm|c|cc|cpp|h):[0-9]+(:[0-9]+)?: warning:/ {
        print $0
    }
' "${LOG_FILE}" | sort -u >"${FIRST_PARTY_WARNINGS}"

if [[ -s "${FIRST_PARTY_WARNINGS}" ]]; then
    echo "First-party compiler warnings found:" >&2
    cat "${FIRST_PARTY_WARNINGS}" >&2
    exit 1
fi

echo "Strict concurrency gate passed with zero first-party warnings."
awk '
    /: warning:/ {
        if ($0 ~ /\/Vendor\/SwiftTerm\//) swiftterm++
        else if ($0 ~ /\/Vendor\/ZIPFoundation\//) zipfoundation++
        else if ($0 ~ /\/(SourcePackages\/.*|Vendor\/)swift-nio-ssh\//) niossh++
        else if ($0 ~ /\/SourcePackages\/.*Citadel\// || $0 ~ /\/Vendor\/Citadel\//) citadel++
    }
    END {
        printf "Third-party warning instances in the Xcode log (informational): SwiftTerm=%d, ZIPFoundation=%d, NIOSSH=%d, Citadel=%d; FreeRDP/WinPR are recorded from the RDP bootstrap log.\n", swiftterm + 0, zipfoundation + 0, niossh + 0, citadel + 0
    }
' "${LOG_FILE}"
echo "Full log: ${LOG_FILE}"
