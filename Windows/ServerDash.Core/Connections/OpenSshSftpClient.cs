using ServerDash.Credentials;
using ServerDash.Models;

namespace ServerDash.Connections;

public sealed class SftpClientException : Exception
{
    public SftpClientException(string message) : base(message) { }
}

public sealed class OpenSshSftpClient : IRemoteFileClient
{
    private readonly OpenSshInstall _install;
    private readonly ServerConnectionConfig _config;
    private readonly string _knownHostsPath;
    private readonly IOpenSshProcessRunner _runner;
    private readonly ICredentialStore _credentials;
    private readonly ApplicationPaths _paths;
    private CancellationTokenSource? _operation;

    public OpenSshSftpClient(
        OpenSshInstall install,
        ServerConnectionConfig config,
        string knownHostsPath,
        IOpenSshProcessRunner runner,
        ICredentialStore credentials,
        ApplicationPaths paths)
    {
        _install = install;
        _config = config;
        _knownHostsPath = knownHostsPath;
        _runner = runner;
        _credentials = credentials;
        _paths = paths;
    }

    public Task<SftpDirectoryListing> ListAsync(string path, CancellationToken cancellationToken = default)
    {
        ValidatePath(path);
        var output = Run(["cd " + Quote(path), "pwd", "ls -la"], cancellationToken);
        return Task.FromResult(SftpListingParser.Parse(output, path));
    }

    public Task CreateDirectoryAsync(string name, string path, CancellationToken cancellationToken = default)
    {
        ValidateName(name);
        ValidatePath(path);
        Run(["mkdir " + Quote(RemotePath.Child(name, path))], cancellationToken);
        return Task.CompletedTask;
    }

    public Task CreateFileAsync(string name, string path, CancellationToken cancellationToken = default)
    {
        ValidateName(name);
        ValidatePath(path);
        var empty = Path.Combine(_paths.TemporaryDirectory, $"serverdash-empty-{Guid.NewGuid():N}");
        Directory.CreateDirectory(_paths.TemporaryDirectory);
        File.WriteAllBytes(empty, []);
        try
        {
            Run(["put " + Quote(empty) + " " + Quote(RemotePath.Child(name, path))], cancellationToken);
        }
        finally
        {
            TemporaryFiles.Delete([empty]);
        }

        return Task.CompletedTask;
    }

    public Task RenameAsync(RemoteFileItem item, string newName, CancellationToken cancellationToken = default)
    {
        ValidateName(newName);
        ValidatePath(item.Path);
        var destination = RemotePath.Child(newName, RemotePath.Parent(item.Path));
        Run(["rename " + Quote(item.Path) + " " + Quote(destination)], cancellationToken);
        return Task.CompletedTask;
    }

    public Task MoveAsync(RemoteFileItem item, string directory, CancellationToken cancellationToken = default)
    {
        ValidatePath(item.Path);
        ValidatePath(directory);
        var destination = RemotePath.Child(item.Name, directory);
        Run(["rename " + Quote(item.Path) + " " + Quote(destination)], cancellationToken);
        return Task.CompletedTask;
    }

    public Task DeleteAsync(RemoteFileItem item, bool recursive, CancellationToken cancellationToken = default)
    {
        ValidatePath(item.Path);
        if (item.IsDirectory && recursive)
        {
            var listing = ListAsync(item.Path, cancellationToken).GetAwaiter().GetResult();
            foreach (var child in listing.Items)
            {
                DeleteAsync(child, child.IsDirectory, cancellationToken).GetAwaiter().GetResult();
            }
        }

        Run([(item.IsDirectory ? "rmdir " : "rm ") + Quote(item.Path)], cancellationToken);
        return Task.CompletedTask;
    }

    public Task UploadAsync(
        string localPath,
        string remotePath,
        Action<SftpProgress>? onProgress,
        CancellationToken cancellationToken = default)
    {
        ValidatePath(localPath);
        ValidatePath(remotePath);
        if (!File.Exists(localPath) && !Directory.Exists(localPath))
        {
            throw new SftpClientException("本地文件不存在。");
        }

        onProgress?.Invoke(new SftpProgress(0, 0, 0, TimeSpan.Zero, "正在上传", true));
        var flag = Directory.Exists(localPath) ? "put -pR " : "put -p ";
        Run([flag + Quote(localPath) + " " + Quote(remotePath)], cancellationToken);
        return Task.CompletedTask;
    }

    public Task DownloadAsync(
        string remotePath,
        long size,
        string localPath,
        Action<SftpProgress>? onProgress,
        CancellationToken cancellationToken = default)
    {
        ValidatePath(remotePath);
        ValidatePath(localPath);
        onProgress?.Invoke(new SftpProgress(0, size, 0, TimeSpan.Zero, "正在下载", true));
        Run(["get -p " + Quote(remotePath) + " " + Quote(localPath)], cancellationToken);
        EnsureDownloadArrived(localPath);
        return Task.CompletedTask;
    }

    public Task CancelCurrentOperationAsync()
    {
        _operation?.Cancel();
        return Task.CompletedTask;
    }

    public Task CloseAsync() => CancelCurrentOperationAsync();

    public async ValueTask DisposeAsync() => await CloseAsync().ConfigureAwait(false);

    public static void EnsureDownloadArrived(string localPath)
    {
        if (!File.Exists(localPath) && !Directory.Exists(localPath))
        {
            throw new SftpClientException("传输未完成，未将半成品标为成功：" + Path.GetFileName(localPath));
        }
    }

    public static string Quote(string value)
    {
        var result = "\"";
        foreach (var character in value)
        {
            if (character is '\\' or '"')
            {
                result += "\\";
            }

            result += character;
        }

        return result + "\"";
    }

    public static void ValidatePath(string path)
    {
        if (string.IsNullOrWhiteSpace(path) || path.IndexOfAny(['\n', '\r', '\0']) >= 0)
        {
            throw new SftpClientException("路径不能包含换行或控制字符。");
        }
    }

    public static void ValidateName(string name)
    {
        ValidatePath(name);
        var trimmed = name.Trim();
        if (trimmed.Length == 0 || trimmed.Contains('/') || trimmed is "." or "..")
        {
            throw new SftpClientException("名称不能为空，也不能包含“/”。");
        }
    }

    private string Run(IReadOnlyList<string> commands, CancellationToken cancellationToken)
    {
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        _operation = linked;
        using var auth = SessionAuthMaterial.Prepare(_config, _credentials, _paths);
        var batch = Path.Combine(_paths.TemporaryDirectory, $"serverdash-sftp-{Guid.NewGuid():N}.batch");
        Directory.CreateDirectory(_paths.TemporaryDirectory);
        File.WriteAllLines(batch, commands.Append("quit"));
        try
        {
            var plan = OpenSshArgumentBuilder.BuildSftp(
                _install,
                _config,
                _knownHostsPath,
                batch,
                auth.IdentityFile);
            var result = _runner.Run(
                plan.Executable,
                plan.Arguments,
                auth.Environment,
                TimeSpan.FromMinutes(2),
                512_000,
                auth.CleanupPaths.Append(batch),
                linked.Token);
            if (result.ExitCode != 0)
            {
                throw new SftpClientException(
                    string.IsNullOrWhiteSpace(result.ErrorText) ? "SFTP 操作失败。" : result.ErrorText.Trim());
            }

            return result.OutputText;
        }
        finally
        {
            TemporaryFiles.Delete([batch]);
            if (ReferenceEquals(_operation, linked))
            {
                _operation = null;
            }
        }
    }
}

public static class RemotePath
{
    public static string Child(string name, string directory)
    {
        var basePath = directory == "/" ? "" : directory.Trim('/');
        return Normalize("/" + basePath + "/" + name);
    }

    public static string Parent(string path)
    {
        var normalized = Normalize(path);
        if (normalized == "/")
        {
            return "/";
        }

        var slash = normalized.LastIndexOf('/');
        return slash <= 0 ? "/" : normalized[..slash];
    }

    public static string Normalize(string path)
    {
        if (path == ".")
        {
            return ".";
        }

        var parts = new List<string>();
        foreach (var component in path.Split('/', StringSplitOptions.RemoveEmptyEntries))
        {
            if (component == ".")
            {
                continue;
            }

            if (component == "..")
            {
                if (parts.Count > 0)
                {
                    parts.RemoveAt(parts.Count - 1);
                }

                continue;
            }

            parts.Add(component);
        }

        return "/" + string.Join('/', parts);
    }
}

public static class SftpListingParser
{
    public static SftpDirectoryListing Parse(string output, string fallbackPath)
    {
        var canonical = fallbackPath;
        foreach (var raw in output.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
        {
            const string marker = "Remote working directory:";
            var index = raw.IndexOf(marker, StringComparison.Ordinal);
            if (index >= 0)
            {
                canonical = raw[(index + marker.Length)..].Trim();
                break;
            }
        }

        canonical = RemotePath.Normalize(canonical);
        var items = output
            .Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries)
            .Select(line => ParseLine(line, canonical))
            .OfType<RemoteFileItem>()
            .OrderByDescending(item => item.IsDirectory)
            .ThenBy(item => item.Name, StringComparer.OrdinalIgnoreCase)
            .ToArray();
        return new SftpDirectoryListing(canonical, items);
    }

    private static RemoteFileItem? ParseLine(string line, string directory)
    {
        var fields = line.Split((char[]?)null, 9, StringSplitOptions.RemoveEmptyEntries);
        if (fields.Length < 9)
        {
            return null;
        }

        var permissions = fields[0];
        if (permissions.Length < 10 || !long.TryParse(fields[4], out var size))
        {
            return null;
        }

        var name = fields[8];
        if (permissions[0] == 'l')
        {
            var arrow = name.IndexOf(" -> ", StringComparison.Ordinal);
            if (arrow >= 0)
            {
                name = name[..arrow];
            }
        }

        if (name is "." or "..")
        {
            return null;
        }

        var kind = permissions[0] switch
        {
            'd' => RemoteFileKind.Directory,
            '-' => RemoteFileKind.File,
            'l' => RemoteFileKind.SymbolicLink,
            _ => RemoteFileKind.Other
        };
        return new RemoteFileItem(
            RemotePath.Child(name, directory),
            name,
            kind,
            size,
            permissions,
            fields[2],
            fields[3],
            $"{fields[5]} {fields[6]} {fields[7]}");
    }
}
