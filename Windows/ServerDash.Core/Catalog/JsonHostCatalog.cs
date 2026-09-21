using System.Text.Json;
using System.Text.Json.Serialization;
using ServerDash.Models;

namespace ServerDash.Catalog;

public sealed class HostCatalogDocument
{
    public List<ServerRecord> Hosts { get; set; } = [];
}

public sealed class JsonHostCatalog
{
    private static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Converters = { new JsonStringEnumConverter() }
    };

    private readonly object _gate = new();

    public JsonHostCatalog(string filePath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(filePath);
        FilePath = filePath;
    }

    public string FilePath { get; }

    public static JsonHostCatalog Open(ApplicationPaths paths)
    {
        paths.EnsureCreated();
        return new JsonHostCatalog(Path.Combine(paths.DataDirectory, "hosts.json"));
    }

    public IReadOnlyList<ServerRecord> List()
    {
        lock (_gate)
        {
            return LoadUnlocked().Hosts.ToArray();
        }
    }

    public void Upsert(ServerRecord record)
    {
        ArgumentNullException.ThrowIfNull(record);
        lock (_gate)
        {
            var document = LoadUnlocked();
            var index = document.Hosts.FindIndex(item => item.Id == record.Id);
            if (index >= 0)
            {
                document.Hosts[index] = record;
            }
            else
            {
                document.Hosts.Add(record);
            }

            SaveUnlocked(document);
        }
    }

    public void Remove(Guid id)
    {
        lock (_gate)
        {
            var document = LoadUnlocked();
            document.Hosts.RemoveAll(item => item.Id == id);
            SaveUnlocked(document);
        }
    }

    public static ServerConnectionConfig ToConnectionConfig(ServerRecord host)
    {
        var credentialId = host.IdentityId ?? host.Id;
        return new ServerConnectionConfig
        {
            Id = host.Id,
            CredentialId = credentialId,
            Name = host.DisplayName,
            Host = host.Host.Trim(),
            Port = host.Port,
            Username = host.Username.Trim(),
            Authentication = host.Authentication,
            PrivateKeyPath = host.PrivateKeyPath,
            UsesImportedKey = host.Authentication != AuthenticationMethod.Password
                && string.IsNullOrWhiteSpace(host.PrivateKeyPath),
            IdentityReferenceMissing = string.IsNullOrWhiteSpace(host.Username)
        };
    }

    private HostCatalogDocument LoadUnlocked()
    {
        if (!File.Exists(FilePath))
        {
            return new HostCatalogDocument();
        }

        var json = File.ReadAllText(FilePath);
        return JsonSerializer.Deserialize<HostCatalogDocument>(json, Options) ?? new HostCatalogDocument();
    }

    private void SaveUnlocked(HostCatalogDocument document)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(FilePath) ?? ".");
        var json = JsonSerializer.Serialize(document, Options);
        File.WriteAllText(FilePath, json);
    }
}
