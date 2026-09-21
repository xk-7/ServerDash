namespace ServerDash.Monitoring;

public sealed class ServerCapabilities
{
    public string Platform { get; init; } = "linux";
    public string Family { get; init; } = "";
    public bool GnuCoreutils { get; init; } = true;
    public bool HasProc { get; init; } = true;
    public bool HasDocker { get; init; }
    public bool HasGpu { get; init; }
    public bool HasVnStat { get; init; }
    public bool LimitedSupport { get; init; }

    public string Summary
    {
        get
        {
            var parts = new List<string> { string.IsNullOrWhiteSpace(Family) ? Platform : Family };
            if (LimitedSupport) parts.Add("有限支持");
            if (HasDocker) parts.Add("Docker");
            if (HasGpu) parts.Add("GPU");
            if (HasVnStat) parts.Add("vnStat");
            return string.Join(" · ", parts);
        }
    }
}

public sealed record ProcessMetric(string Name, int Pid, double Cpu, double Memory, string User = "", string Arguments = "", int ThreadCount = 0);

public sealed record NetworkInterfaceMetric(string Name, double ReceivedBytes, double SentBytes, bool IsActive = false);

public sealed record FilesystemMetric(string Device, string MountPoint, string FilesystemType, double UsedBytes, double TotalBytes);

public sealed record GpuMetric(int Index, string Uuid, string Name, double Utilization, double MemoryUsedBytes, double MemoryTotalBytes);

public sealed record DockerContainerMetric(string Id, string Name, string Image, string State, string Status);

public sealed class ServerSnapshot
{
    public DateTimeOffset CapturedAt { get; init; } = DateTimeOffset.UtcNow;
    public double CpuUsage { get; init; }
    public int CoreCount { get; init; }
    public double Load1 { get; init; }
    public double Load5 { get; init; }
    public double Load15 { get; init; }
    public double MemoryUsedBytes { get; init; }
    public double MemoryTotalBytes { get; init; }
    public double SwapUsedBytes { get; init; }
    public double SwapTotalBytes { get; init; }
    public double DiskUsedBytes { get; init; }
    public double DiskTotalBytes { get; init; }
    public double NetworkReceivedBytes { get; init; }
    public double NetworkSentBytes { get; init; }
    public string Uptime { get; init; } = "—";
    public string Distribution { get; init; } = "Linux";
    public string Kernel { get; init; } = "—";
    public int LoggedInUsers { get; init; }
    public int ProcessCount { get; init; }
    public IReadOnlyList<ProcessMetric> TopProcesses { get; init; } = [];
    public IReadOnlyList<ProcessMetric> Processes { get; init; } = [];
    public IReadOnlyList<NetworkInterfaceMetric> NetworkInterfaces { get; init; } = [];
    public IReadOnlyList<FilesystemMetric> Filesystems { get; init; } = [];
    public IReadOnlyList<GpuMetric> Gpus { get; init; } = [];
    public IReadOnlyList<DockerContainerMetric> DockerContainers { get; init; } = [];
    public bool DockerAvailable { get; init; }
    public string DockerVersion { get; init; } = "";
}

public sealed class MonitoringException : Exception
{
    public MonitoringException(string message) : base(message) { }
}
