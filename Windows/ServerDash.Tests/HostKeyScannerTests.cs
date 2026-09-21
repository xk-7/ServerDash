using ServerDash.Trust;

namespace ServerDash.Tests;

public sealed class HostKeyScannerTests
{
    public const string SampleLine = "203.0.113.10 ssh-ed25519 AQIDBA==";
    public const string SampleRsa = "203.0.113.10 ssh-rsa AQIDBA==";

    [Fact]
    public void Parse_prefers_ed25519()
    {
        var probe = HostKeyScanner.Parse(
            "# comment\n" + SampleRsa + "\n" + SampleLine + "\n",
            "",
            "203.0.113.10",
            22);
        Assert.Equal("ED25519", probe.Algorithm);
        Assert.Equal(SampleLine, probe.KeyLine);
        Assert.StartsWith("SHA256:", probe.Fingerprint);
    }

    [Fact]
    public void Fingerprint_is_sha256_without_padding()
    {
        var fingerprint = HostKeyScanner.Fingerprint(SampleLine);
        Assert.Equal("SHA256:" + Convert.ToBase64String(System.Security.Cryptography.SHA256.HashData(Convert.FromBase64String("AQIDBA=="))).TrimEnd('='), fingerprint);
    }

    [Fact]
    public void Parse_fails_closed_without_valid_lines()
    {
        Assert.Throws<ServerDash.Connections.RemoteConnectionFailure>(
            () => HostKeyScanner.Parse("# only comments\n", "ssh-keyscan: not found", "203.0.113.10", 22));
    }
}
