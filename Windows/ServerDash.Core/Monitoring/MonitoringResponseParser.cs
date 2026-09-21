using ServerDash.Connections;

namespace ServerDash.Monitoring;

public static class MonitoringResponseParser
{
    public static ServerCapabilities ParseCapabilities(string output)
    {
        var values = ScalarMap(output);
        var distro = values.GetValueOrDefault("distro") ?? "";
        return new ServerCapabilities
        {
            Platform = (values.GetValueOrDefault("os") ?? "Linux").ToLowerInvariant(),
            Family = distro,
            GnuCoreutils = values.GetValueOrDefault("gnu") == "1",
            HasProc = values.GetValueOrDefault("proc") == "1",
            HasDocker = values.GetValueOrDefault("docker") == "1",
            HasGpu = values.GetValueOrDefault("gpu") == "1",
            HasVnStat = values.GetValueOrDefault("vnstat") == "1",
            LimitedSupport = distro == "alpine" || values.GetValueOrDefault("gnu") != "1"
        };
    }

    public static ServerSnapshot Parse(string output)
    {
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        var processes = new List<ProcessMetric>();
        var interfaces = new List<NetworkInterfaceMetric>();
        var filesystems = new List<FilesystemMetric>();
        var gpus = new List<GpuMetric>();
        var containers = new List<DockerContainerMetric>();

        foreach (var raw in output.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
        {
            var separator = raw.IndexOf('=');
            if (separator <= 0)
            {
                continue;
            }

            var key = raw[..separator];
            var value = raw[(separator + 1)..];
            switch (key)
            {
                case "proc":
                    var proc = value.Split('|');
                    if (proc.Length == 4)
                    {
                        processes.Add(new ProcessMetric(proc[1], Int(proc[0]), Num(proc[2]), Num(proc[3])));
                    }
                    else if (proc.Length >= 7)
                    {
                        processes.Add(new ProcessMetric(
                            proc[2],
                            Int(proc[0]),
                            Num(proc[3]),
                            Num(proc[4]),
                            proc[1],
                            string.Join('|', proc.Skip(6)),
                            Int(proc[5])));
                    }

                    break;
                case "iface":
                    var iface = value.Split('|');
                    if (iface.Length >= 3)
                    {
                        interfaces.Add(new NetworkInterfaceMetric(iface[0], Num(iface[1]), Num(iface[2])));
                    }

                    break;
                case "fs":
                    var fs = value.Split('|');
                    if (fs.Length >= 5)
                    {
                        filesystems.Add(new FilesystemMetric(
                            fs[0],
                            string.Join('|', fs.Skip(4)),
                            fs[1],
                            Num(fs[2]),
                            Num(fs[3])));
                    }

                    break;
                case "gpu":
                    var gpu = value.Split('|');
                    if (gpu.Length == 10)
                    {
                        gpus.Add(new GpuMetric(
                            Int(gpu[0]),
                            gpu[1],
                            gpu[2],
                            Num(gpu[3]),
                            Num(gpu[4]) * 1_048_576,
                            Num(gpu[5]) * 1_048_576));
                    }

                    break;
                case "dcont":
                    var docker = value.Split('|');
                    if (docker.Length >= 5)
                    {
                        containers.Add(new DockerContainerMetric(
                            docker[0],
                            docker[1],
                            docker[2],
                            docker[3],
                            string.Join('|', docker.Skip(4))));
                    }

                    break;
                default:
                    values[key] = value;
                    break;
            }
        }

        if (!values.ContainsKey("mem_total_kb"))
        {
            var preview = output.Replace('\n', ' ').Trim();
            if (preview.Length > 160)
            {
                preview = preview[..160];
            }

            throw new MonitoringException(preview.Length == 0 ? "SSH 命令没有返回数据" : "原始输出：" + preview);
        }

        var memoryTotal = Num(values.GetValueOrDefault("mem_total_kb")) * 1024;
        var memoryAvailable = Num(values.GetValueOrDefault("mem_available_kb")) * 1024;
        var swapTotal = Num(values.GetValueOrDefault("swap_total_kb")) * 1024;
        var swapFree = Num(values.GetValueOrDefault("swap_free_kb")) * 1024;
        var active = values.GetValueOrDefault("active_iface") ?? "";
        interfaces = interfaces
            .Select(item => item with { IsActive = item.Name == active })
            .ToList();

        return new ServerSnapshot
        {
            CpuUsage = Num(values.GetValueOrDefault("cpu")),
            CoreCount = Int(values.GetValueOrDefault("cores")),
            Load1 = Num(values.GetValueOrDefault("load1")),
            Load5 = Num(values.GetValueOrDefault("load5")),
            Load15 = Num(values.GetValueOrDefault("load15")),
            MemoryUsedBytes = Math.Max(0, memoryTotal - memoryAvailable),
            MemoryTotalBytes = memoryTotal,
            SwapUsedBytes = Math.Max(0, swapTotal - swapFree),
            SwapTotalBytes = swapTotal,
            DiskUsedBytes = Num(values.GetValueOrDefault("disk_used")),
            DiskTotalBytes = Num(values.GetValueOrDefault("disk_total")),
            NetworkReceivedBytes = Num(values.GetValueOrDefault("net_rx")),
            NetworkSentBytes = Num(values.GetValueOrDefault("net_tx")),
            Uptime = values.GetValueOrDefault("uptime") ?? "—",
            Distribution = values.GetValueOrDefault("distro") ?? "Linux",
            Kernel = values.GetValueOrDefault("kernel") ?? "—",
            LoggedInUsers = Int(values.GetValueOrDefault("users")),
            ProcessCount = Int(values.GetValueOrDefault("processes")),
            Processes = processes,
            TopProcesses = processes.Take(8).ToArray(),
            NetworkInterfaces = interfaces,
            Filesystems = filesystems,
            Gpus = gpus,
            DockerContainers = containers,
            DockerAvailable = values.GetValueOrDefault("docker_available") == "1",
            DockerVersion = values.GetValueOrDefault("docker_version") ?? ""
        };
    }

    public static async Task<ServerSnapshot> CollectAsync(
        IRemoteSession session,
        CancellationToken cancellationToken = default)
    {
        try
        {
            var primary = await session.ExecuteAsync(MonitoringScripts.FallbackCollect, TimeSpan.FromSeconds(45), 512_000, cancellationToken)
                .ConfigureAwait(false);
            return Parse(primary.Output);
        }
        catch (MonitoringException)
        {
            var fallback = await session.ExecuteAsync(MonitoringScripts.FallbackCollect, TimeSpan.FromSeconds(45), 512_000, cancellationToken)
                .ConfigureAwait(false);
            return Parse(fallback.Output);
        }
    }

    public static async Task<ServerCapabilities> ProbeAsync(
        IRemoteSession session,
        CancellationToken cancellationToken = default)
    {
        var result = await session.ExecuteAsync(MonitoringScripts.Probe, TimeSpan.FromSeconds(20), 64_000, cancellationToken)
            .ConfigureAwait(false);
        return ParseCapabilities(result.Output);
    }

    private static Dictionary<string, string> ScalarMap(string output)
    {
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var raw in output.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
        {
            var separator = raw.IndexOf('=');
            if (separator > 0)
            {
                values[raw[..separator]] = raw[(separator + 1)..];
            }
        }

        return values;
    }

    private static double Num(string? value) =>
        double.TryParse(value?.Trim(), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var number)
            ? number
            : 0;

    private static int Int(string? value) =>
        int.TryParse(value?.Trim(), System.Globalization.NumberStyles.Integer, System.Globalization.CultureInfo.InvariantCulture, out var number)
            ? number
            : 0;
}
