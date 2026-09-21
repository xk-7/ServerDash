using ServerDash.Connections;
using ServerDash.Models;

namespace ServerDash.Tests;

public sealed class OpenSshLaunchPlanTests
{
    [Fact]
    public void Build_requires_strict_host_key_checking_and_app_known_hosts()
    {
        var plan = OpenSshArgumentBuilder.Build(FakeInstall(), SampleConfig(), "/tmp/serverdash-known_hosts");

        Assert.Contains("-F", plan.Arguments);
        Assert.Contains("StrictHostKeyChecking=yes", plan.OptionValues);
        Assert.Contains("UserKnownHostsFile=/tmp/serverdash-known_hosts", plan.OptionValues);
        Assert.Contains("UpdateHostKeys=no", plan.OptionValues);
        Assert.DoesNotContain(plan.OptionValues, value =>
            value.Contains("accept-new", StringComparison.OrdinalIgnoreCase) ||
            value.Equals("StrictHostKeyChecking=no", StringComparison.OrdinalIgnoreCase));
        Assert.Equal("operator@203.0.113.10", plan.Arguments[^1]);
    }

    [Fact]
    public void RejectWeakHostKeyChecking_blocks_accept_new()
    {
        var weak = new OpenSshLaunchPlan(
            "ssh",
            ["-o", "StrictHostKeyChecking=accept-new", "host"],
            "known_hosts");

        Assert.Throws<InvalidOperationException>(() => OpenSshArgumentBuilder.RejectWeakHostKeyChecking(weak));
    }

    [Fact]
    public void Sftp_plan_uses_capital_P_and_batch_file()
    {
        var plan = OpenSshArgumentBuilder.BuildSftp(
            FakeInstall(),
            SampleConfig(),
            "known_hosts",
            "batch.txt");
        Assert.Equal("/usr/bin/sftp", plan.Executable);
        Assert.Contains("-P", plan.Arguments);
        Assert.Contains("-b", plan.Arguments);
        Assert.Contains("batch.txt", plan.Arguments);
        Assert.Contains("StrictHostKeyChecking=yes", plan.OptionValues);
    }

    [Fact]
    public void Password_auth_disables_pubkey()
    {
        var config = SampleConfig() with { Authentication = AuthenticationMethod.Password };
        var plan = OpenSshArgumentBuilder.Build(FakeInstall(), config, "known_hosts");
        Assert.Contains("PubkeyAuthentication=no", plan.OptionValues);
    }

    private static OpenSshInstall FakeInstall() => new("/usr/bin/ssh", "/usr/bin/sftp");

    private static ServerConnectionConfig SampleConfig() => new()
    {
        Id = Guid.Parse("11111111-1111-1111-1111-111111111111"),
        CredentialId = Guid.Parse("22222222-2222-2222-2222-222222222222"),
        Name = "edge",
        Host = "203.0.113.10",
        Port = 22,
        Username = "operator",
        Authentication = AuthenticationMethod.PrivateKey,
        PrivateKeyPath = "/tmp/id_ed25519"
    };
}
