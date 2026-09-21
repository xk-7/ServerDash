using ServerDash.Connections;
using ServerDash.Credentials;
using ServerDash.Models;
using ServerDash.Trust;

namespace ServerDash.Tests;

public sealed class OpenSshConnectionEngineTests
{
    [Fact]
    public async Task Connect_fails_closed_without_openssh()
    {
        var engine = CreateEngine(withBinaries: false, seedHost: true, withPassword: true);
        var error = await Assert.ThrowsAsync<RemoteConnectionFailure>(
            () => engine.ConnectAsync(PasswordConfig(), null));
        Assert.Equal(RemoteConnectionFailureKind.MissingOpenSsh, error.Kind);
    }

    [Fact]
    public async Task Connect_fails_closed_without_credential()
    {
        var engine = CreateEngine(withBinaries: true, seedHost: true, withPassword: false);
        var error = await Assert.ThrowsAsync<RemoteConnectionFailure>(
            () => engine.ConnectAsync(PasswordConfig(), null));
        Assert.Equal(RemoteConnectionFailureKind.MissingCredential, error.Kind);
    }

    [Fact]
    public async Task Connect_fails_closed_on_unknown_host_without_keyscan()
    {
        var engine = CreateEngine(withBinaries: true, seedHost: false, withPassword: true);
        var error = await Assert.ThrowsAsync<RemoteConnectionFailure>(
            () => engine.ConnectAsync(PasswordConfig(), (_, _) => Task.FromResult(RemoteHostTrustDecision.TrustAndStore)));
        Assert.Equal(RemoteConnectionFailureKind.MissingKeyscan, error.Kind);
    }

    [Fact]
    public async Task Connect_rejects_when_handler_rejects()
    {
        var engine = CreateEngine(withBinaries: true, seedHost: false, withPassword: true, scanner: new FakeScanner());
        var error = await Assert.ThrowsAsync<RemoteConnectionFailure>(
            () => engine.ConnectAsync(PasswordConfig(), (_, _) => Task.FromResult(RemoteHostTrustDecision.Reject)));
        Assert.Equal(RemoteConnectionFailureKind.HostKeyRejected, error.Kind);
    }

    [Fact]
    public async Task Connect_returns_session_after_store()
    {
        var engine = CreateEngine(withBinaries: true, seedHost: false, withPassword: true, scanner: new FakeScanner());
        await using var session = await engine.ConnectAsync(
            PasswordConfig(),
            (_, _) => Task.FromResult(RemoteHostTrustDecision.TrustAndStore));
        Assert.NotNull(session);
    }

    [Fact]
    public async Task Connect_uses_stored_host_without_keyscan()
    {
        var engine = CreateEngine(withBinaries: true, seedHost: true, withPassword: true);
        await using var session = await engine.ConnectAsync(PasswordConfig(), null);
        Assert.NotNull(session);
    }

    [Fact]
    public async Task Connect_does_not_silently_run_indirect_routes()
    {
        var engine = CreateEngine(withBinaries: true, seedHost: true, withPassword: true);
        var config = PasswordConfig() with
        {
            Route = new ConnectionRoute
            {
                Name = "jump",
                Hops = ["bastion.example"]
            }
        };

        var error = await Assert.ThrowsAsync<RemoteConnectionFailure>(
            () => engine.ConnectAsync(config, null));
        Assert.Equal(RemoteConnectionFailureKind.IndirectRouteNotImplemented, error.Kind);
    }

    [Fact]
    public void Engine_exposes_macos_equivalent_capabilities()
    {
        var engine = CreateEngine(withBinaries: false, seedHost: false, withPassword: false);
        Assert.Equal(PlatformCapabilities.Windows, engine.Capabilities);
        Assert.Equal(PlatformCapabilities.MacOS, engine.Capabilities);
    }

    private static OpenSshConnectionEngine CreateEngine(
        bool withBinaries,
        bool seedHost,
        bool withPassword,
        IHostKeyScanner? scanner = null)
    {
        var root = Directory.CreateTempSubdirectory("sd-engine-");
        var paths = ApplicationPaths.Isolated(root.FullName);
        paths.EnsureCreated();
        var search = withBinaries ? MakeBinaries(root.FullName) : [Path.Combine(root.FullName, "empty")];
        var locator = new OpenSshLocator(search, pathEntries: []);
        var hosts = new KnownHostsStore(paths.KnownHostsPath);
        if (seedHost)
        {
            hosts.Store("203.0.113.10", 22, "ssh-ed25519", "AAAA");
        }

        var credentials = new InMemoryCredentialStore();
        if (withPassword)
        {
            credentials.SetSecret(PasswordConfig().CredentialId.ToString("D"), "pw");
        }

        return new OpenSshConnectionEngine(locator, hosts, credentials, paths, scanner, new FakeRunner());
    }

    private static string[] MakeBinaries(string root)
    {
        var sshName = OperatingSystem.IsWindows() ? "ssh.exe" : "ssh";
        var sftpName = OperatingSystem.IsWindows() ? "sftp.exe" : "sftp";
        File.WriteAllText(Path.Combine(root, sshName), "placeholder");
        File.WriteAllText(Path.Combine(root, sftpName), "placeholder");
        return [root];
    }

    private static ServerConnectionConfig PasswordConfig() => new()
    {
        Id = Guid.Parse("11111111-1111-1111-1111-111111111111"),
        CredentialId = Guid.Parse("22222222-2222-2222-2222-222222222222"),
        Name = "edge",
        Host = "203.0.113.10",
        Port = 22,
        Username = "operator",
        Authentication = AuthenticationMethod.Password
    };

    private sealed class FakeScanner : IHostKeyScanner
    {
        public HostKeyProbe Scan(string host, int port, string? preferredAlgorithm = null) =>
            HostKeyScanner.Parse(HostKeyScannerTests.SampleLine + "\n", "", host, port, preferredAlgorithm);
    }

    private sealed class FakeRunner : IOpenSshProcessRunner
    {
        public OpenSshProcessResult Run(
            string executable,
            IReadOnlyList<string> arguments,
            IReadOnlyDictionary<string, string>? environment,
            TimeSpan timeout,
            int maxOutputBytes,
            IEnumerable<string>? cleanupPaths,
            CancellationToken cancellationToken = default) =>
            new([], [], 0);

        public OpenSshLiveProcess Start(
            string executable,
            IReadOnlyList<string> arguments,
            IReadOnlyDictionary<string, string>? environment,
            IEnumerable<string>? cleanupPaths) =>
            throw new InvalidOperationException("Live process is not used in these tests.");
    }
}
