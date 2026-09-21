#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
REF=""
SOURCE_BRANCH=""

usage() {
    cat <<'EOF'
Usage: ./Scripts/check-apple-main-scope.sh [--ref REF] [--source-branch NAME]

Validates that a candidate Apple mainline tree contains only the approved
Apple product and support roots, and no independent Windows client project.
Without --ref, tracked paths from the current index are checked.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ref)
            [[ $# -ge 2 ]] || { echo "--ref requires a value" >&2; exit 2; }
            REF="$2"
            shift 2
            ;;
        --source-branch)
            [[ $# -ge 2 ]] || { echo "--source-branch requires a value" >&2; exit 2; }
            SOURCE_BRANCH="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

LOWER_SOURCE_BRANCH="$(printf '%s' "${SOURCE_BRANCH}" | tr '[:upper:]' '[:lower:]')"
case "${LOWER_SOURCE_BRANCH}" in
    windows/*|codex/windows-*)
        echo "Windows client branches cannot be merged into the Apple mainline: ${SOURCE_BRANCH}" >&2
        exit 1
        ;;
esac

if [[ -n "${REF}" ]]; then
    git -C "${ROOT_DIR}" rev-parse --verify "${REF}^{tree}" >/dev/null
    PATHS="$(git -C "${ROOT_DIR}" ls-tree -r --name-only "${REF}")"
    PROJECT_YAML="$(git -C "${ROOT_DIR}" show "${REF}:project.yml")"
else
    PATHS="$(git -C "${ROOT_DIR}" ls-files)"
    PROJECT_YAML="$(cat "${ROOT_DIR}/project.yml")"
fi

read_tracked_path() {
    local path="$1"
    if [[ -n "${REF}" ]]; then
        git -C "${ROOT_DIR}" show "${REF}:${path}"
    else
        cat "${ROOT_DIR}/${path}"
    fi
}

allowed_root() {
    case "$1" in
        .cursor|.github|.gitignore|CHANGELOG.md|Docs|MacUITests|Mobile|Native|README.md|README.zh-CN.md|Resources|Scripts|ServerDash.xcodeproj|Sources|Tests|Vendor|Website|project.yml)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

invalid=0
while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    root="${path%%/*}"
    if ! allowed_root "${root}"; then
        echo "Apple mainline contains an unapproved top-level path: ${path}" >&2
        invalid=1
        continue
    fi

    lower_path="$(printf '%s' "${path}" | tr '[:upper:]' '[:lower:]')"
    case "${lower_path}" in
        windows/*|docs/windows.md|docs/windowsclient*.md|docs/windows-client*.md|docs/*windows-client*.md|docs/architecturedecisions/*windows-winui-client*.md|.github/workflows/windows*.yml|.github/workflows/windows*.yaml|*.cs|*.csproj|*.fs|*.fsproj|*.vb|*.vbproj|*.sln|*.slnx|*.wapproj|*.xaml|*.vcxproj|*.props|*.targets|*.nuspec|*.ps1|*.cmd|*.bat|*/package.appxmanifest|package.appxmanifest|*.msix|*.msixbundle)
            echo "Independent Windows client content is not allowed on Apple mainline: ${path}" >&2
            invalid=1
            ;;
    esac
done <<EOF
${PATHS}
EOF

# Windows product documentation can be disguised behind a neutral filename.
# Scan for client-framework/package markers that do not occur in the allowed
# macOS RDP, FreeRDP/WinPR, remote-host or certificate documentation. The
# policy document itself necessarily discusses this boundary and is excluded.
while IFS= read -r document; do
    [[ -n "${document}" ]] || continue
    lower_document="$(printf '%s' "${document}" | tr '[:upper:]' '[:lower:]')"
    case "${lower_document}" in
        docs/branch_policy.md) continue ;;
        docs/*.md|docs/*.markdown|docs/*.rst|docs/*.txt|docs/*.adoc|docs/*.asciidoc) ;;
        *) continue ;;
    esac

    if read_tracked_path "${document}" | grep -Eiq \
        '(^|[^[:alnum:]_])(winui([[:space:]]*3)?|msix(bundle)?|wpf|windows[[:space:]]+app[[:space:]]+sdk|dotnet|csproj)([^[:alnum:]_]|$)'; then
        echo "Independent Windows client documentation is not allowed on Apple mainline: ${document}" >&2
        invalid=1
    fi
done <<EOF
${PATHS}
EOF

# Windows client build helpers can also hide behind neutral POSIX script names.
while IFS= read -r script; do
    [[ -n "${script}" ]] || continue
    lower_script="$(printf '%s' "${script}" | tr '[:upper:]' '[:lower:]')"
    case "${lower_script}" in
        scripts/check-apple-main-scope.sh|scripts/test-apple-main-scope.sh|scripts/dev-doctor.sh|scripts/test-dev-workflow.sh) continue ;;
        scripts/*.sh) ;;
        *) continue ;;
    esac

    if read_tracked_path "${script}" | grep -Eiq \
        '(^|[^[:alnum:]_])(winui([[:space:]]*3)?|msix(bundle)?|wpf|windows[[:space:]]+app[[:space:]]+sdk|dotnet|csproj|msbuild|nuget|pwsh|powershell)([^[:alnum:]_]|$)'; then
        echo "Independent Windows client build tooling is not allowed on Apple mainline: ${script}" >&2
        invalid=1
    fi
done <<EOF
${PATHS}
EOF

# A Windows client workflow can use an innocuous filename such as
# `release-pc.yml`, so validate workflow contents as well as paths. These
# markers intentionally target Windows build/release tooling; Apple-side RDP,
# FreeRDP/WinPR sources and Windows-host interoperability fixtures stay valid.
while IFS= read -r workflow; do
    [[ -n "${workflow}" ]] || continue
    lower_workflow="$(printf '%s' "${workflow}" | tr '[:upper:]' '[:lower:]')"
    case "${lower_workflow}" in
        .github/workflows/*.yml|.github/workflows/*.yaml) ;;
        *) continue ;;
    esac

    if read_tracked_path "${workflow}" | grep -Eiq \
        'windows-(latest|[0-9]+)|actions/setup-dotnet|(^|[[:space:]])dotnet[[:space:]]+(build|test|publish|restore)|(^|[[:space:]])(msbuild|nuget|pwsh|powershell)([[:space:]]|$)|(^|[^[:alnum:]_])(build|package|publish)[-_](pc|windows)([^[:alnum:]_]|$)|\.ps1([[:space:]"'"'']|$)|\.(sln|csproj|wapproj)([[:space:]"'"'']|$)|(^|[^[:alnum:]_])(winui|msix(bundle)?)([^[:alnum:]_]|$)'; then
        echo "Independent Windows client workflow is not allowed on Apple mainline: ${workflow}" >&2
        invalid=1
    fi
done <<EOF
${PATHS}
EOF

platforms="$(printf '%s\n' "${PROJECT_YAML}" | awk '$1 == "platform:" { print $2 }' | sort -u)"
while IFS= read -r platform; do
    [[ -n "${platform}" ]] || continue
    case "${platform}" in
        macOS|iOS|tvOS|watchOS|visionOS) ;;
        *)
            echo "project.yml declares a non-Apple platform: ${platform}" >&2
            invalid=1
            ;;
    esac
done <<EOF
${platforms}
EOF

if [[ ${invalid} -ne 0 ]]; then
    echo "Apple mainline scope validation failed. See Docs/BRANCH_POLICY.md." >&2
    exit 1
fi

echo "Apple mainline scope is valid."
