#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
EXPECTED_VERSION=""
REQUIRE_CLEAN=0
REQUIRE_MAIN=0
CHECK_GENERATED=1
ERROR_COUNT=0
WARNING_COUNT=0
GENERATED_CHECK_ROOT=""

cleanup_generated_check() {
    if [[ -n "${GENERATED_CHECK_ROOT}" && -d "${GENERATED_CHECK_ROOT}" ]]; then
        rm -rf "${GENERATED_CHECK_ROOT}"
    fi
}
trap cleanup_generated_check EXIT

usage() {
    cat <<'EOF'
Usage: ./Scripts/dev-doctor.sh [options]

Checks the current Apple development worktree without changing it.

Options:
  --release VERSION       Require a clean main/tag release context and matching metadata.
  --expect-version VALUE  Require project.yml to use VALUE for every app target.
  --require-clean         Fail when tracked or untracked files are present.
  --require-main          Require main, or detached HEAD at the matching release tag.
  --skip-generated-check  Skip the temporary XcodeGen drift check.
  -h, --help              Show this help.

Diagnostic overrides (must be set explicitly to 1):
  SERVERDASH_ALLOW_DIRTY=1
  SERVERDASH_ALLOW_STALE_BASE=1
  SERVERDASH_ALLOW_NONRELEASE_BRANCH=1
  SERVERDASH_ALLOW_DETACHED=1
  SERVERDASH_ALLOW_WINDOWS_BRANCH=1
  SERVERDASH_ALLOW_LEGACY_WORKTREE=1
EOF
}

fail_check() {
    ERROR_COUNT=$((ERROR_COUNT + 1))
    printf 'ERROR: %s\n' "$*" >&2
}

warn_check() {
    WARNING_COUNT=$((WARNING_COUNT + 1))
    printf 'WARNING: %s\n' "$*" >&2
}

require_override_or_fail() {
    override_name="$1"
    shift
    override_value="${!override_name:-0}"
    if [[ "${override_value}" == "1" ]]; then
        warn_check "$* (${override_name}=1 override active)"
    else
        fail_check "$* Set ${override_name}=1 only for an intentional diagnostic build."
    fi
}

unique_yaml_values() {
    key="$1"
    awk -v key="${key}" '
        $1 == key ":" {
            value = $2
            gsub(/^[\047\042]|[\047\042]$/, "", value)
            print value
        }
    ' "${ROOT_DIR}/project.yml" | sort -u
}

check_generated_project() {
    if ! command -v xcodegen >/dev/null 2>&1; then
        fail_check "XcodeGen is unavailable; install version 2.45.4."
        return
    fi

    xcodegen_version="$(xcodegen --version 2>/dev/null | awk '{print $NF}')"
    if [[ "${xcodegen_version}" != "2.45.4" ]]; then
        fail_check "XcodeGen 2.45.4 is required; found ${xcodegen_version:-unknown}."
        return
    fi

    GENERATED_CHECK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/serverdash-xcodegen-check.XXXXXX")"
    generated_root="${GENERATED_CHECK_ROOT}"
    cp "${ROOT_DIR}/project.yml" "${generated_root}/project.yml"
    for item in Sources Native Vendor Resources Tests MacUITests Mobile; do
        ln -s "${ROOT_DIR}/${item}" "${generated_root}/${item}"
    done

    if ! xcodegen \
        --spec "${generated_root}/project.yml" \
        --project "${generated_root}" \
        --project-root "${generated_root}" \
        --cache-path "${generated_root}/cache" \
        --quiet; then
        rm -rf "${generated_root}"
        GENERATED_CHECK_ROOT=""
        fail_check "XcodeGen could not regenerate the project in an isolated directory."
        return
    fi

    generated_project="${generated_root}/ServerDash.xcodeproj"
    if ! diff -q \
        "${ROOT_DIR}/ServerDash.xcodeproj/project.pbxproj" \
        "${generated_project}/project.pbxproj" >/dev/null 2>&1 \
        || ! diff -rq \
        "${ROOT_DIR}/ServerDash.xcodeproj/xcshareddata/xcschemes" \
        "${generated_project}/xcshareddata/xcschemes" >/dev/null 2>&1; then
        rm -rf "${generated_root}"
        GENERATED_CHECK_ROOT=""
        fail_check "ServerDash.xcodeproj has drifted from project.yml; regenerate and review it with xcodegen generate."
        return
    fi

    rm -rf "${generated_root}"
    GENERATED_CHECK_ROOT=""
    printf 'Xcode project: generated files match project.yml\n'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release)
            if [[ $# -lt 2 ]]; then
                echo "--release requires a version" >&2
                exit 2
            fi
            EXPECTED_VERSION="$2"
            REQUIRE_CLEAN=1
            REQUIRE_MAIN=1
            shift 2
            ;;
        --expect-version)
            if [[ $# -lt 2 ]]; then
                echo "--expect-version requires a value" >&2
                exit 2
            fi
            EXPECTED_VERSION="$2"
            shift 2
            ;;
        --require-clean)
            REQUIRE_CLEAN=1
            shift
            ;;
        --require-main)
            REQUIRE_MAIN=1
            shift
            ;;
        --skip-generated-check)
            CHECK_GENERATED=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ -n "${EXPECTED_VERSION}" && ! "${EXPECTED_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Version must use numeric MAJOR.MINOR.PATCH form; received ${EXPECTED_VERSION}." >&2
    exit 2
fi

for tool in git awk sort diff mktemp; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        fail_check "Required tool is unavailable: ${tool}"
    fi
done

if [[ ! -f "${ROOT_DIR}/project.yml" || ! -d "${ROOT_DIR}/ServerDash.xcodeproj" ]]; then
    fail_check "Run this script from a complete ServerDash checkout."
fi

if ! git -C "${ROOT_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    fail_check "${ROOT_DIR} is not a Git worktree."
fi

if [[ "${ERROR_COUNT}" -gt 0 ]]; then
    exit 1
fi

WORKTREE_ROOT="$(git -C "${ROOT_DIR}" rev-parse --show-toplevel)"
BRANCH="$(git -C "${ROOT_DIR}" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
HEAD_SHA="$(git -C "${ROOT_DIR}" rev-parse HEAD)"
SHORT_SHA="$(git -C "${ROOT_DIR}" rev-parse --short=12 HEAD)"
PRIMARY_WORKTREE="$(git -C "${ROOT_DIR}" worktree list --porcelain | awk '/^worktree / { sub(/^worktree /, ""); print; exit }')"
PRIMARY_BRANCH="$(git -C "${PRIMARY_WORKTREE}" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"

if [[ -z "${BRANCH}" ]]; then
    DISPLAY_BRANCH="detached HEAD"
else
    DISPLAY_BRANCH="${BRANCH}"
fi

printf 'Repository: %s\n' "${ROOT_DIR}"
printf 'Worktree:   %s\n' "${WORKTREE_ROOT}"
printf 'Branch:     %s\n' "${DISPLAY_BRANCH}"
printf 'Commit:     %s\n' "${SHORT_SHA}"
printf 'Primary:    %s (%s)\n' "${PRIMARY_WORKTREE}" "${PRIMARY_BRANCH:-detached HEAD}"

if [[ "${WORKTREE_ROOT}" != "${ROOT_DIR}" ]]; then
    fail_check "Script root and Git worktree root differ."
fi

case "${WORKTREE_ROOT}" in
    */.build|*/.build/*)
        require_override_or_fail SERVERDASH_ALLOW_LEGACY_WORKTREE \
            "Registered source worktrees must not live under .build."
        ;;
esac

if [[ "${CI:-false}" != "true" && "${GITHUB_ACTIONS:-false}" != "true" && "${PRIMARY_BRANCH}" != "main" ]]; then
    require_override_or_fail SERVERDASH_ALLOW_LEGACY_WORKTREE \
        "The primary worktree must remain on main; found ${PRIMARY_BRANCH:-detached HEAD}."
fi

LOWER_BRANCH="$(printf '%s' "${BRANCH}" | tr '[:upper:]' '[:lower:]')"
case "${LOWER_BRANCH}" in
    windows/*|codex/windows-*)
        require_override_or_fail SERVERDASH_ALLOW_WINDOWS_BRANCH \
            "The Windows client branch is not an Apple build workspace."
        ;;
esac

WINDOWS_CLIENT_PATHS=""
while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    lower_path="$(printf '%s' "${path}" | tr '[:upper:]' '[:lower:]')"
    case "${lower_path}" in
        windows|windows/*|desktop|desktop/*|docs/windows.md|docs/windowsclient*.md|docs/windows-client*.md|docs/*windows-client*.md|docs/architecturedecisions/*windows-winui-client*.md|.github/workflows/windows*.yml|.github/workflows/windows*.yaml|*.cs|*.csproj|*.fs|*.fsproj|*.vb|*.vbproj|*.sln|*.slnx|*.wapproj|*.xaml|*.vcxproj|*.props|*.targets|*.nuspec|*.ps1|*.cmd|*.bat|*/package.appxmanifest|package.appxmanifest|*.msix|*.msixbundle)
            WINDOWS_CLIENT_PATHS="${WINDOWS_CLIENT_PATHS}${path}
"
            ;;
    esac
done <<EOF
$(git -C "${ROOT_DIR}" ls-files)
EOF
WINDOWS_CLIENT_CONTENT_PATHS=""
while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    lower_path="$(printf '%s' "${path}" | tr '[:upper:]' '[:lower:]')"
    case "${lower_path}" in
        docs/branch_policy.md|scripts/check-apple-main-scope.sh|scripts/test-apple-main-scope.sh|scripts/dev-doctor.sh|scripts/test-dev-workflow.sh)
            continue
            ;;
        docs/*.md|docs/*.markdown|docs/*.rst|docs/*.txt|docs/*.adoc|docs/*.asciidoc|scripts/*.sh)
            ;;
        *)
            continue
            ;;
    esac
    if grep -Eiq '(^|[^[:alnum:]_])(winui([[:space:]]*3)?|msix(bundle)?|wpf|windows[[:space:]]+app[[:space:]]+sdk|dotnet|csproj|msbuild|nuget|pwsh|powershell)([^[:alnum:]_]|$)' "${ROOT_DIR}/${path}"; then
        WINDOWS_CLIENT_CONTENT_PATHS="${WINDOWS_CLIENT_CONTENT_PATHS}${path}
"
    fi
done <<EOF
$(git -C "${ROOT_DIR}" ls-files)
EOF
if [[ -n "${WINDOWS_CLIENT_PATHS}${WINDOWS_CLIENT_CONTENT_PATHS}" ]]; then
    require_override_or_fail SERVERDASH_ALLOW_WINDOWS_BRANCH \
        "This checkout contains an independent Windows client tree and is not an Apple build workspace."
fi

if [[ -z "${BRANCH}" && "${CI:-false}" != "true" && "${GITHUB_ACTIONS:-false}" != "true" ]]; then
    matching_tag=""
    if [[ -n "${EXPECTED_VERSION}" ]]; then
        matching_tag="$(git -C "${ROOT_DIR}" tag --points-at "${HEAD_SHA}" | grep -Fx "v${EXPECTED_VERSION}" || true)"
    fi
    if [[ -z "${matching_tag}" ]]; then
        require_override_or_fail SERVERDASH_ALLOW_DETACHED \
            "Detached HEAD is supported for CI and an exact release tag only."
    fi
fi

if git -C "${ROOT_DIR}" rev-parse --verify origin/main >/dev/null 2>&1; then
    read -r AHEAD_COUNT BEHIND_COUNT <<EOF
$(git -C "${ROOT_DIR}" rev-list --left-right --count HEAD...origin/main)
EOF
    printf 'origin/main: ahead %s, behind %s\n' "${AHEAD_COUNT}" "${BEHIND_COUNT}"
    if ! git -C "${ROOT_DIR}" merge-base --is-ancestor origin/main HEAD; then
        require_override_or_fail SERVERDASH_ALLOW_STALE_BASE \
            "HEAD does not contain the locally known origin/main."
    fi
else
    require_override_or_fail SERVERDASH_ALLOW_STALE_BASE \
        "origin/main is unavailable; fetch it before Apple validation."
fi

if [[ "${REQUIRE_MAIN}" == "1" ]]; then
    if [[ "${BRANCH}" != "main" ]]; then
        matching_tag=""
        if [[ -z "${BRANCH}" && -n "${EXPECTED_VERSION}" ]]; then
            matching_tag="$(git -C "${ROOT_DIR}" tag --points-at "${HEAD_SHA}" | grep -Fx "v${EXPECTED_VERSION}" || true)"
        fi
        if [[ -z "${matching_tag}" ]]; then
            require_override_or_fail SERVERDASH_ALLOW_NONRELEASE_BRANCH \
                "Release artifacts must be built from main or detached at v${EXPECTED_VERSION:-<version>}."
        fi
    fi
fi

MARKETING_VERSIONS="$(unique_yaml_values MARKETING_VERSION)"
BUILD_VERSIONS="$(unique_yaml_values CURRENT_PROJECT_VERSION)"
MARKETING_COUNT="$(printf '%s\n' "${MARKETING_VERSIONS}" | awk 'NF { count += 1 } END { print count + 0 }')"
BUILD_COUNT="$(printf '%s\n' "${BUILD_VERSIONS}" | awk 'NF { count += 1 } END { print count + 0 }')"

if [[ "${MARKETING_COUNT}" != "1" ]]; then
    fail_check "Application targets do not share one MARKETING_VERSION: ${MARKETING_VERSIONS:-missing}"
    PROJECT_VERSION="unknown"
else
    PROJECT_VERSION="${MARKETING_VERSIONS}"
fi
if [[ "${BUILD_COUNT}" != "1" ]]; then
    fail_check "Application targets do not share one CURRENT_PROJECT_VERSION: ${BUILD_VERSIONS:-missing}"
    PROJECT_BUILD="unknown"
else
    PROJECT_BUILD="${BUILD_VERSIONS}"
fi
printf 'Version:    %s (build %s)\n' "${PROJECT_VERSION}" "${PROJECT_BUILD}"

if [[ ! "${PROJECT_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    fail_check "MARKETING_VERSION must use numeric MAJOR.MINOR.PATCH form."
fi
if [[ ! "${PROJECT_BUILD}" =~ ^[1-9][0-9]*$ ]]; then
    fail_check "CURRENT_PROJECT_VERSION must be a positive integer."
fi

if [[ -n "${EXPECTED_VERSION}" && "${PROJECT_VERSION}" != "${EXPECTED_VERSION}" ]]; then
    fail_check "Requested version ${EXPECTED_VERSION} does not match project.yml version ${PROJECT_VERSION}."
fi

if [[ "${REQUIRE_MAIN}" == "1" && -n "${EXPECTED_VERSION}" ]]; then
    RELEASE_NOTICE="${ROOT_DIR}/Docs/RELEASE_NOTES_${EXPECTED_VERSION}.md"
    if [[ ! -f "${RELEASE_NOTICE}" ]]; then
        fail_check "Release notice is missing: ${RELEASE_NOTICE}"
    elif ! grep -Fq "${EXPECTED_VERSION}" "${RELEASE_NOTICE}"; then
        fail_check "Release notice does not identify version ${EXPECTED_VERSION}: ${RELEASE_NOTICE}"
    fi
fi

if [[ "${REQUIRE_CLEAN}" == "1" ]]; then
    DIRTY_STATE="$(git -C "${ROOT_DIR}" status --porcelain --untracked-files=all)"
    if [[ -n "${DIRTY_STATE}" ]]; then
        require_override_or_fail SERVERDASH_ALLOW_DIRTY \
            "A clean worktree is required; git status reports local changes."
    else
        printf 'Git state:  clean\n'
    fi
fi

if [[ "${CHECK_GENERATED}" == "1" ]]; then
    check_generated_project
fi

RDP_ENSURE_SCRIPT="${ROOT_DIR}/Scripts/ensure-rdp-dependencies.sh"
if [[ -f "${RDP_ENSURE_SCRIPT}" ]]; then
    if RDP_KEY="$(bash "${RDP_ENSURE_SCRIPT}" --print-key 2>/dev/null)"; then
        printf 'RDP key:    %s\n' "${RDP_KEY}"
    else
        warn_check "The RDP content key could not be calculated."
    fi
    if bash "${RDP_ENSURE_SCRIPT}" --verify-only --quiet >/dev/null 2>&1; then
        printf 'RDP cache:  verified\n'
    else
        warn_check "RDP dependencies are not ready; run ./Scripts/macos-dev.sh bootstrap."
    fi
else
    fail_check "RDP bootstrap script is missing: ${RDP_ENSURE_SCRIPT}"
fi

if [[ "${ERROR_COUNT}" -gt 0 ]]; then
    printf 'Developer checks failed with %s error(s) and %s warning(s).\n' \
        "${ERROR_COUNT}" "${WARNING_COUNT}" >&2
    exit 1
fi

printf 'Developer checks passed with %s warning(s).\n' "${WARNING_COUNT}"
