namespace ServerDash;

/// <summary>
/// Desktop capability flags. <see cref="Windows"/> matches macOS, not the iOS subset.
/// </summary>
public sealed record PlatformCapabilities(
    bool InteractiveShell,
    bool RemoteCommand,
    bool FileTransfer,
    bool LocalForward,
    bool RemoteForward,
    bool DynamicForward,
    bool JumpHosts,
    bool Socks5Proxy,
    bool HttpConnectProxy,
    bool SshAgent,
    bool ExternalPrivateKeyPath)
{
    public static PlatformCapabilities MacOS { get; } = Desktop();

    public static PlatformCapabilities Windows { get; } = Desktop();

    public static PlatformCapabilities Mobile { get; } = new(
        InteractiveShell: true,
        RemoteCommand: true,
        FileTransfer: true,
        LocalForward: false,
        RemoteForward: false,
        DynamicForward: false,
        JumpHosts: false,
        Socks5Proxy: false,
        HttpConnectProxy: false,
        SshAgent: false,
        ExternalPrivateKeyPath: false);

    public static PlatformCapabilities Current =>
        OperatingSystem.IsWindows() ? Windows : MacOS;

    private static PlatformCapabilities Desktop() => new(
        InteractiveShell: true,
        RemoteCommand: true,
        FileTransfer: true,
        LocalForward: true,
        RemoteForward: true,
        DynamicForward: true,
        JumpHosts: true,
        Socks5Proxy: true,
        HttpConnectProxy: true,
        SshAgent: true,
        ExternalPrivateKeyPath: true);
}
