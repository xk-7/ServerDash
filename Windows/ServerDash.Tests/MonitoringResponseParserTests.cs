using ServerDash.Monitoring;

namespace ServerDash.Tests;

public sealed class MonitoringResponseParserTests
{
    [Fact]
    public void Parse_reads_fallback_cpu_memory_and_processes()
    {
        var snapshot = MonitoringResponseParser.Parse(
            """
            mem_total_kb=2048000
            mem_available_kb=1024000
            swap_total_kb=0
            swap_free_kb=0
            cpu=12.5
            cores=4
            load1=0.10
            load5=0.20
            load15=0.30
            disk_used=100
            disk_total=200
            net_rx=8
            net_tx=16
            uptime=1 hour
            distro=Debian GNU/Linux
            kernel=Linux 6.1
            users=1
            processes=12
            proc=1|sshd|1.5|0.2
            """);

        Assert.Equal(12.5, snapshot.CpuUsage);
        Assert.Equal(4, snapshot.CoreCount);
        Assert.Equal(1024000 * 1024, snapshot.MemoryUsedBytes);
        Assert.Equal("sshd", Assert.Single(snapshot.TopProcesses).Name);
        Assert.Equal("Debian GNU/Linux", snapshot.Distribution);
    }

    [Fact]
    public void Parse_rejects_empty_output()
    {
        Assert.Throws<MonitoringException>(() => MonitoringResponseParser.Parse(""));
    }

    [Fact]
    public void Probe_maps_capability_flags()
    {
        var capabilities = MonitoringResponseParser.ParseCapabilities(
            "os=Linux\ndistro=ubuntu\ndocker=1\ngpu=0\nvnstat=0\nproc=1\ngnu=1\n");
        Assert.True(capabilities.HasDocker);
        Assert.False(capabilities.HasGpu);
        Assert.Equal("ubuntu", capabilities.Family);
    }
}
