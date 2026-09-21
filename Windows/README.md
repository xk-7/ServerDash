# ServerDash for Windows

WinUI 3 / .NET 8 workbench that aligns with the macOS desktop feature set.
This directory exists only on `windows/align-macos`. It is **not** a released
client. See [Docs/WINDOWS.md](../Docs/WINDOWS.md) and
[ADR-0007](../Docs/ArchitectureDecisions/ADR-0007-windows-winui-client.md).

## Requirements

- Windows 10 1809 or Windows 11
- .NET 8 SDK
- Windows App SDK 1.6 (restored by NuGet)
- Visual Studio 2022 (17.8+) with the WinUI workload, or `dotnet build` on x64
- Optional Features → **OpenSSH Client** (`ssh.exe` and `sftp.exe`)

The application fails closed if OpenSSH is missing. It does not bundle an SSH
server, does not accept unknown hosts automatically, and does not read the
macOS SwiftData or Keychain stores.

## Build

```powershell
cd Windows
dotnet test ServerDash.Tests\ServerDash.Tests.csproj
dotnet build ServerDash.App\ServerDash.App.csproj -c Debug -p:Platform=x64
```

`ServerDash.Core` and the tests target `net8.0` and can run wherever the SDK
exists. `ServerDash.App` is `net8.0-windows10.0.19041.0` and builds on Windows
only.

## Layout

| Project | Role |
| --- | --- |
| `ServerDash.Core` | Capabilities, models, remote contracts, OpenSSH launch plan, trust file, credential store |
| `ServerDash.App` | Single-window WinUI shell |
| `ServerDash.Tests` | Contract and fail-closed tests |

Data root: `%LOCALAPPDATA%\ServerDash\`
Known hosts: `%LOCALAPPDATA%\ServerDash\known_hosts`
Host catalog: `%LOCALAPPDATA%\ServerDash\Data\hosts.json`

P1 provides host add/connect, TOFU, fallback monitoring, a basic SSH stream,
and SFTP list/get/put. It is not a complete macOS workbench. RDP is not included.
