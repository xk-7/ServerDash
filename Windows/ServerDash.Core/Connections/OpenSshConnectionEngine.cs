using ServerDash.Credentials;
using ServerDash.Models;
using ServerDash.Trust;

namespace ServerDash.Connections;

public sealed class OpenSshConnectionEngine : IRemoteConnectionEngine
{
    private readonly OpenSshLocator _locator;
    private readonly KnownHostsStore _knownHosts;
    private readonly ICredentialStore _credentials;
    private readonly ApplicationPaths _paths;
    private readonly IHostKeyScanner? _scanner;
    private readonly IOpenSshProcessRunner _runner;

    public OpenSshConnectionEngine(
        OpenSshLocator locator,
        KnownHostsStore knownHosts,
        ICredentialStore credentials,
        ApplicationPaths paths,
        IHostKeyScanner? scanner = null,
        IOpenSshProcessRunner? runner = null)
    {
        _locator = locator;
        _knownHosts = knownHosts;
        _credentials = credentials;
        _paths = paths;
        _scanner = scanner;
        _runner = runner ?? new OpenSshProcessRunner();
    }

    public static OpenSshConnectionEngine CreateDefault()
    {
        var paths = ApplicationPaths.WindowsDefault();
        paths.EnsureCreated();
        var locator = OpenSshLocator.System;
        var runner = new OpenSshProcessRunner();
        return new OpenSshConnectionEngine(
            locator,
            new KnownHostsStore(paths.KnownHostsPath),
            OperatingSystem.IsWindows()
                ? new WindowsCredentialStore()
                : new InMemoryCredentialStore(),
            paths,
            new HostKeyScanner(locator, runner),
            runner);
    }

    public PlatformCapabilities Capabilities => PlatformCapabilities.Windows;

    public OpenSshLaunchPlan BuildLaunchPlan(ServerConnectionConfig config, OpenSshInstall install) =>
        OpenSshArgumentBuilder.Build(install, config, _knownHosts.KnownHostsPath);

    public async Task<IRemoteSession> ConnectAsync(
        ServerConnectionConfig config,
        RemoteHostTrustHandler? trustHandler,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(config);
        cancellationToken.ThrowIfCancellationRequested();

        if (config.IdentityReferenceMissing || string.IsNullOrWhiteSpace(config.Username))
        {
            throw RemoteConnectionFailure.MissingCredential();
        }

        if (!config.Route.IsDirect)
        {
            throw new RemoteConnectionFailure(RemoteConnectionFailureKind.IndirectRouteNotImplemented);
        }

        var install = _locator.Find() ?? throw RemoteConnectionFailure.MissingOpenSsh();
        EnsureCredential(config);

        var knownHostsPath = _knownHosts.KnownHostsPath;
        var stored = _knownHosts.Find(config.Host, config.Port);
        HostKeyProbe? probe = null;
        if (stored.Count == 0 || NeedsRescan(stored, config, out probe))
        {
            probe ??= Scan(config.Host, config.Port);
            if (trustHandler is null)
            {
                throw RemoteConnectionFailure.HostKeyRejected();
            }

            var decision = await trustHandler(probe.ToPresentation(), cancellationToken).ConfigureAwait(false);
            switch (decision)
            {
                case RemoteHostTrustDecision.Reject:
                    throw RemoteConnectionFailure.HostKeyRejected();
                case RemoteHostTrustDecision.TrustAndStore:
                    _knownHosts.StoreLine(config.Host, config.Port, probe.KeyLine);
                    foreach (var extra in probe.AdditionalKeyLines)
                    {
                        try
                        {
                            _knownHosts.StoreLine(config.Host, config.Port, extra);
                        }
                        catch (ArgumentException)
                        {
                        }
                    }

                    knownHostsPath = _knownHosts.KnownHostsPath;
                    break;
                case RemoteHostTrustDecision.TrustOnce:
                    knownHostsPath = WriteOnceHosts(probe);
                    break;
            }
        }

        _ = BuildLaunchPlan(config, install);
        return new OpenSshRemoteSession(install, config, knownHostsPath, _runner, _credentials, _paths);
    }

    private bool NeedsRescan(IReadOnlyList<KnownHostKey> stored, ServerConnectionConfig config, out HostKeyProbe? probe)
    {
        probe = null;
        if (_scanner is null && (_locator.Find()?.KeyscanPath is null))
        {
            return false;
        }

        try
        {
            probe = Scan(config.Host, config.Port);
        }
        catch (RemoteConnectionFailure)
        {
            return false;
        }

        var storedLine = stored[0].KeyLine;
        var storedFingerprint = HostKeyScanner.Fingerprint(storedLine);
        return storedFingerprint is not null && storedFingerprint != probe.Fingerprint;
    }

    private HostKeyProbe Scan(string host, int port)
    {
        var scanner = _scanner ?? new HostKeyScanner(_locator, _runner);
        return scanner.Scan(host, port);
    }

    private string WriteOnceHosts(HostKeyProbe probe)
    {
        _paths.EnsureCreated();
        var path = Path.Combine(_paths.TemporaryDirectory, $"serverdash-known-once-{Guid.NewGuid():N}");
        var once = new KnownHostsStore(path);
        once.StoreLine(probe.Host, probe.Port, probe.KeyLine);
        return path;
    }

    private void EnsureCredential(ServerConnectionConfig config)
    {
        if (config.Authentication is AuthenticationMethod.Password or AuthenticationMethod.KeyThenPassword)
        {
            if (!_credentials.HasSecret(config.CredentialId.ToString("D")))
            {
                throw RemoteConnectionFailure.MissingCredential();
            }
        }

        if (config.Authentication is AuthenticationMethod.PrivateKey or AuthenticationMethod.KeyThenPassword)
        {
            var hasKeyFile = !string.IsNullOrWhiteSpace(config.PrivateKeyPath) && File.Exists(config.PrivateKeyPath);
            var hasImported = config.UsesImportedKey && _credentials.HasSecret(config.CredentialId.ToString("D"));
            if (!hasKeyFile && !hasImported)
            {
                throw RemoteConnectionFailure.MissingCredential();
            }
        }
    }
}
