#!/bin/bash
set -euo pipefail
RDP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RDP_BUILD="$RDP_ROOT/.build/rdp"
mkdir -p "$RDP_BUILD/downloads" "$RDP_BUILD/sources" "$RDP_BUILD/tools" "$RDP_BUILD/universal"
download() {
    if [[ ! -f "$RDP_BUILD/downloads/$1" ]]; then
        curl --fail --location --proto '=https' --max-time 300 "$2" --output "$RDP_BUILD/downloads/$1"
    fi
}
download freerdp-3.31.0.tar.gz https://pub.freerdp.com/releases/freerdp-3.31.0.tar.gz
download openssl-3.5.8.tar.gz https://github.com/openssl/openssl/releases/download/openssl-3.5.8/openssl-3.5.8.tar.gz
download cmake-3.31.12-macos-universal.tar.gz https://github.com/Kitware/CMake/releases/download/v3.31.12/cmake-3.31.12-macos-universal.tar.gz
(cd "$RDP_BUILD/downloads" && shasum -a 256 -c "$RDP_ROOT/Vendor/RDP/dependencies.sha256")
for RDP_NAME in freerdp-3.31.0 openssl-3.5.8; do
    if [[ ! -d "$RDP_BUILD/sources/$RDP_NAME" ]]; then
        tar -xzf "$RDP_BUILD/downloads/$RDP_NAME.tar.gz" -C "$RDP_BUILD/sources"
    fi
done
if [[ ! -d "$RDP_BUILD/tools/cmake-3.31.12-macos-universal" ]]; then
    tar -xzf "$RDP_BUILD/downloads/cmake-3.31.12-macos-universal.tar.gz" -C "$RDP_BUILD/tools"
fi
RDP_CMAKE="$RDP_BUILD/tools/cmake-3.31.12-macos-universal/CMake.app/Contents/bin/cmake"
RDP_SDK="$(xcrun --sdk macosx --show-sdk-path)"
for RDP_ARCH in arm64 x86_64; do
    RDP_PREFIX="$RDP_BUILD/install-$RDP_ARCH"
    mkdir -p "$RDP_BUILD/openssl-$RDP_ARCH"
    if [[ ! -f "$RDP_PREFIX/lib/libssl.a" ]]; then
        (cd "$RDP_BUILD/openssl-$RDP_ARCH"
         "$RDP_BUILD/sources/openssl-3.5.8/Configure" "darwin64-$RDP_ARCH-cc" \
             no-shared no-tests no-module --libdir=lib --prefix="$RDP_PREFIX" \
             -mmacosx-version-min=14.0 -isysroot "$RDP_SDK"
         make -j4 build_libs
         make install_dev)
    fi
    "$RDP_CMAKE" -S "$RDP_BUILD/sources/freerdp-3.31.0" -B "$RDP_BUILD/freerdp-$RDP_ARCH" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF -DCMAKE_OSX_ARCHITECTURES="$RDP_ARCH" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_OSX_SYSROOT="$RDP_SDK" \
        -DCMAKE_INSTALL_PREFIX="$RDP_PREFIX" -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" \
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
        -DWITH_CCACHE=OFF -DWITH_CLANG_FORMAT=OFF -DWITH_TLS_DATA_LIMIT=ON
    "$RDP_CMAKE" --build "$RDP_BUILD/freerdp-$RDP_ARCH" --parallel 4
    "$RDP_CMAKE" --install "$RDP_BUILD/freerdp-$RDP_ARCH"
    /usr/bin/libtool -static -o "$RDP_BUILD/libServerDashRDP-$RDP_ARCH.a" "$RDP_PREFIX"/lib/lib*.a "$RDP_PREFIX"/lib/freerdp3/lib*.a
done
lipo -create "$RDP_BUILD/libServerDashRDP-arm64.a" "$RDP_BUILD/libServerDashRDP-x86_64.a" \
    -output "$RDP_BUILD/universal/libServerDashRDP.a"
mkdir -p "$RDP_BUILD/universal/Headers"
cp -R "$RDP_BUILD/install-arm64/include/." "$RDP_BUILD/universal/Headers/"
# XCFramework creation never overwrites an existing bundle. Use a fresh staging directory.
RDP_STAGING="$(mktemp -d "$RDP_BUILD/xcframework.XXXXXX")"
xcodebuild -create-xcframework -library "$RDP_BUILD/universal/libServerDashRDP.a" \
    -headers "$RDP_BUILD/universal/Headers" -output "$RDP_STAGING/ServerDashRDP.xcframework"
if [[ -d "$RDP_BUILD/ServerDashRDP.xcframework" ]]; then
    mv "$RDP_BUILD/ServerDashRDP.xcframework" "$RDP_STAGING/previous.xcframework"
fi
mv "$RDP_STAGING/ServerDashRDP.xcframework" "$RDP_BUILD/ServerDashRDP.xcframework"
printf 'RDP dependency build complete: %s\n' "$RDP_BUILD/ServerDashRDP.xcframework"
