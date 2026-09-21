namespace ServerDash.Tests;

public sealed class PlatformCapabilitiesTests
{
    [Fact]
    public void Windows_matches_macOS_desktop_flags()
    {
        Assert.Equal(PlatformCapabilities.MacOS, PlatformCapabilities.Windows);
        Assert.True(PlatformCapabilities.Windows.JumpHosts);
        Assert.True(PlatformCapabilities.Windows.SshAgent);
        Assert.True(PlatformCapabilities.Windows.ExternalPrivateKeyPath);
        Assert.True(PlatformCapabilities.Windows.LocalForward);
        Assert.True(PlatformCapabilities.Windows.RemoteForward);
        Assert.True(PlatformCapabilities.Windows.DynamicForward);
    }

    [Fact]
    public void Mobile_is_not_the_windows_target()
    {
        Assert.NotEqual(PlatformCapabilities.Windows, PlatformCapabilities.Mobile);
        Assert.False(PlatformCapabilities.Mobile.JumpHosts);
        Assert.False(PlatformCapabilities.Mobile.SshAgent);
    }
}
