namespace ServerDash.Models;

public enum AuthenticationMethod
{
    PrivateKey,
    Password,
    KeyThenPassword
}

public enum ServerVerificationStatus
{
    Unverified,
    SshReady,
    MonitorReady,
    MonitorUnsupported
}

public enum ServerConnectionStatus
{
    Unknown,
    Connecting,
    Online,
    Offline,
    Failed
}

public enum SshKeyStorageMode
{
    File,
    Imported
}

public sealed class ServerRecord
{
    public Guid Id { get; init; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    public string Host { get; set; } = "";
    public int Port { get; set; } = 22;
    public string Username { get; set; } = "";
    public AuthenticationMethod Authentication { get; set; } = AuthenticationMethod.PrivateKey;
    public string PrivateKeyPath { get; set; } = "";
    public string GroupName { get; set; } = "默认分组";
    public string TagsText { get; set; } = "";
    public string Notes { get; set; } = "";
    public Guid? IdentityId { get; set; }
    public DateTimeOffset CreatedAt { get; init; } = DateTimeOffset.UtcNow;
    public ServerVerificationStatus VerificationStatus { get; set; } = ServerVerificationStatus.Unverified;
    public bool EnableDashboardMonitor { get; set; } = true;

    public string DisplayName
    {
        get
        {
            var trimmed = Name.Trim();
            return trimmed.Length == 0 ? Host : trimmed;
        }
    }
}

public sealed class IdentityRecord
{
    public Guid Id { get; init; } = Guid.NewGuid();
    public string Username { get; set; } = "";
    public AuthenticationMethod Authentication { get; set; } = AuthenticationMethod.PrivateKey;
    public Guid? CredentialId { get; set; }
    public Guid? SshKeyId { get; set; }
}

public sealed class SshKeyRecord
{
    public Guid Id { get; init; } = Guid.NewGuid();
    public string FilePath { get; set; } = "";
    public SshKeyStorageMode StorageMode { get; set; } = SshKeyStorageMode.Imported;
    public bool HasPassphrase { get; set; }
}

public sealed class ConnectionRoute
{
    public static ConnectionRoute Direct { get; } = new()
    {
        Id = Guid.Parse("00000000-0000-0000-0000-000000000011"),
        Name = "直接连接"
    };

    public Guid Id { get; init; } = Guid.NewGuid();
    public string Name { get; init; } = "直接连接";
    public IReadOnlyList<string> Hops { get; init; } = [];
    public bool HasProxy { get; init; }

    public bool IsDirect => Hops.Count == 0 && !HasProxy;
}

public sealed class ServerConnectionConfig
{
    public required Guid Id { get; init; }
    public required Guid CredentialId { get; init; }
    public required string Name { get; init; }
    public required string Host { get; init; }
    public int Port { get; init; } = 22;
    public required string Username { get; init; }
    public AuthenticationMethod Authentication { get; init; } = AuthenticationMethod.PrivateKey;
    public string PrivateKeyPath { get; init; } = "";
    public Guid? SshKeyId { get; init; }
    public bool UsesImportedKey { get; init; }
    public bool HasPassphrase { get; init; }
    public TimeSpan ConnectTimeout { get; init; } = TimeSpan.FromSeconds(15);
    public ConnectionRoute Route { get; init; } = ConnectionRoute.Direct;
    public bool IdentityReferenceMissing { get; init; }
}
