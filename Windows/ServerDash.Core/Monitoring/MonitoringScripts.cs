namespace ServerDash.Monitoring;

public static class MonitoringScripts
{
    public const string Probe = """
        sh -lc '
        printf "os=%s\n" "$(uname -s 2>/dev/null)"
        printf "distro=%s\n" "$(awk -F= "/^ID=/ {gsub(/\"/,\"\",\$2); print \$2}" /etc/os-release 2>/dev/null)"
        command -v docker >/dev/null 2>&1 && echo docker=1 || echo docker=0
        command -v nvidia-smi >/dev/null 2>&1 && echo gpu=1 || echo gpu=0
        command -v vnstat >/dev/null 2>&1 && echo vnstat=1 || echo vnstat=0
        [ -r /proc/stat ] && echo proc=1 || echo proc=0
        df --version >/dev/null 2>&1 && echo gnu=1 || echo gnu=0
        '
        """;

    public const string FallbackCollect = """
        sh -lc '
        mem_total=$(awk "/MemTotal/ {print \$2}" /proc/meminfo 2>/dev/null)
        mem_available=$(awk "/MemAvailable/ {print \$2}" /proc/meminfo 2>/dev/null)
        swap_total=$(awk "/SwapTotal/ {print \$2}" /proc/meminfo 2>/dev/null)
        swap_free=$(awk "/SwapFree/ {print \$2}" /proc/meminfo 2>/dev/null)
        [ -z "$mem_total" ] && mem_total=0
        [ -z "$mem_available" ] && mem_available=0
        [ -z "$swap_total" ] && swap_total=0
        [ -z "$swap_free" ] && swap_free=0
        printf "serverdash_protocol=1\nmem_total_kb=%s\nmem_available_kb=%s\nswap_total_kb=%s\nswap_free_kb=%s\n" "$mem_total" "$mem_available" "$swap_total" "$swap_free"
        cpu_idle=$(LC_ALL=C top -bn1 2>/dev/null | awk "/Cpu\\(s\\)/ {for(i=1;i<=NF;i++) if(\$i ~ /id/) {gsub(/[^0-9.]/,\"\",\$i); print \$i; exit}}")
        [ -z "$cpu_idle" ] && cpu_idle=100
        cpu=$(awk -v idle="$cpu_idle" "BEGIN {printf \"%.2f\", 100-idle}")
        cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
        set -- $(cat /proc/loadavg 2>/dev/null || echo "0 0 0")
        load1=$1; load5=$2; load15=$3
        set -- $(df -B1 / 2>/dev/null | awk "NR==2 {print \$3, \$2}")
        disk_used=$1; disk_total=$2
        set -- $(awk -F"[: ]+" "NR>2 {rx+=\$3; tx+=\$11} END {print rx+0, tx+0}" /proc/net/dev 2>/dev/null)
        net_rx=$1; net_tx=$2
        uptime_text=$(uptime -p 2>/dev/null | sed "s/^up //" || true)
        distro=$(awk -F= "/^PRETTY_NAME=/ {gsub(/^\\\"|\\\"$/,\"\",\$2); print \$2}" /etc/os-release 2>/dev/null)
        kernel=$(uname -sr 2>/dev/null)
        users=$(who 2>/dev/null | wc -l | tr -d " ")
        processes=$(ps -e 2>/dev/null | awk "NR>1 {count++} END {print count+0}")
        printf "cpu=%s\ncores=%s\nload1=%s\nload5=%s\nload15=%s\n" "$cpu" "$cores" "$load1" "$load5" "$load15"
        printf "disk_used=%s\ndisk_total=%s\nnet_rx=%s\nnet_tx=%s\n" "$disk_used" "$disk_total" "$net_rx" "$net_tx"
        printf "uptime=%s\ndistro=%s\nkernel=%s\nusers=%s\nprocesses=%s\n" "$uptime_text" "$distro" "$kernel" "$users" "$processes"
        ps -eo pid=,comm=,%cpu=,%mem= 2>/dev/null | sort -k3 -nr | awk "NR<=5 {printf \"proc=%s|%s|%s|%s\\n\", \$1, \$2, \$3, \$4}"
        '
        """;
}
