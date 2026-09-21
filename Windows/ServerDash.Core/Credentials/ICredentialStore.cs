namespace ServerDash.Credentials;

public interface ICredentialStore
{
    bool HasSecret(string account);

    bool TryGetSecret(string account, out string secret);

    void SetSecret(string account, string secret);

    void DeleteSecret(string account);
}
