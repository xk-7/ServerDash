# Frozen from the native Linux collector; private temporary directory; geolocation disabled.
sh -lc '
umask 077
    sample_dir=$(mktemp -d "${TMPDIR:-/tmp}/serverdash.XXXXXXXXXX") || exit 1
    trap "rm -rf \"$sample_dir\"" EXIT HUP INT TERM
    sample_base="$sample_dir/sample"
    SERVERDASH_DISABLE_GEO=1
cpu_a="${sample_base}.cpu.a"
cpu_b="${sample_base}.cpu.b"
disk_a="${sample_base}.disk.a"
disk_b="${sample_base}.disk.b"
grep "^cpu" /proc/stat 2>/dev/null > "$cpu_a"
cat /proc/diskstats 2>/dev/null > "$disk_a"
sleep 0.25
grep "^cpu" /proc/stat 2>/dev/null > "$cpu_b"
cat /proc/diskstats 2>/dev/null > "$disk_b"
cpu_metrics=$(awk "NR==FNR {u[\$1]=\$2; n[\$1]=\$3; s[\$1]=\$4; i[\$1]=\$5; w[\$1]=\$6; q[\$1]=\$7; z[\$1]=\$8; t[\$1]=\$9; next} {k=\$1; du=\$2-u[k]; dn=\$3-n[k]; ds=\$4-s[k]; di=\$5-i[k]; dw=\$6-w[k]; dq=\$7-q[k]; dz=\$8-z[k]; dt=\$9-t[k]; total=du+dn+ds+di+dw+dq+dz+dt; if(total<=0) next; user_pct=du*100/total; nice_pct=dn*100/total; system_pct=(ds+dq+dz)*100/total; wait_pct=dw*100/total; steal_pct=dt*100/total; if(k==\"cpu\") printf \"cpu=%.2f\\ncpu_user=%.2f\\ncpu_system=%.2f\\ncpu_iowait=%.2f\\n\", 100-(di*100/total), user_pct+nice_pct, system_pct, wait_pct; else if(k ~ /^cpu[0-9]+$/) printf \"core=%s|%.2f|%.2f|%.2f|%.2f|%.2f\\n\", substr(k,4), user_pct, system_pct, nice_pct, wait_pct, steal_pct}" "$cpu_a" "$cpu_b")
if printf "%s\n" "$cpu_metrics" | grep -q "^cpu="; then
  printf "%s\n" "$cpu_metrics"
else
  printf "cpu=0\n%s\n" "$cpu_metrics"
fi
cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
cpu_model=$(awk -F: "/model name|Hardware|Processor/ {sub(/^[ \\t]+/,\"\",\$2); print \$2; exit}" /proc/cpuinfo 2>/dev/null)
cpu_temp=$(for f in /sys/class/thermal/thermal_zone*/temp; do [ -r "$f" ] && awk "{if(\$1>1000) printf \"%.1f\\n\", \$1/1000; else printf \"%.1f\\n\", \$1}" "$f"; done 2>/dev/null | sort -nr | head -1)
set -- $(cat /proc/loadavg 2>/dev/null || echo "0 0 0")
load1=$1; load5=$2; load15=$3
mem_total=$(awk "/MemTotal/ {print \$2}" /proc/meminfo 2>/dev/null)
mem_available=$(awk "/MemAvailable/ {print \$2}" /proc/meminfo 2>/dev/null)
mem_free=$(awk "/^MemFree:/ {print \$2}" /proc/meminfo 2>/dev/null)
mem_cached=$(awk "/^Cached:/ {print \$2}" /proc/meminfo 2>/dev/null)
mem_buffers=$(awk "/^Buffers:/ {print \$2}" /proc/meminfo 2>/dev/null)
swap_total=$(awk "/SwapTotal/ {print \$2}" /proc/meminfo 2>/dev/null)
swap_free=$(awk "/SwapFree/ {print \$2}" /proc/meminfo 2>/dev/null)
set -- $(df -B1 / 2>/dev/null | awk "NR==2 {print \$3, \$2}")
disk_used=$1; disk_total=$2
awk -F"[: ]+" "NR>2 {name=\$2; rx=\$3; tx=\$11; if(name != \"\") {printf \"iface=%s|%.0f|%.0f\\n\", name, rx, tx; score=rx+tx; if(name !~ /^(lo|docker|veth|br-|virbr|tun|tap|tailscale|zt)/ && (score>max || active==\"\")){max=score; active=name; arx=rx; atx=tx}}} END {printf \"active_iface=%s\\nnet_rx=%.0f\\nnet_tx=%.0f\\n\", active, arx+0, atx+0}" /proc/net/dev 2>/dev/null
awk -v interval=0.25 "NR==FNR {reads[\$3]=\$4; rsec[\$3]=\$6; rms[\$3]=\$7; writes[\$3]=\$8; wsec[\$3]=\$10; wms[\$3]=\$11; next} {dev=\$3; if(dev !~ /^(sd|vd|xvd|hd|nvme|mmcblk)/) next; if(dev ~ /^(sd|vd|xvd|hd)[a-z]+[0-9]+$/ || dev ~ /p[0-9]+$/) next; dr=\$4-reads[dev]; dw=\$8-writes[dev]; drs=\$6-rsec[dev]; dws=\$10-wsec[dev]; drm=\$7-rms[dev]; dwm=\$11-wms[dev]; if(dr<0||dw<0) next; printf \"diskio=%s|%.0f|%.0f|%.2f|%.2f|%.2f|%.2f|%.0f|%.0f\\n\", dev, drs*512/interval, dws*512/interval, dr/interval, dw/interval, dr>0?drm/dr:0, dw>0?dwm/dw:0, \$6*512, \$10*512}" "$disk_a" "$disk_b"
rm -f "$cpu_a" "$cpu_b" "$disk_a" "$disk_b"
uptime_text=$(uptime -p 2>/dev/null | sed "s/^up //" || true)
distro=$(awk -F= "/^PRETTY_NAME=/ {gsub(/^\\\"|\\\"$/,\"\",\$2); print \$2}" /etc/os-release 2>/dev/null)
kernel=$(uname -sr 2>/dev/null)
users=$(who 2>/dev/null | wc -l | tr -d " ")
processes=$(ps -e --no-headers 2>/dev/null | wc -l | tr -d " ")
printf "cores=%s\ncpu_model=%s\ncpu_temp=%s\nload1=%s\nload5=%s\nload15=%s\n" "$cores" "$cpu_model" "$cpu_temp" "$load1" "$load5" "$load15"
printf "mem_total_kb=%s\nmem_available_kb=%s\nmem_free_kb=%s\nmem_cached_kb=%s\nmem_buffers_kb=%s\nswap_total_kb=%s\nswap_free_kb=%s\n" "$mem_total" "$mem_available" "$mem_free" "$mem_cached" "$mem_buffers" "$swap_total" "$swap_free"
printf "disk_used=%s\ndisk_total=%s\n" "$disk_used" "$disk_total"
printf "uptime=%s\ndistro=%s\nkernel=%s\nusers=%s\nprocesses=%s\n" "$uptime_text" "$distro" "$kernel" "$users" "$processes"
ps -eo pid=,user=,comm=,%cpu=,%mem=,nlwp=,args= --sort=-%cpu 2>/dev/null | awk "NR<=100 {cmd=\$7; for(i=8;i<=NF;i++) cmd=cmd \" \" \$i; gsub(/[|]/,\"/\",cmd); printf \"proc=%s|%s|%s|%s|%s|%s|%s\\n\", \$1, \$2, \$3, \$4, \$5, \$6, cmd}"
if [ -r /proc/sys/fs/file-nr ]; then
  awk "{printf \"file_handles_used=%.0f\\nfile_handles_limit=%s\\n\", \$1-\$2, \$3}" /proc/sys/fs/file-nr
fi
if [ -r /proc/net/sockstat ]; then
  awk "\$1==\"sockets:\" {printf \"socket_total=%d\\n\",\$3} \$1==\"TCP:\" {printf \"socket_tcp=%d\\nsocket_timewait=%d\\n\",\$3,\$7} \$1==\"UDP:\" {printf \"socket_udp=%d\\n\",\$3}" /proc/net/sockstat
  awk "FNR>1 && \$4==\"0A\" {n++} END {printf \"socket_listening=%d\\n\",n}" /proc/net/tcp /proc/net/tcp6 2>/dev/null
fi
if command -v ss >/dev/null 2>&1; then
  if ss -H -lntup > "${sample_base}.listeners" 2>/dev/null; then
    printf "listeners_available=1\n"
    awk "NR<=200 {process=\$7; for(i=8;i<=NF;i++) process=process \" \" \$i; gsub(/[|]/,\"/\",process); printf \"listener=%s|%s|%s\\n\",\$1,\$5,process}" "${sample_base}.listeners"
  else
    printf "listeners_error=ss failed\n"
  fi
  rm -f "${sample_base}.listeners"
fi
uid=$(id -u 2>/dev/null || echo 0)
slow_cache="$sample_dir/monitor.cache"
now=$(date +%s)
cache_time=$(stat -c %Y "$slow_cache" 2>/dev/null || echo 0)
cache_age=$((now-cache_time))
if [ ! -s "$slow_cache" ] || [ "$cache_age" -gt 15 ]; then
  slow_tmp="${slow_cache}.$$"
  {
    df -B1 -PT 2>/dev/null | awk "NR>1 {dev=\$1; type=\$2; total=\$3; used=\$4; mount=\$7; for(i=8;i<=NF;i++) mount=mount \" \" \$i; if(total>0) {gsub(/[|]/,\"/\",dev); gsub(/[|]/,\"/\",mount); printf \"fs=%s|%s|%.0f|%.0f|%s\\n\", dev, type, used, total, mount}}"
    if command -v nvidia-smi >/dev/null 2>&1; then
      driver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 | tr -d " ")
      cuda=$(nvidia-smi 2>/dev/null | sed -n "s/.*CUDA Version: \\([0-9.]*\\).*/\\1/p" | head -1)
      printf "gpu_driver=%s\ncuda_version=%s\n" "$driver" "$cuda"
      nvidia-smi --query-gpu=index,uuid,name,utilization.gpu,memory.used,memory.total,fan.speed,temperature.gpu,power.draw,power.limit --format=csv,noheader,nounits 2>/dev/null | awk -F"," "{for(i=1;i<=NF;i++) gsub(/^[ \\t]+|[ \\t]+$/,\"\",\$i); gsub(/[|]/,\"/\",\$3); printf \"gpu=%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\\n\", \$1,\$2,\$3,\$4,\$5,\$6,\$7,\$8,\$9,\$10}"
      nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_memory --format=csv,noheader,nounits 2>/dev/null | awk -F"," "{for(i=1;i<=NF;i++) gsub(/^[ \\t]+|[ \\t]+$/,\"\",\$i); gsub(/[|]/,\"/\",\$3); printf \"gproc=%s|%s|%s|%s\\n\", \$1,\$2,\$3,\$4}"
    fi
    if command -v docker >/dev/null 2>&1 && docker version --format "{{.Server.Version}}" >/dev/null 2>&1; then
      printf "docker_available=1\ndocker_version=%s\n" "$(docker version --format "{{.Server.Version}}" 2>/dev/null)"
      docker ps -a --no-trunc --format "dcont={{.ID}}|{{.Names}}|{{.Image}}|{{.State}}|{{.Status}}" 2>/dev/null
    else
      printf "docker_available=0\n"
    fi
    vn_source=""
    vn_json=""
    if command -v vnstat >/dev/null 2>&1; then
      vn_source="vnstat"
      vn_json=$(vnstat --json 2>/dev/null)
    elif command -v docker >/dev/null 2>&1; then
      vn_container=$(docker ps --format "{{.Names}}" 2>/dev/null | awk "tolower(\$0) ~ /vnstat/ {print; exit}")
      if [ -n "$vn_container" ]; then
        vn_source="docker"
        vn_json=$(docker exec "$vn_container" vnstat --json 2>/dev/null)
      fi
    fi
    if [ -n "$vn_source" ] && [ -n "$vn_json" ]; then
      printf "vnstat_available=1\nvnstat_source=%s\nvnstat_json=%s\n" "$vn_source" "$(printf "%s" "$vn_json" | base64 | tr -d "\\n")"
    else
      printf "vnstat_available=0\n"
    fi
    geo_cache="$sample_dir/geo.json"
    geo_time=$(stat -c %Y "$geo_cache" 2>/dev/null || echo 0)
    geo_age=$((now-geo_time))
    if [ "$SERVERDASH_DISABLE_GEO" = "1" ]; then
      rm -f "$geo_cache" "${geo_cache}.$$"
    else
      if [ ! -s "$geo_cache" ] || [ "$geo_age" -gt 86400 ]; then
        if command -v curl >/dev/null 2>&1; then
          curl -fsS --max-time 4 https://ipinfo.io/json > "${geo_cache}.$$" 2>/dev/null && mv "${geo_cache}.$$" "$geo_cache"
        fi
      fi
      if [ -s "$geo_cache" ]; then
        printf "geo_json=%s\n" "$(base64 < "$geo_cache" | tr -d "\\n")"
      fi
    fi
  } > "$slow_tmp"
  chmod 600 "$slow_tmp" 2>/dev/null || true
  mv "$slow_tmp" "$slow_cache"
fi
cat "$slow_cache" 2>/dev/null
'
