namespace ServerDash.Connections;

public sealed record OpenSshInstall(string SshPath, string SftpPath, string? KeyscanPath = null);

/// <summary>
/// Locates system OpenSSH. Missing ssh or sftp is a hard failure.
/// </summary>
public sealed class OpenSshLocator
{
    private readonly IReadOnlyList<string> _searchDirectories;
    private readonly IReadOnlyList<string> _pathEntries;

    public OpenSshLocator(
        IEnumerable<string>? searchDirectories = null,
        IEnumerable<string>? pathEntries = null)
    {
        _searchDirectories = searchDirectories?.ToArray() ?? DefaultDirectories();
        _pathEntries = pathEntries?.ToArray() ?? SplitPath();
    }

    public static OpenSshLocator System { get; } = new();

    public OpenSshInstall? Find()
    {
        var ssh = FindBinary("ssh");
        var sftp = FindBinary("sftp");
        if (ssh is null || sftp is null)
        {
            return null;
        }

        return new OpenSshInstall(ssh, sftp, FindBinary("ssh-keyscan"));
    }

    public OpenSshInstall Require() =>
        Find() ?? throw RemoteConnectionFailure.MissingOpenSsh();

    private string? FindBinary(string name)
    {
        var fileName = OperatingSystem.IsWindows() ? name + ".exe" : name;
        foreach (var directory in _searchDirectories.Concat(_pathEntries))
        {
            if (string.IsNullOrWhiteSpace(directory))
            {
                continue;
            }

            var candidate = Path.Combine(directory, fileName);
            if (File.Exists(candidate))
            {
                return Path.GetFullPath(candidate);
            }
        }

        return null;
    }

    private static string[] DefaultDirectories()
    {
        if (!OperatingSystem.IsWindows())
        {
            return ["/usr/bin", "/usr/local/bin", "/opt/homebrew/bin"];
        }

        var systemRoot = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        if (string.IsNullOrWhiteSpace(systemRoot))
        {
            systemRoot = @"C:\Windows";
        }

        return
        [
            Path.Combine(systemRoot, "System32", "OpenSSH"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "OpenSSH"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "OpenSSH")
        ];
    }

    private static string[] SplitPath()
    {
        var path = Environment.GetEnvironmentVariable("PATH") ?? "";
        return path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
    }
}
