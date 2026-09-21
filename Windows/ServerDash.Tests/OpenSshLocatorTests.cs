using ServerDash.Connections;

namespace ServerDash.Tests;

public sealed class OpenSshLocatorTests
{
    [Fact]
    public void Find_returns_null_when_search_paths_are_empty()
    {
        var locator = new OpenSshLocator(
            searchDirectories: [Path.Combine(Path.GetTempPath(), "serverdash-missing-openssh")],
            pathEntries: []);

        Assert.Null(locator.Find());
    }

    [Fact]
    public void Require_fails_closed_when_binaries_are_missing()
    {
        var locator = new OpenSshLocator(
            searchDirectories: [Path.Combine(Path.GetTempPath(), "serverdash-missing-openssh")],
            pathEntries: []);

        var error = Assert.Throws<RemoteConnectionFailure>(() => locator.Require());
        Assert.Equal(RemoteConnectionFailureKind.MissingOpenSsh, error.Kind);
    }

    [Fact]
    public void Find_requires_both_ssh_and_sftp()
    {
        var root = Directory.CreateTempSubdirectory("sd-ssh-only-");
        try
        {
            var sshName = OperatingSystem.IsWindows() ? "ssh.exe" : "ssh";
            File.WriteAllText(Path.Combine(root.FullName, sshName), "placeholder");

            var locator = new OpenSshLocator(
                searchDirectories: [root.FullName],
                pathEntries: []);

            Assert.Null(locator.Find());
        }
        finally
        {
            root.Delete(true);
        }
    }

    [Fact]
    public void Find_returns_install_when_both_binaries_exist()
    {
        var root = Directory.CreateTempSubdirectory("sd-openssh-");
        try
        {
            var sshName = OperatingSystem.IsWindows() ? "ssh.exe" : "ssh";
            var sftpName = OperatingSystem.IsWindows() ? "sftp.exe" : "sftp";
            var ssh = Path.Combine(root.FullName, sshName);
            var sftp = Path.Combine(root.FullName, sftpName);
            File.WriteAllText(ssh, "placeholder");
            File.WriteAllText(sftp, "placeholder");

            var locator = new OpenSshLocator(
                searchDirectories: [root.FullName],
                pathEntries: []);

            var install = locator.Find();
            Assert.NotNull(install);
            Assert.Equal(Path.GetFullPath(ssh), install!.SshPath);
            Assert.Equal(Path.GetFullPath(sftp), install.SftpPath);
        }
        finally
        {
            root.Delete(true);
        }
    }
}
