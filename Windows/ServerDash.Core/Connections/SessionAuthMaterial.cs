using ServerDash.Credentials;
using ServerDash.Models;

namespace ServerDash.Connections;

public sealed class SessionAuthMaterial : IDisposable
{
    private readonly List<string> _cleanup = [];
    private bool _disposed;

    private SessionAuthMaterial(Dictionary<string, string> environment, string? identityFile)
    {
        Environment = environment;
        IdentityFile = identityFile;
    }

    public IReadOnlyDictionary<string, string> Environment { get; }
    public string? IdentityFile { get; }
    public IReadOnlyList<string> CleanupPaths => _cleanup;

    public static SessionAuthMaterial Prepare(
        ServerConnectionConfig config,
        ICredentialStore credentials,
        ApplicationPaths paths)
    {
        paths.EnsureCreated();
        var environment = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        string? identity = string.IsNullOrWhiteSpace(config.PrivateKeyPath) ? null : config.PrivateKeyPath;
        var account = config.CredentialId.ToString("D");

        if (config.Authentication is AuthenticationMethod.Password or AuthenticationMethod.KeyThenPassword
            || config.HasPassphrase)
        {
            if (!credentials.TryGetSecret(account, out var secret) || string.IsNullOrEmpty(secret))
            {
                if (config.Authentication != AuthenticationMethod.PrivateKey || config.HasPassphrase)
                {
                    throw RemoteConnectionFailure.MissingCredential();
                }
            }
            else
            {
                var secretFile = UniqueTemp(paths, "askpass-secret");
                File.WriteAllText(secretFile, secret);
                var helper = WriteAskPassHelper(paths);
                environment["SERVERDASH_ASKPASS_FILE"] = secretFile;
                environment["SSH_ASKPASS"] = helper;
                environment["SSH_ASKPASS_REQUIRE"] = "force";
                environment["DISPLAY"] = environment.GetValueOrDefault("DISPLAY") ?? "localhost:0";
                environment["SSH_AUTH_SOCK"] = "";
            }
        }

        if (config.UsesImportedKey && credentials.TryGetSecret(account, out var keyBody)
            && keyBody.Contains("BEGIN", StringComparison.Ordinal))
        {
            identity = UniqueTemp(paths, "id");
            File.WriteAllText(identity, keyBody);
            if (!OperatingSystem.IsWindows())
            {
                File.SetUnixFileMode(identity, UnixFileMode.UserRead | UnixFileMode.UserWrite);
            }
        }

        var material = new SessionAuthMaterial(environment, identity);
        foreach (var path in environment.Values.Concat(identity is null ? [] : new[] { identity }))
        {
            if (path.Contains("serverdash-", StringComparison.OrdinalIgnoreCase)
                && File.Exists(path)
                && Path.GetDirectoryName(path) == Path.GetFullPath(paths.TemporaryDirectory))
            {
                material._cleanup.Add(path);
            }
        }

        if (identity is not null && identity != config.PrivateKeyPath)
        {
            material._cleanup.Add(identity);
        }

        if (environment.TryGetValue("SERVERDASH_ASKPASS_FILE", out var ask) && File.Exists(ask))
        {
            material._cleanup.Add(ask);
        }

        return material;
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        TemporaryFiles.Delete(_cleanup);
    }

    private static string UniqueTemp(ApplicationPaths paths, string prefix)
    {
        paths.EnsureCreated();
        return Path.Combine(paths.TemporaryDirectory, $"serverdash-{prefix}-{Guid.NewGuid():N}");
    }

    private static string WriteAskPassHelper(ApplicationPaths paths)
    {
        if (OperatingSystem.IsWindows())
        {
            var file = Path.Combine(paths.TemporaryDirectory, "serverdash-askpass.cmd");
            File.WriteAllText(file, "@echo off\r\nif exist \"%SERVERDASH_ASKPASS_FILE%\" type \"%SERVERDASH_ASKPASS_FILE%\"\r\n");
            return file;
        }

        var script = Path.Combine(paths.TemporaryDirectory, "serverdash-askpass.sh");
        File.WriteAllText(script, "#!/bin/sh\ncat \"$SERVERDASH_ASKPASS_FILE\"\n");
        File.SetUnixFileMode(script, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        return script;
    }
}
