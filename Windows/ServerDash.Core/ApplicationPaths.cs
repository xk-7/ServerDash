namespace ServerDash;

public sealed class ApplicationPaths
{
    public ApplicationPaths(string rootDirectory)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(rootDirectory);
        RootDirectory = rootDirectory;
        DataDirectory = Path.Combine(rootDirectory, "Data");
        KnownHostsPath = Path.Combine(rootDirectory, "known_hosts");
        TemporaryDirectory = Path.Combine(rootDirectory, "tmp");
    }

    public string RootDirectory { get; }
    public string DataDirectory { get; }
    public string KnownHostsPath { get; }
    public string TemporaryDirectory { get; }

    public static ApplicationPaths WindowsDefault()
    {
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrWhiteSpace(local))
        {
            local = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                "AppData",
                "Local");
        }

        return new ApplicationPaths(Path.Combine(local, "ServerDash"));
    }

    public static ApplicationPaths Isolated(string rootDirectory) => new(rootDirectory);

    public void EnsureCreated()
    {
        Directory.CreateDirectory(RootDirectory);
        Directory.CreateDirectory(DataDirectory);
        Directory.CreateDirectory(TemporaryDirectory);
    }
}
