use anyhow::{ensure, Result};
use base64::Engine;
use serde_json::{json, Map, Value};
use std::collections::HashMap;

pub const COMMAND: &str = include_str!("monitor.sh");
pub fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

pub fn parse(text: &str) -> Result<Value> {
    ensure!(
        text.len() <= 4 * 1024 * 1024,
        "Monitoring response exceeded limit"
    );
    let mut scalars = HashMap::new();
    let mut records: Map<String, Value> = Map::new();
    for line in text.lines() {
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        if matches!(
            key,
            "proc" | "core" | "iface" | "fs" | "diskio" | "gpu" | "gproc" | "dcont" | "listener"
        ) {
            let fields: Vec<&str> = value.split('|').collect();
            records
                .entry(key)
                .or_insert_with(|| json!([]))
                .as_array_mut()
                .unwrap()
                .push(json!(fields));
        } else {
            scalars.insert(key.to_owned(), value.to_owned());
        }
    }
    let number = |key: &str| -> Option<f64> {
        scalars
            .get(key)?
            .parse::<f64>()
            .ok()
            .filter(|v| v.is_finite() && *v >= 0.0)
    };
    let memory_total = number("mem_total_kb").unwrap_or(0.0) * 1024.0;
    ensure!(
        memory_total > 0.0 && number("cpu").is_some(),
        "Linux monitoring response is missing CPU or memory metrics"
    );
    let memory_available = number("mem_available_kb").unwrap_or(0.0) * 1024.0;
    let memory_free = number("mem_free_kb").unwrap_or(0.0) * 1024.0;
    let memory_cached =
        (number("mem_cached_kb").unwrap_or(0.0) + number("mem_buffers_kb").unwrap_or(0.0)) * 1024.0;
    let memory_used = (memory_total
        - if memory_free + memory_cached > 0.0 {
            memory_free + memory_cached
        } else {
            memory_available
        })
    .max(0.0);
    let mut snapshot = json!({"timestamp":now_ms(),"status":"online","cpuPercent":number("cpu").unwrap_or(0.0).min(100.0),"memoryUsed":memory_used,"memoryTotal":memory_total,"memoryPercent":(memory_used/memory_total*100.0).clamp(0.0,100.0),"diskUsed":number("disk_used"),"diskTotal":number("disk_total"),"networkRx":number("net_rx"),"networkTx":number("net_tx"),"load":[number("load1"),number("load5"),number("load15")],"cores":number("cores"),"distro":scalars.get("distro"),"kernel":scalars.get("kernel"),"uptime":scalars.get("uptime"),"metrics":scalars,"records":records});
    snapshot["memoryCachedBytes"] = json!(memory_cached);
    snapshot["swapUsedBytes"] = json!(((number("swap_total_kb").unwrap_or(0.0)
        - number("swap_free_kb").unwrap_or(0.0))
        * 1024.0)
        .max(0.0));
    for (source, destination) in [
        ("proc", "processes"),
        ("fs", "filesystems"),
        ("gpu", "gpus"),
        ("dcont", "dockerContainers"),
    ] {
        let items:Vec<Value>=records.get(source).and_then(Value::as_array).into_iter().flatten().filter_map(|fields|{
            let fields:Vec<&str>=fields.as_array()?.iter().map(|v|v.as_str().unwrap_or("")).collect();
            let n=|i:usize|fields.get(i)?.parse::<f64>().ok().filter(|v|v.is_finite()&&*v>=0.0);
            match source {
                "proc" if fields.len()>=7=>Some(json!({"pid":n(0),"user":fields[1],"name":fields[2],"cpu":n(3),"memory":n(4),"threadCount":n(5),"arguments":fields[6..].join("|")})),
                "fs" if fields.len()>=5=>Some(json!({"device":fields[0],"filesystemType":fields[1],"usedBytes":n(2),"totalBytes":n(3),"mountPoint":fields[4..].join("|")})),
                "gpu" if fields.len()==10=>Some(json!({"index":n(0),"uuid":fields[1],"name":fields[2],"utilization":n(3),"memoryUsedBytes":n(4).map(|v|v*1048576.0),"memoryTotalBytes":n(5).map(|v|v*1048576.0),"fanPercent":n(6),"temperatureCelsius":n(7),"powerWatts":n(8),"powerLimitWatts":n(9)})),
                "dcont" if fields.len()>=5=>Some(json!({"id":fields[0],"name":fields[1],"image":fields[2],"state":fields[3],"status":fields[4..].join("|")})),
                _=>None
            }
        }).collect();
        snapshot[destination] = json!(items);
    }
    snapshot["capturedAt"] = json!(chrono::Utc::now().to_rfc3339());
    snapshot["memoryUsedBytes"] = snapshot["memoryUsed"].clone();
    snapshot["memoryTotalBytes"] = snapshot["memoryTotal"].clone();
    snapshot["diskUsedBytes"] = snapshot["diskUsed"].clone();
    snapshot["diskTotalBytes"] = snapshot["diskTotal"].clone();
    snapshot["loadAverage"] = snapshot["load"].clone();
    for key in ["vnstat_json", "geo_json"] {
        if let Some(encoded) = scalars.get(key) {
            if let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(encoded) {
                if let Ok(value) = serde_json::from_slice::<Value>(&bytes) {
                    snapshot[key.trim_end_matches("_json")] = value;
                }
            }
        }
    }
    Ok(snapshot)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn monitoring_keeps_repeated_records_and_equals() {
        let v=parse("cpu=12.5\nmem_total_kb=1024\nmem_available_kb=256\nproc=1|root|a|2|0|1|x=y\nproc=2|root|b|3|0|1|b\ngpu=0|uuid|RTX|40|10|100|N/A|45|N/A|N/A\n").unwrap();
        assert_eq!(v["records"]["proc"].as_array().unwrap().len(), 2);
        assert_eq!(v["records"]["proc"][0][6], "x=y");
        assert_eq!(v["memoryPercent"], 75.0);
    }
    #[test]
    fn refuses_missing_or_nonfinite_samples() {
        assert!(parse("cpu=NaN\nmem_total_kb=1024").is_err());
        assert!(parse("error=permission denied").is_err());
    }
}
