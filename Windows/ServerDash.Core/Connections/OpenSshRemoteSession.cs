using System.Threading.Channels;
using ServerDash.Credentials;
using ServerDash.Models;

namespace ServerDash.Connections;

public sealed class OpenSshRemoteSession : IRemoteSession
{
    private readonly OpenSshInstall _install;
    private readonly ServerConnectionConfig _config;
    private readonly string _knownHostsPath;
    private readonly IOpenSshProcessRunner _runner;
    private readonly ICredentialStore _credentials;
    private readonly ApplicationPaths _paths;
    private bool _closed;

    public OpenSshRemoteSession(
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

    public Task<RemoteCommandResult> ExecuteAsync(
        string command,
        TimeSpan timeout,
        int maxOutputBytes,
        CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(_closed, this);
        using var auth = SessionAuthMaterial.Prepare(_config, _credentials, _paths);
        var plan = OpenSshArgumentBuilder.Build(
            _install,
            _config,
            _knownHostsPath,
            auth.IdentityFile,
            ["--", command]);
        var result = _runner.Run(
            plan.Executable,
            plan.Arguments,
            auth.Environment,
            timeout,
            maxOutputBytes,
            auth.CleanupPaths,
            cancellationToken);
        return Task.FromResult(new RemoteCommandResult(result.Stdout, result.Stderr, result.ExitCode));
    }

    public Task<IRemoteShellSession> OpenShellAsync(
        RemoteShellDimensions dimensions,
        CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(_closed, this);
        cancellationToken.ThrowIfCancellationRequested();
        _ = dimensions;
        var auth = SessionAuthMaterial.Prepare(_config, _credentials, _paths);
        var plan = OpenSshArgumentBuilder.Build(
            _install,
            _config,
            _knownHostsPath,
            auth.IdentityFile);
        var arguments = new List<string> { "-tt" };
        arguments.AddRange(plan.Arguments);
        var live = _runner.Start(plan.Executable, arguments, auth.Environment, auth.CleanupPaths);
        return Task.FromResult<IRemoteShellSession>(new OpenSshRemoteShellSession(live));
    }

    public Task<IRemoteFileClient> OpenSftpAsync(CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(_closed, this);
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult<IRemoteFileClient>(
            new OpenSshSftpClient(_install, _config, _knownHostsPath, _runner, _credentials, _paths));
    }

    public Task CloseAsync()
    {
        _closed = true;
        return Task.CompletedTask;
    }

    public async ValueTask DisposeAsync() => await CloseAsync().ConfigureAwait(false);
}

public sealed class OpenSshRemoteShellSession : IRemoteShellSession
{
    private readonly OpenSshLiveProcess _live;
    private readonly Channel<byte[]> _channel = Channel.CreateUnbounded<byte[]>();
    private readonly CancellationTokenSource _cts = new();
    private bool _closed;

    public OpenSshRemoteShellSession(OpenSshLiveProcess live)
    {
        _live = live;
        Events = ReadEventsAsync();
        _ = Task.Run(PumpAsync);
    }

    public IAsyncEnumerable<byte[]> Events { get; }

    public async Task WriteAsync(ReadOnlyMemory<byte> data, CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(_closed, this);
        await _live.StandardInput.WriteAsync(data, cancellationToken).ConfigureAwait(false);
        await _live.StandardInput.FlushAsync(cancellationToken).ConfigureAwait(false);
    }

    public Task ResizeAsync(RemoteShellDimensions dimensions, CancellationToken cancellationToken = default)
    {
        _ = dimensions;
        cancellationToken.ThrowIfCancellationRequested();
        return Task.CompletedTask;
    }

    public Task CloseAsync()
    {
        if (_closed)
        {
            return Task.CompletedTask;
        }

        _closed = true;
        _cts.Cancel();
        _channel.Writer.TryComplete();
        _live.Dispose();
        return Task.CompletedTask;
    }

    public async ValueTask DisposeAsync() => await CloseAsync().ConfigureAwait(false);

    private async IAsyncEnumerable<byte[]> ReadEventsAsync()
    {
        await foreach (var chunk in _channel.Reader.ReadAllAsync().ConfigureAwait(false))
        {
            yield return chunk;
        }
    }

    private async Task PumpAsync()
    {
        var buffer = new byte[OpenSshProcessRunner.DefaultChunkBytes];
        try
        {
            while (!_cts.IsCancellationRequested)
            {
                var read = await _live.StandardOutput.ReadAsync(buffer, _cts.Token).ConfigureAwait(false);
                if (read <= 0)
                {
                    break;
                }

                var copy = new byte[read];
                Buffer.BlockCopy(buffer, 0, copy, 0, read);
                await _channel.Writer.WriteAsync(copy, _cts.Token).ConfigureAwait(false);
            }

            _channel.Writer.TryComplete();
        }
        catch (OperationCanceledException)
        {
            _channel.Writer.TryComplete();
        }
        catch (Exception ex)
        {
            _channel.Writer.TryComplete(ex);
        }
    }
}
