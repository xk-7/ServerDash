using ServerDash.Models;

namespace ServerDash.Connections;

public enum RemoteHostTrustDecision
{
    TrustOnce,
    TrustAndStore,
    Reject
}

public sealed record RemoteHostKeyPresentation(
    string Host,
    int Port,
    string Algorithm,
    byte[] KeyBlob,
    string Fingerprint,
    string KeyLine);

public delegate Task<RemoteHostTrustDecision> RemoteHostTrustHandler(
    RemoteHostKeyPresentation presentation,
    CancellationToken cancellationToken);

public sealed record RemoteCommandResult(byte[] Stdout, byte[] Stderr, int? ExitCode)
{
    public string Output => System.Text.Encoding.UTF8.GetString(Stdout);
    public string ErrorOutput => System.Text.Encoding.UTF8.GetString(Stderr);
}

public sealed record RemoteShellDimensions(int Columns, int Rows, int PixelWidth = 0, int PixelHeight = 0)
{
    public static RemoteShellDimensions Standard { get; } = new(80, 24);

    public RemoteShellDimensions Normalized => new(
        Math.Max(2, Columns),
        Math.Max(2, Rows),
        Math.Max(0, PixelWidth),
        Math.Max(0, PixelHeight));
}

public enum RemoteFileKind
{
    File,
    Directory,
    SymbolicLink,
    Other
}

public sealed record RemoteFileItem(
    string Path,
    string Name,
    RemoteFileKind Kind,
    long Size,
    string Permissions,
    string Owner,
    string Group,
    string ModifiedText)
{
    public bool IsDirectory => Kind == RemoteFileKind.Directory;
}

public sealed record SftpDirectoryListing(string Path, IReadOnlyList<RemoteFileItem> Items);

public sealed record SftpProgress(
    long TransferredBytes,
    long TotalBytes,
    double SpeedBytesPerSecond,
    TimeSpan Remaining,
    string Message,
    bool IsIndeterminate = false)
{
    public double Fraction => TotalBytes <= 0
        ? 0
        : Math.Min(1, (double)TransferredBytes / TotalBytes);
}

public interface IRemoteConnectionEngine
{
    PlatformCapabilities Capabilities { get; }

    Task<IRemoteSession> ConnectAsync(
        ServerConnectionConfig config,
        RemoteHostTrustHandler? trustHandler,
        CancellationToken cancellationToken = default);
}

public interface IRemoteSession : IAsyncDisposable
{
    Task<RemoteCommandResult> ExecuteAsync(
        string command,
        TimeSpan timeout,
        int maxOutputBytes,
        CancellationToken cancellationToken = default);

    Task<IRemoteShellSession> OpenShellAsync(
        RemoteShellDimensions dimensions,
        CancellationToken cancellationToken = default);

    Task<IRemoteFileClient> OpenSftpAsync(CancellationToken cancellationToken = default);

    Task CloseAsync();
}

public interface IRemoteShellSession : IAsyncDisposable
{
    IAsyncEnumerable<byte[]> Events { get; }

    Task WriteAsync(ReadOnlyMemory<byte> data, CancellationToken cancellationToken = default);

    Task ResizeAsync(RemoteShellDimensions dimensions, CancellationToken cancellationToken = default);

    Task CloseAsync();
}

public interface IRemoteFileClient : IAsyncDisposable
{
    Task<SftpDirectoryListing> ListAsync(string path, CancellationToken cancellationToken = default);

    Task CreateDirectoryAsync(string name, string path, CancellationToken cancellationToken = default);

    Task CreateFileAsync(string name, string path, CancellationToken cancellationToken = default);

    Task RenameAsync(RemoteFileItem item, string newName, CancellationToken cancellationToken = default);

    Task MoveAsync(RemoteFileItem item, string directory, CancellationToken cancellationToken = default);

    Task DeleteAsync(RemoteFileItem item, bool recursive, CancellationToken cancellationToken = default);

    Task UploadAsync(
        string localPath,
        string remotePath,
        Action<SftpProgress>? onProgress,
        CancellationToken cancellationToken = default);

    Task DownloadAsync(
        string remotePath,
        long size,
        string localPath,
        Action<SftpProgress>? onProgress,
        CancellationToken cancellationToken = default);

    Task CancelCurrentOperationAsync();

    Task CloseAsync();
}
