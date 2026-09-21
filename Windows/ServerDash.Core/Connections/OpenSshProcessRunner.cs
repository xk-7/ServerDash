using System.Diagnostics;
using System.Text;

namespace ServerDash.Connections;

public sealed record OpenSshProcessResult(byte[] Stdout, byte[] Stderr, int ExitCode)
{
    public string OutputText => Encoding.UTF8.GetString(Stdout);
    public string ErrorText => Encoding.UTF8.GetString(Stderr);
}

public interface IOpenSshProcessRunner
{
    OpenSshProcessResult Run(
        string executable,
        IReadOnlyList<string> arguments,
        IReadOnlyDictionary<string, string>? environment,
        TimeSpan timeout,
        int maxOutputBytes,
        IEnumerable<string>? cleanupPaths,
        CancellationToken cancellationToken = default);

    OpenSshLiveProcess Start(
        string executable,
        IReadOnlyList<string> arguments,
        IReadOnlyDictionary<string, string>? environment,
        IEnumerable<string>? cleanupPaths);
}

public sealed class OpenSshLiveProcess : IDisposable
{
    private readonly List<string> _cleanupPaths;
    private bool _disposed;

    internal OpenSshLiveProcess(Process process, List<string> cleanupPaths)
    {
        Process = process;
        _cleanupPaths = cleanupPaths;
        StandardInput = process.StandardInput.BaseStream;
        StandardOutput = process.StandardOutput.BaseStream;
    }

    public Process Process { get; }
    public Stream StandardInput { get; }
    public Stream StandardOutput { get; }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        try
        {
            if (!Process.HasExited)
            {
                Process.Kill(entireProcessTree: true);
            }
        }
        catch (InvalidOperationException)
        {
        }

        Process.Dispose();
        TemporaryFiles.Delete(_cleanupPaths);
    }
}

public sealed class OpenSshProcessRunner : IOpenSshProcessRunner
{
    public const int DefaultChunkBytes = 32 * 1024;

    public OpenSshProcessResult Run(
        string executable,
        IReadOnlyList<string> arguments,
        IReadOnlyDictionary<string, string>? environment,
        TimeSpan timeout,
        int maxOutputBytes,
        IEnumerable<string>? cleanupPaths,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(executable);
        var cleanup = cleanupPaths?.ToArray() ?? [];
        using var process = StartProcess(executable, arguments, environment, redirectError: true);
        try
        {
            using var stdout = new MemoryStream();
            using var stderr = new MemoryStream();
            var stdoutTask = Task.Run(() => Copy(process.StandardOutput.BaseStream, stdout, maxOutputBytes), cancellationToken);
            var stderrTask = Task.Run(() => Copy(process.StandardError.BaseStream, stderr, maxOutputBytes), cancellationToken);
            var finished = Wait(process, timeout, cancellationToken);
            Task.WaitAll([stdoutTask, stderrTask], TimeSpan.FromSeconds(2));
            if (!finished)
            {
                Kill(process);
                throw new RemoteConnectionFailure(RemoteConnectionFailureKind.TimedOut);
            }

            if (stdout.Length > maxOutputBytes || stderr.Length > maxOutputBytes)
            {
                throw new RemoteConnectionFailure(RemoteConnectionFailureKind.OutputLimitExceeded);
            }

            return new OpenSshProcessResult(stdout.ToArray(), stderr.ToArray(), process.ExitCode);
        }
        finally
        {
            TemporaryFiles.Delete(cleanup);
        }
    }

    public OpenSshLiveProcess Start(
        string executable,
        IReadOnlyList<string> arguments,
        IReadOnlyDictionary<string, string>? environment,
        IEnumerable<string>? cleanupPaths)
    {
        var process = StartProcess(executable, arguments, environment, redirectError: false);
        return new OpenSshLiveProcess(process, cleanupPaths?.ToList() ?? []);
    }

    private static Process StartProcess(
        string executable,
        IReadOnlyList<string> arguments,
        IReadOnlyDictionary<string, string>? environment,
        bool redirectError)
    {
        var start = new ProcessStartInfo
        {
            FileName = executable,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = redirectError
        };
        foreach (var argument in arguments)
        {
            start.ArgumentList.Add(argument);
        }

        if (environment is not null)
        {
            foreach (var pair in environment)
            {
                start.Environment[pair.Key] = pair.Value;
            }
        }

        var process = Process.Start(start)
            ?? throw new RemoteConnectionFailure(RemoteConnectionFailureKind.Transport, "无法启动 OpenSSH 进程。");
        return process;
    }

    private static bool Wait(Process process, TimeSpan timeout, CancellationToken cancellationToken)
    {
        var remaining = timeout <= TimeSpan.Zero ? TimeSpan.FromSeconds(30) : timeout;
        var deadline = DateTime.UtcNow + remaining;
        while (DateTime.UtcNow < deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (process.WaitForExit(100))
            {
                return true;
            }
        }

        return process.HasExited;
    }

    private static void Kill(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
                process.WaitForExit(2000);
            }
        }
        catch (InvalidOperationException)
        {
        }
    }

    private static void Copy(Stream source, MemoryStream destination, int maxOutputBytes)
    {
        var buffer = new byte[DefaultChunkBytes];
        while (true)
        {
            var read = source.Read(buffer, 0, buffer.Length);
            if (read <= 0)
            {
                break;
            }

            destination.Write(buffer, 0, read);
            if (destination.Length > maxOutputBytes)
            {
                break;
            }
        }
    }
}

public static class TemporaryFiles
{
    public static void Delete(IEnumerable<string> paths)
    {
        foreach (var path in paths)
        {
            try
            {
                if (File.Exists(path))
                {
                    File.Delete(path);
                }
            }
            catch (IOException)
            {
            }
            catch (UnauthorizedAccessException)
            {
            }
        }
    }
}
