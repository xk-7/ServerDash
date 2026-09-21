using ServerDash.Connections;

namespace ServerDash.Tests;

public sealed class SftpClientTests
{
    [Fact]
    public void EnsureDownloadArrived_fails_when_target_missing()
    {
        var missing = Path.Combine(Path.GetTempPath(), $"sd-missing-{Guid.NewGuid():N}");
        var error = Assert.Throws<SftpClientException>(() => OpenSshSftpClient.EnsureDownloadArrived(missing));
        Assert.Contains("未将半成品标为成功", error.Message);
    }

    [Fact]
    public void EnsureDownloadArrived_accepts_existing_file()
    {
        var file = Path.Combine(Path.GetTempPath(), $"sd-present-{Guid.NewGuid():N}");
        File.WriteAllText(file, "ok");
        try
        {
            OpenSshSftpClient.EnsureDownloadArrived(file);
        }
        finally
        {
            File.Delete(file);
        }
    }

    [Fact]
    public void Listing_parser_reads_ls_la()
    {
        var listing = SftpListingParser.Parse(
            """
            Remote working directory: /var/log
            drwxr-xr-x  2 root root 4096 Jan 1 00:00 .
            drwxr-xr-x  3 root root 4096 Jan 1 00:00 ..
            -rw-r--r--  1 root root  128 Jan 1 00:00 syslog
            drwxr-xr-x  2 root root 4096 Jan 1 00:00 journal
            """,
            "/");
        Assert.Equal("/var/log", listing.Path);
        Assert.Equal(2, listing.Items.Count);
        Assert.Contains(listing.Items, item => item.IsDirectory && item.Name == "journal");
        Assert.Contains(listing.Items, item => !item.IsDirectory && item.Name == "syslog" && item.Size == 128);
    }
}
