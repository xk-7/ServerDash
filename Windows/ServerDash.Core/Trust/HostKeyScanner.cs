using System.Security.Cryptography;
using ServerDash.Connections;

namespace ServerDash.Trust;

public sealed record HostKeyProbe(
    string Host,
    int Port,
    string Algorithm,
    string Fingerprint,
    string KeyLine,
    IReadOnlyList<string> AdditionalKeyLines)
{
    public RemoteHostKeyPresentation ToPresentation()
    {
        var parts = KeyLine.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var blob = parts.Length >= 3 ? Convert.FromBase64String(parts[2]) : [];
        return new RemoteHostKeyPresentation(Host, Port, Algorithm, blob, Fingerprint, KeyLine);
    }
}

public interface IHostKeyScanner
{
    HostKeyProbe Scan(string host, int port, string? preferredAlgorithm = null);
}

public sealed class HostKeyScanner : IHostKeyScanner
{
    private readonly OpenSshLocator _locator;
    private readonly IOpenSshProcessRunner _runner;

    public HostKeyScanner(OpenSshLocator locator, IOpenSshProcessRunner runner)
    {
        _locator = locator;
        _runner = runner;
    }

    public HostKeyProbe Scan(string host, int port, string? preferredAlgorithm = null)
    {
        var install = _locator.Find() ?? throw RemoteConnectionFailure.MissingOpenSsh();
        if (string.IsNullOrWhiteSpace(install.KeyscanPath))
        {
            throw RemoteConnectionFailure.MissingKeyscan();
        }

        var result = _runner.Run(
            install.KeyscanPath,
            ["-T", "8", "-p", port.ToString(), host],
            environment: null,
            timeout: TimeSpan.FromSeconds(12),
            maxOutputBytes: 64_000,
            cleanupPaths: null);
        return Parse(result.OutputText, result.ErrorText, host, port, preferredAlgorithm);
    }

    public static HostKeyProbe Parse(
        string output,
        string error,
        string host,
        int port,
        string? preferredAlgorithm = null)
    {
        var validLines = output
            .Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries)
            .Select(line => line.Trim())
            .Where(line => !line.StartsWith('#') && line.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length >= 3)
            .ToArray();

        var preferred = validLines.FirstOrDefault(line => AlgorithmOf(line) == preferredAlgorithm)
            ?? validLines.FirstOrDefault(line => AlgorithmOf(line) == "ssh-ed25519")
            ?? validLines.FirstOrDefault();
        if (preferred is null)
        {
            throw new RemoteConnectionFailure(
                RemoteConnectionFailureKind.Transport,
                string.IsNullOrWhiteSpace(error) ? "无法获取服务器主机指纹。" : error);
        }

        var fields = preferred.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var fingerprint = Fingerprint(preferred)
            ?? throw new RemoteConnectionFailure(RemoteConnectionFailureKind.Transport, "服务器返回了无效的 SSH 主机密钥。");
        return new HostKeyProbe(
            host,
            port,
            AlgorithmDisplayName(fields[1]),
            fingerprint,
            preferred,
            validLines.Where(line => line != preferred).ToArray());
    }

    public static string? Fingerprint(string keyLine)
    {
        var fields = keyLine.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (fields.Length < 3)
        {
            return null;
        }

        try
        {
            var blob = Convert.FromBase64String(fields[2]);
            var digest = SHA256.HashData(blob);
            return "SHA256:" + Convert.ToBase64String(digest).TrimEnd('=');
        }
        catch (FormatException)
        {
            return null;
        }
    }

    public static string AlgorithmDisplayName(string algorithm) => algorithm switch
    {
        "ssh-ed25519" => "ED25519",
        "ecdsa-sha2-nistp256" => "ECDSA",
        "ssh-rsa" => "RSA",
        _ => algorithm
    };

    private static string? AlgorithmOf(string line)
    {
        var fields = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        return fields.Length >= 2 ? fields[1] : null;
    }
}
