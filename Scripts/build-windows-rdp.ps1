param([string]$BuildRoot = (Join-Path $PSScriptRoot '../.build/windows-rdp'))
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
if (-not $IsWindows) { throw 'Run this script on Windows x64.' }
$SourceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
New-Item -ItemType Directory -Force $BuildRoot | Out-Null
$Prefix = Join-Path $BuildRoot 'install'
$Downloads = Join-Path $BuildRoot 'downloads'
$Sources = Join-Path $BuildRoot 'sources'
New-Item -ItemType Directory -Force $Downloads, $Sources | Out-Null

# Load the x64 MSVC environment without changing the caller's PowerShell profile.
$VSWhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$VS = & $VSWhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $VS) { throw 'Visual Studio C++ Build Tools and Windows SDK are required.' }
Import-Module (Join-Path $VS 'Common7/Tools/Microsoft.VisualStudio.DevShell.dll')
Enter-VsDevShell -VsInstallPath $VS -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'
if (Test-Path 'C:/Strawberry/perl/bin/perl.exe') { $env:PATH = "C:/Strawberry/perl/bin;$env:PATH" }
Get-Command perl, nmake, cmake | Out-Null

function Get-VerifiedSource([string]$Name, [string]$Url) {
    $Archive = Join-Path $Downloads "$Name.tar.gz"
    $Expected = (Get-Content (Join-Path $SourceRoot 'Vendor/RDP/dependencies.sha256') |
        Where-Object { $_.EndsWith("  $Name.tar.gz") }).Split(' ')[0]
    if (-not $Expected) { throw "Missing checksum for $Name" }
    if (-not (Test-Path $Archive)) { Invoke-WebRequest $Url -OutFile $Archive }
    if ((Get-FileHash $Archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Expected) { throw "Checksum mismatch: $Name" }
    if (-not (Test-Path (Join-Path $Sources $Name))) { & tar -xzf $Archive -C $Sources }
    return Join-Path $Sources $Name
}
$OpenSSL = Get-VerifiedSource 'openssl-3.5.8' 'https://github.com/openssl/openssl/releases/download/openssl-3.5.8/openssl-3.5.8.tar.gz'
$FreeRDP = Get-VerifiedSource 'freerdp-3.31.0' 'https://pub.freerdp.com/releases/freerdp-3.31.0.tar.gz'
$OpenSSLBuild = Join-Path $BuildRoot 'openssl'
New-Item -ItemType Directory -Force $OpenSSLBuild | Out-Null
if (-not (Test-Path (Join-Path $Prefix 'lib/libssl.lib'))) {
    Push-Location $OpenSSLBuild
    try {
        & perl (Join-Path $OpenSSL 'Configure') VC-WIN64A no-shared no-tests no-module no-asm "--prefix=$Prefix" --libdir=lib
        & nmake build_libs
        & nmake install_dev
    } finally { Pop-Location }
}
$FreeRDPBuild = Join-Path $BuildRoot 'freerdp'
& cmake -S $FreeRDP -B $FreeRDPBuild -A x64 "-DCMAKE_INSTALL_PREFIX=$Prefix" "-DOPENSSL_ROOT_DIR=$Prefix" `
    -DOPENSSL_USE_STATIC_LIBS=ON -DBUILD_SHARED_LIBS=ON -DWITH_CLIENT=OFF -DWITH_CLIENT_COMMON=ON -DWITH_CLIENT_CHANNELS=ON `
    -DWITH_SERVER=OFF -DWITH_SERVER_CHANNELS=OFF -DWITH_SAMPLE=OFF -DWITH_X11=OFF -DWITH_FFMPEG=OFF `
    -DWITH_SWSCALE=OFF -DWITH_OPENH264=OFF -DWITH_JPEG=OFF -DWITH_OPUS=OFF -DWITH_URIPARSER=OFF `
    -DWITH_CUPS=OFF -DWITH_PCSC=OFF -DWITH_PKCS11=OFF -DWITH_SMARTCARD_EMULATE=OFF -DWITH_WINPR_TOOLS=OFF `
    -DWITH_MANPAGES=OFF -DWITH_AAD=OFF -DWITH_JSON_DISABLED=ON -DWITH_KRB5=OFF -DWITH_FUSE=OFF `
    -DCHANNEL_URBDRC=OFF -DCHANNEL_SMARTCARD=OFF -DCHANNEL_PRINTER=OFF -DCHANNEL_AUDIN=OFF `
    -DCHANNEL_VIDEO=OFF -DCHANNEL_TSMF=OFF -DBUILD_TESTING=OFF -DWITH_CCACHE=OFF -DWITH_CLANG_FORMAT=OFF
& cmake --build $FreeRDPBuild --config Release --parallel 4
& cmake --install $FreeRDPBuild --config Release
$DisplayBuild = Join-Path $BuildRoot 'display'
& cmake -S (Join-Path $SourceRoot 'Desktop/native/rdp') -B $DisplayBuild -A x64 "-DCMAKE_PREFIX_PATH=$Prefix" "-DCMAKE_INSTALL_PREFIX=$Prefix"
& cmake --build $DisplayBuild --config Release --parallel 4
& cmake --install $DisplayBuild --config Release
$env:PATH = "$(Join-Path $Prefix 'bin');$env:PATH"
& ctest --test-dir $DisplayBuild -C Release --output-on-failure
# This artifact is a display/build probe, not an enabled RDP client.
Copy-Item (Join-Path $FreeRDP 'LICENSE') (Join-Path $Prefix 'LICENSE-FreeRDP.txt')
Copy-Item (Join-Path $OpenSSL 'LICENSE.txt') (Join-Path $Prefix 'LICENSE-OpenSSL.txt')
