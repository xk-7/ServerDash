use serde_json::Value;
#[test]
fn monitor_response_matches_swift_memory_and_extended_metrics() {
    let root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../Shared/Contracts/fixtures");
    let raw = std::fs::read_to_string(root.join("monitoring.txt")).unwrap();
    let expected: Value =
        serde_json::from_slice(&std::fs::read(root.join("swift-monitoring.json")).unwrap())
            .unwrap();
    let parsed = serverdash_core::monitor::parse(&raw).unwrap();
    for field in [
        "cpuPercent",
        "memoryUsedBytes",
        "memoryTotalBytes",
        "memoryCachedBytes",
        "swapUsedBytes",
    ] {
        assert_eq!(parsed[field].as_f64(), expected[field].as_f64(), "{field}");
    }
    assert_eq!(
        parsed["processes"][0]["arguments"],
        expected["processArguments"]
    );
    assert_eq!(
        parsed["filesystems"][0]["mountPoint"],
        expected["filesystemMount"]
    );
    assert_eq!(
        parsed["gpus"][0]["memoryUsedBytes"].as_f64(),
        expected["gpuMemoryUsedBytes"].as_f64()
    );
    assert_eq!(parsed["gpus"][0]["fanPercent"], expected["gpuFan"]);
    assert_eq!(
        parsed["dockerContainers"][0]["status"],
        expected["dockerStatus"]
    );
}
