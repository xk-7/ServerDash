#if os(macOS)
import Darwin

/// Sampled only while constructing a benchmark report, outside timed operations.
/// Darwin reports ru_maxrss in bytes, as a process-lifetime high-water mark.
enum MacPerformanceResourceMetrics {
    static func cumulativeTestHostSnapshot() -> [String: Any] {
        var usage = rusage()
        let status = getrusage(RUSAGE_SELF, &usage)
        let failureCode = status == 0 ? nil : Int(errno)
        var result: [String: Any] = [
            "source": "Darwin.getrusage(RUSAGE_SELF).ru_maxrss",
            "unit": "bytes",
            "processIdentifier": Int(getpid()),
            "scope": "Cumulative process-lifetime peak resident memory of the XCTest host, including earlier tests and fixtures in this process. Not a per-operation increment, not the QA app, and not the xcodebuild driver."
        ]
        if let failureCode {
            result["unavailableErrno"] = failureCode
        } else {
            result["peakResidentMemoryBytes"] = usage.ru_maxrss
        }
        return result
    }
}
#endif
