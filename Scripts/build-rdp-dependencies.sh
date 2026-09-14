#!/bin/bash
set -euo pipefail

RDP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RDP_BUILD="${RDP_BUILD_ROOT:-$RDP_ROOT/.build/rdp}"
RDP_DOWNLOADS="${RDP_DOWNLOAD_CACHE:-$RDP_BUILD/downloads}"
RDP_OUTPUT="${RDP_OUTPUT_DIR:-$RDP_BUILD}"
RDP_DEPENDENCIES="$RDP_ROOT/Vendor/RDP/dependencies.sha256"
RDP_DEPLOYMENT_TARGET="${RDP_DEPLOYMENT_TARGET:-14.0}"
RDP_ARCHITECTURES="${RDP_ARCHITECTURES:-arm64 x86_64}"
RDP_BUILD_JOBS="${RDP_BUILD_JOBS:-4}"
RDP_DOWNLOAD_TEMPORARIES=()
RDP_BUILDER_MARKER_NAME=".serverdash-rdp-builder-v1"
RDP_BUILDER_MARKER_VALUE="com.serverdash.app.native-rdp-builder-v1"

fail() {
    printf 'RDP dependency build failed: %s\n' "$*" >&2
    exit 1
}

claim_owned_directory() {
    local requested_path="$1"
    local label="$2"
    local adoption_mode="${3:-empty}"
    local canonical_path
    local canonical_home
    local canonical_root
    local marker
    local entries
    local entry
    local entry_name
    local expected_hash
    local marker_staging

    case "$requested_path" in
        /*) ;;
        *) fail "$label must be an absolute path: $requested_path" ;;
    esac
    [[ ! -L "$requested_path" ]] || fail "$label must not be a symbolic link: $requested_path"
    mkdir -p "$requested_path"
    [[ -d "$requested_path" && ! -L "$requested_path" ]] || fail "$label is not a directory: $requested_path"

    canonical_path="$(cd "$requested_path" && pwd -P)"
    canonical_home="$(cd "$HOME" && pwd -P)"
    canonical_root="$(cd "$RDP_ROOT" && pwd -P)"
    case "$canonical_path" in
        /|"$canonical_home"|"$canonical_root")
            fail "$label resolves to an unsafe directory: $canonical_path"
            ;;
    esac

    marker="$canonical_path/$RDP_BUILDER_MARKER_NAME"
    if [[ -e "$marker" ]]; then
        [[ -f "$marker" && ! -L "$marker" ]] || fail "$label ownership marker is invalid: $marker"
        [[ "$(cat "$marker")" == "$RDP_BUILDER_MARKER_VALUE" ]] || fail "$label ownership marker has unexpected content: $marker"
    else
        entries="$(find "$canonical_path" -mindepth 1 -maxdepth 1 \
            ! -name '.builder-marker.*' -print -quit)"
        if [[ -n "$entries" && "$adoption_mode" == "verified-downloads" ]]; then
            for entry in "$canonical_path"/*; do
                [[ -e "$entry" || -L "$entry" ]] || continue
                entry_name="$(basename "$entry")"
                [[ -f "$entry" && ! -L "$entry" ]] || fail "$label contains an unsupported legacy entry: $entry"
                expected_hash="$(awk -v name="$entry_name" '$2 == name { print $1; exit }' "$RDP_DEPENDENCIES")"
                [[ -n "$expected_hash" ]] || fail "$label contains an unrecognized legacy download: $entry_name"
                printf '%s  %s\n' "$expected_hash" "$entry" | shasum -a 256 -c - >/dev/null 2>&1 \
                    || fail "$label contains a corrupted legacy download: $entry_name"
            done
        elif [[ -n "$entries" ]]; then
            fail "$label is non-empty and has no ServerDash ownership marker: $canonical_path"
        fi
        marker_staging="$(mktemp "$canonical_path/.builder-marker.XXXXXX")"
        printf '%s\n' "$RDP_BUILDER_MARKER_VALUE" > "$marker_staging"
        if ! ln "$marker_staging" "$marker" 2>/dev/null; then
            [[ -f "$marker" && ! -L "$marker" ]] || fail "$label ownership marker could not be initialized: $marker"
            [[ "$(cat "$marker")" == "$RDP_BUILDER_MARKER_VALUE" ]] || fail "$label ownership marker has unexpected content: $marker"
        fi
        rm -f "$marker_staging"
    fi
    printf '%s\n' "$canonical_path"
}

cleanup_download_temporaries() {
    local path
    if [[ ${#RDP_DOWNLOAD_TEMPORARIES[@]} -gt 0 ]]; then
        for path in "${RDP_DOWNLOAD_TEMPORARIES[@]}"; do
            rm -f "$path"
        done
    fi
}
trap cleanup_download_temporaries EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

RDP_BUILD="$(claim_owned_directory "$RDP_BUILD" "RDP_BUILD_ROOT")"
RDP_DOWNLOADS="$(claim_owned_directory "$RDP_DOWNLOADS" "RDP_DOWNLOAD_CACHE" "verified-downloads")"
RDP_OUTPUT="$(claim_owned_directory "$RDP_OUTPUT" "RDP_OUTPUT_DIR")"

mkdir -p "$RDP_BUILD/sources" "$RDP_BUILD/tools" \
    "$RDP_BUILD/universal" "$RDP_OUTPUT/universal"

checksum_for() {
    awk -v name="$1" '$2 == name { print $1; exit }' "$RDP_DEPENDENCIES"
}

verify_download() {
    local name="$1"
    verify_download_path "$name" "$RDP_DOWNLOADS/$name"
}

verify_download_path() {
    local name="$1"
    local path="$2"
    local expected
    expected="$(checksum_for "$name")"
    [[ -n "$expected" && -f "$path" ]] || return 1
    printf '%s  %s\n' "$expected" "$path" | shasum -a 256 -c - >/dev/null 2>&1
}

download() {
    local name="$1"
    local url="$2"
    local destination="$RDP_DOWNLOADS/$name"
    local temporary

    if verify_download "$name"; then
        return
    fi

    temporary="$(mktemp "$RDP_DOWNLOADS/.$name.download.XXXXXX")"
    RDP_DOWNLOAD_TEMPORARIES+=("$temporary")
    if ! curl --fail --location --retry 3 --proto '=https' --proto-redir '=https' --max-time 300 "$url" --output "$temporary"; then
        rm -f "$temporary"
        return 1
    fi

    if ! verify_download_path "$name" "$temporary"; then
        rm -f "$temporary"
        printf 'Downloaded dependency failed SHA-256 verification: %s\n' "$name" >&2
        return 1
    fi
    # The shared final path is only ever populated by a verified, atomic rename.
    mv -f "$temporary" "$destination"
}

download freerdp-3.31.0.tar.gz "${RDP_FREERDP_URL:-https://pub.freerdp.com/releases/freerdp-3.31.0.tar.gz}"
download openssl-3.5.8.tar.gz "${RDP_OPENSSL_URL:-https://github.com/openssl/openssl/releases/download/openssl-3.5.8/openssl-3.5.8.tar.gz}"
download cmake-3.31.12-macos-universal.tar.gz "${RDP_CMAKE_URL:-https://github.com/Kitware/CMake/releases/download/v3.31.12/cmake-3.31.12-macos-universal.tar.gz}"
(cd "$RDP_DOWNLOADS" && shasum -a 256 -c "$RDP_DEPENDENCIES")

for RDP_NAME in freerdp-3.31.0 openssl-3.5.8; do
    if [[ ! -d "$RDP_BUILD/sources/$RDP_NAME" ]]; then
        tar -xzf "$RDP_DOWNLOADS/$RDP_NAME.tar.gz" -C "$RDP_BUILD/sources"
    fi
done
if [[ ! -d "$RDP_BUILD/tools/cmake-3.31.12-macos-universal" ]]; then
    tar -xzf "$RDP_DOWNLOADS/cmake-3.31.12-macos-universal.tar.gz" -C "$RDP_BUILD/tools"
fi

RDP_CMAKE="$RDP_BUILD/tools/cmake-3.31.12-macos-universal/CMake.app/Contents/bin/cmake"
RDP_SDK="$(xcrun --sdk macosx --show-sdk-path)"
RDP_ARCHIVES=()
RDP_HEADER_ARCH=""
for RDP_ARCH in $RDP_ARCHITECTURES; do
    case "$RDP_ARCH" in
        arm64|x86_64) ;;
        *)
            printf 'Unsupported RDP architecture: %s\n' "$RDP_ARCH" >&2
            exit 2
            ;;
    esac

    if [[ -z "$RDP_HEADER_ARCH" ]]; then
        RDP_HEADER_ARCH="$RDP_ARCH"
    fi

    RDP_PREFIX="$RDP_BUILD/install-$RDP_ARCH"
    mkdir -p "$RDP_BUILD/openssl-$RDP_ARCH"
    if [[ ! -f "$RDP_PREFIX/lib/libssl.a" ]]; then
        (cd "$RDP_BUILD/openssl-$RDP_ARCH"
         "$RDP_BUILD/sources/openssl-3.5.8/Configure" "darwin64-$RDP_ARCH-cc" \
             no-shared no-tests no-module --libdir=lib --prefix=/ --openssldir=/etc/ssl \
             -mmacosx-version-min="$RDP_DEPLOYMENT_TARGET" -isysroot "$RDP_SDK"
         make -j"$RDP_BUILD_JOBS" build_libs
         make DESTDIR="$RDP_PREFIX" install_dev)
    fi
    "$RDP_CMAKE" -S "$RDP_BUILD/sources/freerdp-3.31.0" -B "$RDP_BUILD/freerdp-$RDP_ARCH" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF -DCMAKE_OSX_ARCHITECTURES="$RDP_ARCH" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$RDP_DEPLOYMENT_TARGET" -DCMAKE_OSX_SYSROOT="$RDP_SDK" \
        -DCMAKE_INSTALL_PREFIX=/ -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_INSTALL_INCLUDEDIR=include \
        -DCMAKE_INSTALL_DATADIR=share -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" \
        -DOPENSSL_ROOT_DIR="$RDP_PREFIX" -DOPENSSL_USE_STATIC_LIBS=ON \
        -DBUILD_SHARED_LIBS=OFF -DWITH_CLIENT=OFF -DWITH_CLIENT_COMMON=ON -DWITH_CLIENT_CHANNELS=ON \
        -DWITH_SERVER=OFF -DWITH_SERVER_CHANNELS=OFF -DWITH_SAMPLE=OFF -DWITH_X11=OFF \
        -DWITH_FFMPEG=OFF -DWITH_SWSCALE=OFF -DWITH_OPENH264=OFF -DWITH_JPEG=OFF -DWITH_OPUS=OFF -DWITH_URIPARSER=OFF \
        -DWITH_MACAUDIO=ON -DWITH_CUPS=OFF -DWITH_PCSC=OFF -DWITH_PKCS11=OFF \
        -DWITH_SMARTCARD_EMULATE=OFF -DWITH_WINPR_TOOLS=OFF -DWITH_MANPAGES=OFF \
        -DWITH_AAD=OFF -DWITH_JSON_DISABLED=ON -DWITH_KRB5=OFF -DWITH_FUSE=OFF \
        -DCHANNEL_URBDRC=OFF -DCHANNEL_SMARTCARD=OFF -DCHANNEL_PRINTER=OFF \
        -DCHANNEL_AUDIN=OFF -DCHANNEL_VIDEO=OFF -DCHANNEL_TSMF=OFF \
        -DBUILD_TESTING=OFF -DWITH_DEBUG_ALL=OFF -DWITH_VERBOSE_WINPR_ASSERT=ON \
        -DWITH_ABSOLUTE_PLUGIN_LOAD_PATHS=OFF \
        -DWITH_CCACHE=OFF -DWITH_CLANG_FORMAT=OFF -DWITH_TLS_DATA_LIMIT=ON
    "$RDP_CMAKE" --build "$RDP_BUILD/freerdp-$RDP_ARCH" --parallel "$RDP_BUILD_JOBS"
    DESTDIR="$RDP_PREFIX" "$RDP_CMAKE" --install "$RDP_BUILD/freerdp-$RDP_ARCH"
    # FreeRDP 3 installs some archives below usr/lib and some channel archives
    # at the install root even when GNUInstallDirs is configured. Discover the
    # complete staged payload instead of assuming a version-specific layout.
    RDP_STATIC_LIBRARIES=()
    while IFS= read -r RDP_LIBRARY; do
        RDP_STATIC_LIBRARIES+=("$RDP_LIBRARY")
    done < <(find "$RDP_PREFIX" -type f -name '*.a' -print | LC_ALL=C sort)
    if [[ ${#RDP_STATIC_LIBRARIES[@]} -eq 0 ]]; then
        printf 'No static libraries were installed for %s.\n' "$RDP_ARCH" >&2
        exit 1
    fi
    /usr/bin/libtool -static -o "$RDP_BUILD/libServerDashRDP-$RDP_ARCH.a" "${RDP_STATIC_LIBRARIES[@]}"
    RDP_ARCHIVES+=("$RDP_BUILD/libServerDashRDP-$RDP_ARCH.a")
done

if [[ ${#RDP_ARCHIVES[@]} -eq 0 || -z "$RDP_HEADER_ARCH" ]]; then
    printf 'RDP_ARCHITECTURES must contain at least one supported architecture.\n' >&2
    exit 2
fi

lipo -create "${RDP_ARCHIVES[@]}" -output "$RDP_BUILD/universal/libServerDashRDP.a"

RDP_HEADERS_STAGING="$(mktemp -d "$RDP_OUTPUT/.headers.XXXXXX")"
cp -R "$RDP_BUILD/install-$RDP_HEADER_ARCH/include/." "$RDP_HEADERS_STAGING/"
rm -rf "$RDP_OUTPUT/universal/Headers"
mv "$RDP_HEADERS_STAGING" "$RDP_OUTPUT/universal/Headers"
if [[ "$RDP_BUILD/universal/libServerDashRDP.a" != "$RDP_OUTPUT/universal/libServerDashRDP.a" ]]; then
    cp "$RDP_BUILD/universal/libServerDashRDP.a" "$RDP_OUTPUT/universal/libServerDashRDP.a"
fi

# XCFramework creation never overwrites an existing bundle. Use a fresh staging directory.
RDP_STAGING="$(mktemp -d "$RDP_OUTPUT/.xcframework.XXXXXX")"
xcodebuild -create-xcframework -library "$RDP_BUILD/universal/libServerDashRDP.a" \
    -headers "$RDP_OUTPUT/universal/Headers" -output "$RDP_STAGING/ServerDashRDP.xcframework"
rm -rf "$RDP_OUTPUT/ServerDashRDP.xcframework"
mv "$RDP_STAGING/ServerDashRDP.xcframework" "$RDP_OUTPUT/ServerDashRDP.xcframework"
rmdir "$RDP_STAGING"

printf 'RDP dependency build complete: %s\n' "$RDP_OUTPUT/ServerDashRDP.xcframework"
