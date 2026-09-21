namespace ServerDash.Credentials;

public sealed class InMemoryCredentialStore : ICredentialStore
{
    private readonly Dictionary<string, string> _secrets = new(StringComparer.Ordinal);
    private readonly object _gate = new();

    public bool HasSecret(string account)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(account);
        lock (_gate)
        {
            return _secrets.ContainsKey(account);
        }
    }

    public bool TryGetSecret(string account, out string secret)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(account);
        lock (_gate)
        {
            return _secrets.TryGetValue(account, out secret!);
        }
    }

    public void SetSecret(string account, string secret)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(account);
        ArgumentNullException.ThrowIfNull(secret);
        lock (_gate)
        {
            _secrets[account] = secret;
        }
    }

    public void DeleteSecret(string account)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(account);
        lock (_gate)
        {
            _secrets.Remove(account);
        }
    }
}
