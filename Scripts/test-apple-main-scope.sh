#!/bin/bash

set -euo pipefail

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/serverdash-apple-scope.XXXXXX")"
TEST_COUNT=0

cleanup() { rm -rf "${TEST_ROOT}"; }
trap cleanup EXIT INT TERM

new_fixture() {
    name="$1"
    root="${TEST_ROOT}/${name}"
    mkdir -p "${root}/Scripts" "${root}/Sources" "${root}/MacUITests" "${root}/Native" \
        "${root}/Tests/Fixtures/RDP" "${root}/Docs" "${root}/Vendor/RDP"
    cp "${SOURCE_ROOT}/Scripts/check-apple-main-scope.sh" "${root}/Scripts/"
    cat >"${root}/project.yml" <<'EOF'
name: ServerDash
targets:
  ServerDash:
    platform: macOS
  ServerDashMobile:
    platform: iOS
EOF
    touch "${root}/Sources/RDPConnection.swift"
    touch "${root}/MacUITests/ServerDashMacQAUITests.swift"
    touch "${root}/Native/SDRDPClient.m"
    touch "${root}/Tests/Fixtures/RDP/windows-self-signed.pem"
    touch "${root}/Docs/RDP.md"
    touch "${root}/Vendor/RDP/README.md"
    git -C "${root}" init -q -b main
    git -C "${root}" config user.name "ServerDash Tests"
    git -C "${root}" config user.email "tests@serverdash.invalid"
    git -C "${root}" add .
    git -C "${root}" commit -qm "Fixture"
    printf '%s\n' "${root}"
}

pass() {
    TEST_COUNT=$((TEST_COUNT + 1))
    printf 'ok %s - %s\n' "${TEST_COUNT}" "$1"
}

expect_success() {
    description="$1"
    shift
    if "$@" >"${TEST_ROOT}/output.log" 2>&1; then
        pass "${description}"
    else
        cat "${TEST_ROOT}/output.log" >&2
        exit 1
    fi
}

expect_failure() {
    description="$1"
    expected="$2"
    shift 2
    if "$@" >"${TEST_ROOT}/output.log" 2>&1; then
        echo "Expected failure: ${description}" >&2
        exit 1
    fi
    grep -Fq "${expected}" "${TEST_ROOT}/output.log" || {
        cat "${TEST_ROOT}/output.log" >&2
        exit 1
    }
    pass "${description}"
}

valid="$(new_fixture valid)"
expect_success "Apple RDP and Windows-host fixtures remain allowed" \
    bash "${valid}/Scripts/check-apple-main-scope.sh" --ref HEAD --source-branch codex/mac-ui
expect_failure "Windows source branch is rejected" "cannot be merged" \
    bash "${valid}/Scripts/check-apple-main-scope.sh" --ref HEAD --source-branch windows/align-macos
expect_failure "Windows source branch matching is case-insensitive" "cannot be merged" \
    bash "${valid}/Scripts/check-apple-main-scope.sh" --ref HEAD --source-branch Windows/align-macos

windows_tree="$(new_fixture windows-tree)"
mkdir -p "${windows_tree}/Windows/App"
touch "${windows_tree}/Windows/App/MainWindow.xaml"
git -C "${windows_tree}" add . && git -C "${windows_tree}" commit -qm "Add Windows tree"
expect_failure "Windows product tree is rejected" "unapproved top-level path" \
    bash "${windows_tree}/Scripts/check-apple-main-scope.sh" --ref HEAD

mixed_case_windows_tree="$(new_fixture mixed-case-windows-tree)"
mkdir -p "${mixed_case_windows_tree}/wInDoWs/App"
touch "${mixed_case_windows_tree}/wInDoWs/App/client.txt"
git -C "${mixed_case_windows_tree}" add . && git -C "${mixed_case_windows_tree}" commit -qm "Add mixed-case Windows tree"
expect_failure "Mixed-case Windows product tree is rejected" "unapproved top-level path" \
    bash "${mixed_case_windows_tree}/Scripts/check-apple-main-scope.sh" --ref HEAD

dotnet="$(new_fixture dotnet)"
touch "${dotnet}/Sources/ServerDash.csproj"
git -C "${dotnet}" add . && git -C "${dotnet}" commit -qm "Add project"
expect_failure "C# project is rejected" "Independent Windows client content" \
    bash "${dotnet}/Scripts/check-apple-main-scope.sh" --ref HEAD

windows_docs="$(new_fixture windows-docs)"
touch "${windows_docs}/Docs/WINDOWS.md"
git -C "${windows_docs}" add . && git -C "${windows_docs}" commit -qm "Add Windows docs"
expect_failure "Windows client documentation is rejected" "Independent Windows client content" \
    bash "${windows_docs}/Scripts/check-apple-main-scope.sh" --ref HEAD

disguised_windows_docs="$(new_fixture disguised-windows-docs)"
cat >"${disguised_windows_docs}/Docs/desktop-client.md" <<'EOF'
# Desktop client

This document describes the WinUI and MSIX application.
EOF
git -C "${disguised_windows_docs}" add . && git -C "${disguised_windows_docs}" commit -qm "Add disguised Windows docs"
expect_failure "Windows client documentation is rejected by content" "Windows client documentation" \
    bash "${disguised_windows_docs}/Scripts/check-apple-main-scope.sh" --ref HEAD

uppercase_windows_docs="$(new_fixture uppercase-windows-docs)"
cat >"${uppercase_windows_docs}/Docs/desktop-client.MD" <<'EOF'
# Desktop client

This document describes the WinUI and MSIX application.
EOF
git -C "${uppercase_windows_docs}" add . && git -C "${uppercase_windows_docs}" commit -qm "Add uppercase-extension Windows docs"
expect_failure "Uppercase Markdown Windows documentation is rejected by content" "Windows client documentation" \
    bash "${uppercase_windows_docs}/Scripts/check-apple-main-scope.sh" --ref HEAD

rst_windows_docs="$(new_fixture rst-windows-docs)"
cat >"${rst_windows_docs}/Docs/desktop-client.rst" <<'EOF'
Desktop client
==============

This document describes the WinUI and MSIX application.
EOF
git -C "${rst_windows_docs}" add . && git -C "${rst_windows_docs}" commit -qm "Add disguised RST Windows docs"
expect_failure "Windows RST documentation is rejected by content" "Windows client documentation" \
    bash "${rst_windows_docs}/Scripts/check-apple-main-scope.sh" --ref HEAD

windows_cmd="$(new_fixture windows-cmd)"
cat >"${windows_cmd}/Scripts/build-desktop.cmd" <<'EOF'
@echo off
dotnet publish Client.csproj
EOF
git -C "${windows_cmd}" add . && git -C "${windows_cmd}" commit -qm "Add disguised Windows command script"
expect_failure "Windows command build tooling is rejected" "Windows client content" \
    bash "${windows_cmd}/Scripts/check-apple-main-scope.sh" --ref HEAD

uppercase_windows_script="$(new_fixture uppercase-windows-script)"
cat >"${uppercase_windows_script}/Scripts/build-desktop.SH" <<'EOF'
#!/bin/bash
dotnet publish Client.csproj
EOF
git -C "${uppercase_windows_script}" add . && git -C "${uppercase_windows_script}" commit -qm "Add uppercase-extension Windows build script"
expect_failure "Uppercase shell Windows build tooling is rejected by content" "Windows client build tooling" \
    bash "${uppercase_windows_script}/Scripts/check-apple-main-scope.sh" --ref HEAD

windows_workflow="$(new_fixture windows-workflow)"
mkdir -p "${windows_workflow}/.github/workflows"
touch "${windows_workflow}/.github/workflows/windows-release.yml"
git -C "${windows_workflow}" add . && git -C "${windows_workflow}" commit -qm "Add workflow"
expect_failure "Windows workflow is rejected" "Independent Windows client content" \
    bash "${windows_workflow}/Scripts/check-apple-main-scope.sh" --ref HEAD

disguised_windows_workflow="$(new_fixture disguised-windows-workflow)"
mkdir -p "${disguised_windows_workflow}/.github/workflows"
cat >"${disguised_windows_workflow}/.github/workflows/release-pc.yml" <<'EOF'
name: Release desktop
jobs:
  package:
    runs-on: windows-latest
    steps:
      - uses: actions/setup-dotnet@0000000000000000000000000000000000000000
      - run: dotnet publish Desktop.csproj
EOF
git -C "${disguised_windows_workflow}" add . && git -C "${disguised_windows_workflow}" commit -qm "Add disguised Windows workflow"
expect_failure "Windows workflow is rejected by content" "Windows client workflow" \
    bash "${disguised_windows_workflow}/Scripts/check-apple-main-scope.sh" --ref HEAD

matrix_windows_workflow="$(new_fixture matrix-windows-workflow)"
mkdir -p "${matrix_windows_workflow}/.github/workflows"
cat >"${matrix_windows_workflow}/.github/workflows/release-desktop.yml" <<'EOF'
name: Release desktop
jobs:
  package:
    strategy:
      matrix:
        os: [windows-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - run: pwsh ./Scripts/build-pc.ps1
EOF
git -C "${matrix_windows_workflow}" add . && git -C "${matrix_windows_workflow}" commit -qm "Add matrix Windows workflow"
expect_failure "Matrix Windows workflow is rejected by content" "Windows client workflow" \
    bash "${matrix_windows_workflow}/Scripts/check-apple-main-scope.sh" --ref HEAD

unknown="$(new_fixture unknown-root)"
mkdir -p "${unknown}/Desktop"
touch "${unknown}/Desktop/readme.txt"
git -C "${unknown}" add . && git -C "${unknown}" commit -qm "Add root"
expect_failure "unknown product root is rejected" "unapproved top-level path" \
    bash "${unknown}/Scripts/check-apple-main-scope.sh" --ref HEAD

platform="$(new_fixture platform)"
sed 's/platform: macOS/platform: Windows/' "${platform}/project.yml" >"${platform}/project.yml.next"
mv "${platform}/project.yml.next" "${platform}/project.yml"
git -C "${platform}" add project.yml && git -C "${platform}" commit -qm "Add platform"
expect_failure "non-Apple project platform is rejected" "non-Apple platform" \
    bash "${platform}/Scripts/check-apple-main-scope.sh" --ref HEAD

printf '1..%s\n' "${TEST_COUNT}"
