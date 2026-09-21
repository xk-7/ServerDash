using ServerDash.Trust;

namespace ServerDash.Tests;

public sealed class KnownHostsStoreTests
{
    [Fact]
    public void Missing_file_is_untrusted()
    {
        var path = Path.Combine(Path.GetTempPath(), $"sd-known-{Guid.NewGuid():N}");
        var store = new KnownHostsStore(path);
        Assert.False(store.IsTrusted("203.0.113.10", 22));
        Assert.Empty(store.Find("203.0.113.10", 22));
    }

    [Fact]
    public void Store_then_lookup_round_trips()
    {
        var root = Directory.CreateTempSubdirectory("sd-hosts-");
        try
        {
            var store = new KnownHostsStore(Path.Combine(root.FullName, "known_hosts"));
            store.Store("203.0.113.10", 22, "ssh-ed25519", "AAAA");
            Assert.True(store.IsTrusted("203.0.113.10", 22));
            Assert.Contains("203.0.113.10 ssh-ed25519 AAAA", File.ReadAllText(store.KnownHostsPath));
        }
        finally
        {
            root.Delete(true);
        }
    }

    [Fact]
    public void Non_default_port_uses_bracket_form()
    {
        Assert.Equal("[203.0.113.10]:2222", KnownHostsStore.LookupName("203.0.113.10", 2222));
    }
}
