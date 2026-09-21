namespace ServerDash.Trust;

public sealed record KnownHostKey(string Host, int Port, string Algorithm, string KeyLine)
{
    public string LookupHost => Port == 22 ? Host : $"[{Host}]:{Port}";
}

/// <summary>
/// App-owned OpenSSH known_hosts. Missing or unmatched keys are untrusted.
/// </summary>
public sealed class KnownHostsStore
{
    private readonly object _gate = new();

    public KnownHostsStore(string knownHostsPath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(knownHostsPath);
        KnownHostsPath = knownHostsPath;
    }

    public string KnownHostsPath { get; }

    public bool IsTrusted(string host, int port)
    {
        return Find(host, port).Count > 0;
    }

    public IReadOnlyList<KnownHostKey> Find(string host, int port)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(host);
        var lookup = LookupName(host, port);
        lock (_gate)
        {
            if (!File.Exists(KnownHostsPath))
            {
                return [];
            }

            var matches = new List<KnownHostKey>();
            foreach (var raw in File.ReadAllLines(KnownHostsPath))
            {
                var line = raw.Trim();
                if (line.Length == 0 || line.StartsWith('#'))
                {
                    continue;
                }

                var parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                if (parts.Length < 3)
                {
                    continue;
                }

                if (HasName(parts[0], lookup))
                {
                    matches.Add(new KnownHostKey(host, port, parts[1], line));
                }
            }

            return matches;
        }
    }

    public void StoreLine(string host, int port, string keyLine)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(keyLine);
        var parts = keyLine.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 3)
        {
            throw new ArgumentException("known_hosts line must contain host, algorithm, and key.", nameof(keyLine));
        }

        Store(host, port, parts[1], parts[2]);
    }

    public void Store(string host, int port, string algorithm, string base64Key)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(host);
        ArgumentException.ThrowIfNullOrWhiteSpace(algorithm);
        ArgumentException.ThrowIfNullOrWhiteSpace(base64Key);

        var lookup = LookupName(host, port);
        var line = $"{lookup} {algorithm} {base64Key}";
        lock (_gate)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(KnownHostsPath) ?? ".");
            var kept = new List<string>();
            if (File.Exists(KnownHostsPath))
            {
                foreach (var raw in File.ReadAllLines(KnownHostsPath))
                {
                    var existing = raw.Trim();
                    if (existing.Length == 0 || existing.StartsWith('#'))
                    {
                        kept.Add(raw);
                        continue;
                    }

                    var parts = existing.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                    if (parts.Length < 3 || !HasName(parts[0], lookup) || !string.Equals(parts[1], algorithm, StringComparison.Ordinal))
                    {
                        kept.Add(raw);
                    }
                }
            }

            kept.Add(line);
            File.WriteAllLines(KnownHostsPath, kept);
        }
    }

    public static string LookupName(string host, int port) =>
        port == 22 ? host.Trim() : $"[{host.Trim()}]:{port}";

    private static bool HasName(string namesField, string lookup)
    {
        return namesField
            .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Any(name => string.Equals(name, lookup, StringComparison.OrdinalIgnoreCase));
    }
}
