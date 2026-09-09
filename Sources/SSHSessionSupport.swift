import Foundation

enum SSHSessionBootstrap {
    static func handshakeMarker() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ServerDash/handshakes/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return folder.appendingPathComponent("authenticated")
    }
    static func removeMarker(_ marker: URL) { try? FileManager.default.removeItem(at: marker.deletingLastPathComponent()) }
    static func markerArguments(_ marker: URL) -> [String] {
        let path = marker.path.replacingOccurrences(of: "%", with: "%%").replacingOccurrences(of: "'", with: "'\\''")
        return ["-o", "PermitLocalCommand=yes", "-o", "LocalCommand=/usr/bin/touch '\(path)'"]
    }
    static func waitForAuthentication(marker: URL, timeout: TimeInterval) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        while true {
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: marker.path) { return }
            guard clock.now < deadline else { throw WorkbenchConnectionError.unavailable("SSH 连接或身份认证超时。") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    static func runLocalCommand(_ command: String, serverID: UUID) async throws -> String {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        let result = try await ConnectionProcessController.shared.run(ProcessRunRequest(
            executable: "/bin/zsh", arguments: ["-c", command], environment: ProcessInfo.processInfo.environment,
            connectTimeout: 30, totalTimeout: 30, maxOutputBytes: 1024 * 1024, serverID: serverID, module: .terminal))
        guard result.status == 0 else { throw WorkbenchConnectionError.unavailable("本地连接命令退出（\(result.status)）。") }
        return result.output
    }
}

/// Output-only opt-in logs are separate from diagnostics and are never included in sync.
final class SSHSessionOutputLog: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "com.serverdash.ssh.output-log", qos: .utility)
    private var handle: FileHandle?
    private var bytes = 0
    private let limit = 100 * 1024 * 1024
    init(sessionID: UUID) throws {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ServerDash/SessionLogs", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        url = root.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-\(sessionID.uuidString).log")
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw WorkbenchConnectionError.unavailable("无法创建会话日志。")
        }
        handle = try FileHandle(forWritingTo: url)
    }
    func append(_ data: Data) {
        queue.async { [weak self] in
            guard let self, let handle = self.handle else { return }
            do {
                let remaining = self.limit - self.bytes
                if remaining > 0 { try handle.write(contentsOf: data.prefix(remaining)); self.bytes += min(data.count, remaining) }
                if self.bytes >= self.limit {
                    try handle.write(contentsOf: Data("\n[ServerDash: 日志达到 100 MiB 上限，已停止记录。]\n".utf8))
                    try handle.close(); self.handle = nil
                }
            } catch { try? handle.close(); self.handle = nil }
        }
    }
    func close() { queue.sync { try? handle?.close(); handle = nil } }
    deinit { try? handle?.close() }
}
