#!/bin/bash

set -euo pipefail

# Exercise each fixture with only the CI state specified by that test. GitHub
# Actions exports both variables globally, which would otherwise make the
# local-worktree guard cases look like detached CI checkouts.
unset CI GITHUB_ACTIONS

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/serverdash-dev-workflow-tests.XXXXXX")"
PRIMARY_REPO="${FIXTURE_ROOT}/ServerDash"
FEATURE_REPO="${FIXTURE_ROOT}/ServerDash-worktrees/mac-build-reliability"
LEGACY_REPO="${FIXTURE_ROOT}/legacy/.build/mac-build-reliability"
CI_REPO="${FIXTURE_ROOT}/ci-checkout"
WINDOWS_REPO="${FIXTURE_ROOT}/ServerDash-worktrees/windows-installer-preview"
DESKTOP_REPO="${FIXTURE_ROOT}/ServerDash-worktrees/desktop-preview"
CMD_REPO="${FIXTURE_ROOT}/ServerDash-worktrees/desktop-cmd-preview"
RST_REPO="${FIXTURE_ROOT}/ServerDash-worktrees/desktop-rst-preview"
CASE_WINDOWS_REPO="${FIXTURE_ROOT}/ServerDash-worktrees/mixed-case-windows-preview"
CASE_DOC_REPO="${FIXTURE_ROOT}/ServerDash-worktrees/uppercase-doc-preview"
CASE_SCRIPT_REPO="${FIXTURE_ROOT}/ServerDash-worktrees/uppercase-script-preview"
OUTPUT_FILE="${FIXTURE_ROOT}/output.log"
TEST_COUNT=0

cleanup() {
    rm -rf "${FIXTURE_ROOT}"
}
trap cleanup EXIT INT TERM

pass() {
    TEST_COUNT=$((TEST_COUNT + 1))
    printf 'ok %s - %s\n' "${TEST_COUNT}" "$1"
}

expect_success() {
    description="$1"
    shift
    if "$@" >"${OUTPUT_FILE}" 2>&1; then
        pass "${description}"
    else
        cat "${OUTPUT_FILE}" >&2
        echo "Expected success: ${description}" >&2
        exit 1
    fi
}

expect_failure_containing() {
    description="$1"
    expected_text="$2"
    shift 2
    if "$@" >"${OUTPUT_FILE}" 2>&1; then
        cat "${OUTPUT_FILE}" >&2
        echo "Expected failure: ${description}" >&2
        exit 1
    fi
    if ! grep -Fq "${expected_text}" "${OUTPUT_FILE}"; then
        cat "${OUTPUT_FILE}" >&2
        echo "Failure did not contain '${expected_text}': ${description}" >&2
        exit 1
    fi
    pass "${description}"
}

mkdir -p \
    "${PRIMARY_REPO}/Scripts" \
    "${PRIMARY_REPO}/ServerDash.xcodeproj" \
    "${PRIMARY_REPO}/Docs"
cp "${SOURCE_ROOT}/Scripts/dev-doctor.sh" "${PRIMARY_REPO}/Scripts/dev-doctor.sh"
cat >"${PRIMARY_REPO}/Scripts/ensure-rdp-dependencies.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
case "${1:-ensure}" in
    --print-key) echo fixture-key ;;
    --verify-only|ensure) exit 0 ;;
    *) exit 2 ;;
esac
EOF
cat >"${PRIMARY_REPO}/project.yml" <<'EOF'
name: ServerDash
targets:
  ServerDash:
    settings:
      base:
        MARKETING_VERSION: "1.0.3"
        CURRENT_PROJECT_VERSION: 8
  ServerDashMobile:
    settings:
      base:
        MARKETING_VERSION: "1.0.3"
        CURRENT_PROJECT_VERSION: 8
EOF
cat >"${PRIMARY_REPO}/Docs/RELEASE_NOTES_1.0.3.md" <<'EOF'
# ServerDash 1.0.3
EOF
touch "${PRIMARY_REPO}/ServerDash.xcodeproj/project.pbxproj"

git -C "${PRIMARY_REPO}" init -q -b main
git -C "${PRIMARY_REPO}" config user.name "ServerDash Tests"
git -C "${PRIMARY_REPO}" config user.email "tests@serverdash.invalid"
git -C "${PRIMARY_REPO}" add .
git -C "${PRIMARY_REPO}" commit -qm "Fixture baseline"
git -C "${PRIMARY_REPO}" update-ref refs/remotes/origin/main HEAD

DOCTOR=(bash "${PRIMARY_REPO}/Scripts/dev-doctor.sh" --skip-generated-check)
expect_success "clean main worktree passes" "${DOCTOR[@]}"
expect_failure_containing \
    "version mismatch is rejected" \
    "does not match project.yml" \
    "${DOCTOR[@]}" --expect-version 1.0.4

cp "${PRIMARY_REPO}/project.yml" "${FIXTURE_ROOT}/project.yml.saved"
sed 's/CURRENT_PROJECT_VERSION: 8/CURRENT_PROJECT_VERSION: 0/g' \
    "${FIXTURE_ROOT}/project.yml.saved" >"${PRIMARY_REPO}/project.yml"
expect_failure_containing \
    "non-positive build number is rejected" \
    "CURRENT_PROJECT_VERSION must be a positive integer" \
    "${DOCTOR[@]}"
cp "${FIXTURE_ROOT}/project.yml.saved" "${PRIMARY_REPO}/project.yml"

touch "${PRIMARY_REPO}/untracked-change"
expect_failure_containing \
    "dirty release context is rejected" \
    "A clean worktree is required" \
    "${DOCTOR[@]}" --require-clean
expect_success \
    "dirty diagnostic override is explicit" \
    env SERVERDASH_ALLOW_DIRTY=1 "${DOCTOR[@]}" --require-clean
rm "${PRIMARY_REPO}/untracked-change"

git -C "${PRIMARY_REPO}" switch -qc codex/not-main
expect_failure_containing \
    "primary checkout must stay on main" \
    "The primary worktree must remain on main" \
    "${DOCTOR[@]}"
expect_success \
    "legacy primary-layout override is explicit" \
    env SERVERDASH_ALLOW_LEGACY_WORKTREE=1 "${DOCTOR[@]}"
git -C "${PRIMARY_REPO}" switch -q main

mkdir -p "$(dirname "${FEATURE_REPO}")"
git -C "${PRIMARY_REPO}" worktree add -q -b codex/test "${FEATURE_REPO}" main
FEATURE_DOCTOR=(bash "${FEATURE_REPO}/Scripts/dev-doctor.sh" --skip-generated-check)
expect_failure_containing \
    "release artifacts reject a feature branch" \
    "Release artifacts must be built from main" \
    "${FEATURE_DOCTOR[@]}" --release 1.0.3
expect_success \
    "feature-branch release diagnostic override is explicit" \
    env SERVERDASH_ALLOW_NONRELEASE_BRANCH=1 "${FEATURE_DOCTOR[@]}" --release 1.0.3

git -C "${PRIMARY_REPO}" worktree add -q -b codex/windows-installer-preview \
    "${WINDOWS_REPO}" main
WINDOWS_DOCTOR=(bash "${WINDOWS_REPO}/Scripts/dev-doctor.sh" --skip-generated-check)
expect_failure_containing \
    "Windows client branch is rejected for Apple builds" \
    "Windows client branch is not an Apple build workspace" \
    "${WINDOWS_DOCTOR[@]}"
expect_success \
    "Windows client diagnostic override is explicit" \
    env SERVERDASH_ALLOW_WINDOWS_BRANCH=1 "${WINDOWS_DOCTOR[@]}"
git -C "${WINDOWS_REPO}" switch -qc windows/align-macos main
expect_failure_containing \
    "windows slash branch is rejected for Apple builds" \
    "Windows client branch is not an Apple build workspace" \
    "${WINDOWS_DOCTOR[@]}"

git -C "${PRIMARY_REPO}" worktree add -q -b codex/desktop-preview \
    "${DESKTOP_REPO}" main
mkdir -p "${DESKTOP_REPO}/Desktop"
touch "${DESKTOP_REPO}/Desktop/ServerDash.Windows.exe"
git -C "${DESKTOP_REPO}" add Desktop
git -C "${DESKTOP_REPO}" commit -qm "Add disguised Windows desktop tree"
DESKTOP_DOCTOR=(bash "${DESKTOP_REPO}/Scripts/dev-doctor.sh" --skip-generated-check)
expect_failure_containing \
    "Windows Desktop tree is rejected on a neutral branch" \
    "contains an independent Windows client tree" \
    "${DESKTOP_DOCTOR[@]}"
expect_success \
    "Windows Desktop tree diagnostic override is explicit" \
    env SERVERDASH_ALLOW_WINDOWS_BRANCH=1 "${DESKTOP_DOCTOR[@]}"

git -C "${PRIMARY_REPO}" worktree add -q -b codex/desktop-cmd-preview \
    "${CMD_REPO}" main
cat >"${CMD_REPO}/Scripts/build-desktop.cmd" <<'EOF'
@echo off
dotnet publish Client.csproj
EOF
git -C "${CMD_REPO}" add Scripts/build-desktop.cmd
git -C "${CMD_REPO}" commit -qm "Add neutral Windows command script"
CMD_DOCTOR=(bash "${CMD_REPO}/Scripts/dev-doctor.sh" --skip-generated-check)
expect_failure_containing \
    "Windows command script is rejected on a neutral branch" \
    "contains an independent Windows client tree" \
    "${CMD_DOCTOR[@]}"

git -C "${PRIMARY_REPO}" worktree add -q -b codex/desktop-rst-preview \
    "${RST_REPO}" main
cat >"${RST_REPO}/Docs/desktop-client.rst" <<'EOF'
Desktop client
==============

This document describes the WinUI and MSIX application.
EOF
git -C "${RST_REPO}" add Docs/desktop-client.rst
git -C "${RST_REPO}" commit -qm "Add neutral Windows documentation"
RST_DOCTOR=(bash "${RST_REPO}/Scripts/dev-doctor.sh" --skip-generated-check)
expect_failure_containing \
    "Windows RST documentation is rejected on a neutral branch" \
    "contains an independent Windows client tree" \
    "${RST_DOCTOR[@]}"

git -C "${PRIMARY_REPO}" worktree add -q -b codex/mixed-case-windows-preview \
    "${CASE_WINDOWS_REPO}" main
mkdir -p "${CASE_WINDOWS_REPO}/wInDoWs/App"
touch "${CASE_WINDOWS_REPO}/wInDoWs/App/client.txt"
git -C "${CASE_WINDOWS_REPO}" add .
git -C "${CASE_WINDOWS_REPO}" commit -qm "Add mixed-case Windows tree"
CASE_WINDOWS_DOCTOR=(bash "${CASE_WINDOWS_REPO}/Scripts/dev-doctor.sh" --skip-generated-check)
expect_failure_containing \
    "Mixed-case Windows tree is rejected on a neutral branch" \
    "contains an independent Windows client tree" \
    "${CASE_WINDOWS_DOCTOR[@]}"

git -C "${PRIMARY_REPO}" worktree add -q -b codex/uppercase-doc-preview \
    "${CASE_DOC_REPO}" main
cat >"${CASE_DOC_REPO}/Docs/desktop-client.MD" <<'EOF'
# Desktop client

This document describes the WinUI and MSIX application.
EOF
git -C "${CASE_DOC_REPO}" add Docs/desktop-client.MD
git -C "${CASE_DOC_REPO}" commit -qm "Add uppercase-extension Windows documentation"
CASE_DOC_DOCTOR=(bash "${CASE_DOC_REPO}/Scripts/dev-doctor.sh" --skip-generated-check)
expect_failure_containing \
    "Uppercase Markdown Windows documentation is rejected on a neutral branch" \
    "contains an independent Windows client tree" \
    "${CASE_DOC_DOCTOR[@]}"

git -C "${PRIMARY_REPO}" worktree add -q -b codex/uppercase-script-preview \
    "${CASE_SCRIPT_REPO}" main
cat >"${CASE_SCRIPT_REPO}/Scripts/build-desktop.SH" <<'EOF'
#!/bin/bash
dotnet publish Client.csproj
EOF
git -C "${CASE_SCRIPT_REPO}" add Scripts/build-desktop.SH
git -C "${CASE_SCRIPT_REPO}" commit -qm "Add uppercase-extension Windows build script"
CASE_SCRIPT_DOCTOR=(bash "${CASE_SCRIPT_REPO}/Scripts/dev-doctor.sh" --skip-generated-check)
expect_failure_containing \
    "Uppercase shell Windows build tooling is rejected on a neutral branch" \
    "contains an independent Windows client tree" \
    "${CASE_SCRIPT_DOCTOR[@]}"

mkdir -p "$(dirname "${LEGACY_REPO}")"
git -C "${PRIMARY_REPO}" worktree add -q -b codex/legacy "${LEGACY_REPO}" main
LEGACY_DOCTOR=(bash "${LEGACY_REPO}/Scripts/dev-doctor.sh" --skip-generated-check)
expect_failure_containing \
    "registered worktree under .build is rejected" \
    "must not live under .build" \
    "${LEGACY_DOCTOR[@]}"
expect_success \
    "legacy worktree diagnostic override is explicit" \
    env SERVERDASH_ALLOW_LEGACY_WORKTREE=1 "${LEGACY_DOCTOR[@]}"

echo "advance" >"${PRIMARY_REPO}/advance"
git -C "${PRIMARY_REPO}" add advance
git -C "${PRIMARY_REPO}" commit -qm "Advance main"
git -C "${PRIMARY_REPO}" update-ref refs/remotes/origin/main HEAD
git -C "${PRIMARY_REPO}" worktree add -q --detach "${CI_REPO}" main
expect_success \
    "detached CI checkout is accepted" \
    env CI=true bash "${CI_REPO}/Scripts/dev-doctor.sh" --skip-generated-check
expect_failure_containing \
    "stale feature baseline is rejected" \
    "does not contain the locally known origin/main" \
    env SERVERDASH_ALLOW_NONRELEASE_BRANCH=1 \
    "${FEATURE_DOCTOR[@]}" --release 1.0.3
expect_success \
    "stale-base diagnostic override is explicit" \
    env SERVERDASH_ALLOW_NONRELEASE_BRANCH=1 SERVERDASH_ALLOW_STALE_BASE=1 \
    "${FEATURE_DOCTOR[@]}" --release 1.0.3

printf '1..%s\n' "${TEST_COUNT}"
