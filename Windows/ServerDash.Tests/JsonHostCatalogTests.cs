using ServerDash.Catalog;
using ServerDash.Models;

namespace ServerDash.Tests;

public sealed class JsonHostCatalogTests
{
    [Fact]
    public void Upsert_round_trips_without_storing_secrets()
    {
        var root = Directory.CreateTempSubdirectory("sd-catalog-");
        try
        {
            var catalog = JsonHostCatalog.Open(ApplicationPaths.Isolated(root.FullName));
            var host = new ServerRecord
            {
                Name = "edge",
                Host = "203.0.113.10",
                Username = "operator",
                Authentication = AuthenticationMethod.Password
            };
            host.IdentityId = host.Id;
            catalog.Upsert(host);

            var loaded = Assert.Single(catalog.List());
            Assert.Equal("edge", loaded.Name);
            Assert.DoesNotContain("password", File.ReadAllText(catalog.FilePath), StringComparison.OrdinalIgnoreCase);

            var config = JsonHostCatalog.ToConnectionConfig(loaded);
            Assert.Equal(host.Id, config.CredentialId);
            Assert.Equal("203.0.113.10", config.Host);
        }
        finally
        {
            root.Delete(true);
        }
    }
}
