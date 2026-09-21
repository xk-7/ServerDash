using ServerDash.Credentials;

namespace ServerDash.Tests;

public sealed class CredentialStoreTests
{
    [Fact]
    public void In_memory_store_round_trips_and_deletes()
    {
        var store = new InMemoryCredentialStore();
        const string account = "22222222-2222-2222-2222-222222222222";
        Assert.False(store.HasSecret(account));
        store.SetSecret(account, "secret");
        Assert.True(store.TryGetSecret(account, out var secret));
        Assert.Equal("secret", secret);
        store.DeleteSecret(account);
        Assert.False(store.HasSecret(account));
    }

    [Fact]
    public void Windows_store_is_unavailable_off_windows()
    {
        if (OperatingSystem.IsWindows())
        {
            var store = new WindowsCredentialStore();
            Assert.StartsWith("ServerDash/", WindowsCredentialStore.Target("acct"));
            Assert.NotNull(store);
            return;
        }

        Assert.Throws<PlatformNotSupportedException>(() => new WindowsCredentialStore());
    }
}
