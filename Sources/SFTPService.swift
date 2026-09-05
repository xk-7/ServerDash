import Foundation

enum RemoteFileKind: String, Sendable {
    case file
    case directory
    case symbolicLink
    case other
}

struct RemoteFileItem: Identifiable, Hashable, Sendable {
    let path: String
    let name: String
    let kind: RemoteFileKind
    let size: Int64
    let permissions: String
    let owner: String
    let group: String
    let modifiedText: String

    var id: String { path }
    var isDirectory: Bool { kind == .directory }
}

struct SFTPDirectoryListing: Sendable {
    let path: String
    let items: [RemoteFileItem]
}

enum SFTPConflictPolicy: String, CaseIterable, Identifiable, Sendable {
    case overwrite
    case skip
    case rename

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overwrite: "覆盖"
        case .skip: "跳过"
        case .rename: "重命名"
        }
    }
}

struct SFTPProgress: Sendable {
    var transferredBytes: Int64
    var totalBytes: Int64
    var speedBytesPerSecond: Double
    var remaining: TimeInterval
    var message: String

    var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(transferredBytes) / Double(totalBytes))
    }
}

enum SFTPError: LocalizedError {
    case commandFailed(String)
    case invalidResponse
    case invalidName
    case cancelled

    var errorDescription: String? {
        switch self {
        case .commandFailed(let detail):
            detail.isEmpty ? "SFTP 操作失败。" : detail
        case .invalidResponse:
            "无法解析服务器返回的目录信息。"
        case .invalidName:
            "名称不能为空，也不能包含“/”。"
        case .cancelled:
            "传输已取消。"
        }
    }
}

enum RemotePath {
    static func child(_ name: String, of directory: String) -> String {
        let base = directory == "/" ? "" : directory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return normalize("/\(base)/\(name)")
    }

    static func parent(of path: String) -> String {
        let normalized = normalize(path)
        guard normalized != "/" else { return "/" }
        let components = normalized.split(separator: "/").dropLast()
        return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }

    static func normalize(_ path: String) -> String {
        guard path != "." else { return "." }
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if !components.isEmpty {
                    components.removeLast()
                }
            default:
                components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }

    static func uniquedName(_ name: String, existing: Set<String>) -> String {
        if !existing.contains(name) { return name }
        let ns = name as NSString
        let ext = ns.pathExtension
        let base = ext.isEmpty ? name : ns.deletingPathExtension
        var index = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            if !existing.contains(candidate) {
                return candidate
            }
            index += 1
        }
    }
}

enum SFTPListingParser {
    static func parse(_ output: String, fallbackPath: String) -> SFTPDirectoryListing {
        let canonicalPath = output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first { $0.contains("Remote working directory:") }
            .flatMap { line -> String? in
                guard let range = line.range(of: "Remote working directory:") else { return nil }
                return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            } ?? RemotePath.normalize(fallbackPath)

        let items = output
            .split(whereSeparator: \.isNewline)
            .compactMap { parseLine(String($0), directory: canonicalPath) }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        return SFTPDirectoryListing(path: canonicalPath, items: items)
    }

    private static func parseLine(_ line: String, directory: String) -> RemoteFileItem? {
        let fields = line.split(
            maxSplits: 8,
            omittingEmptySubsequences: true,
            whereSeparator: \.isWhitespace
        )
        guard fields.count == 9 else { return nil }

        let permissions = String(fields[0])
        guard permissions.count >= 10,
              let typeCharacter = permissions.first,
              let size = Int64(fields[4]) else {
            return nil
        }

        var name = String(fields[8])
        if typeCharacter == "l", let arrowRange = name.range(of: " -> ") {
            name = String(name[..<arrowRange.lowerBound])
        }
        guard name != ".", name != ".." else { return nil }

        let kind: RemoteFileKind
        switch typeCharacter {
        case "d": kind = .directory
        case "-": kind = .file
        case "l": kind = .symbolicLink
        default: kind = .other
        }

        return RemoteFileItem(
            path: RemotePath.child(name, of: directory),
            name: name,
            kind: kind,
            size: size,
            permissions: permissions,
            owner: String(fields[2]),
            group: String(fields[3]),
            modifiedText: "\(fields[5]) \(fields[6]) \(fields[7])"
        )
    }
}

enum LocalTransferMeasure {
    static func size(of url: URL) -> Int64 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return 0
        }
        if !isDirectory.boolValue {
            return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else {
            return 0
        }
        var total: Int64 = 0
        while let file = enumerator.nextObject() as? URL {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }
}

#if os(macOS)
enum SFTPService {
    static func list(
        config: ServerConnectionConfig,
        path: String
    ) async throws -> SFTPDirectoryListing {
        let interval = PerformanceTrace.begin(.sftpList)
        defer { PerformanceTrace.end(interval) }
        let output = try await run(
            config: config,
            commands: [
                "cd \(quote(path))",
                "pwd",
                "ls -la"
            ]
        )
        return SFTPListingParser.parse(output, fallbackPath: path)
    }

    static func upload(
        localURLs: [URL],
        to remoteDirectory: String,
        config: ServerConnectionConfig,
        policy: SFTPConflictPolicy,
        existingNames: Set<String>,
        onProgress: (@Sendable (SFTPProgress) -> Void)? = nil
    ) async throws {
        var commands: [String] = []
        var totalBytes: Int64 = 0
        var destinations: [String] = []
        for url in localURLs {
            var name = url.lastPathComponent
            if existingNames.contains(name) {
                switch policy {
                case .skip:
                    continue
                case .rename:
                    name = RemotePath.uniquedName(name, existing: existingNames)
                case .overwrite:
                    break
                }
            }
            let destination = RemotePath.child(name, of: remoteDirectory)
            destinations.append(destination)
            totalBytes += LocalTransferMeasure.size(of: url)
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            let flag = isDirectory.boolValue ? "put -pr" : "put -p"
            commands.append("\(flag) \(quote(url.path)) \(quote(destination))")
        }
        guard !commands.isEmpty else { return }
        let resolvedDestinations = destinations
        try await runTransfer(
            config: config,
            commands: commands,
            totalBytes: totalBytes,
            measure: {
                var total: Int64 = 0
                for path in resolvedDestinations {
                    total += (try? await remoteSize(config: config, path: path)) ?? 0
                }
                return total
            },
            onProgress: onProgress
        )
    }

    static func download(
        item: RemoteFileItem,
        to localURL: URL,
        config: ServerConnectionConfig,
        policy: SFTPConflictPolicy,
        onProgress: (@Sendable (SFTPProgress) -> Void)? = nil
    ) async throws {
        if FileManager.default.fileExists(atPath: localURL.path) {
            switch policy {
            case .skip:
                return
            case .rename:
                let renamed = uniquedLocalURL(localURL)
                try await download(
                    item: item,
                    to: renamed,
                    config: config,
                    policy: .overwrite,
                    onProgress: onProgress
                )
                return
            case .overwrite:
                break
            }
        }
        let flag = item.isDirectory ? "get -pr" : "get -p"
        let total = item.isDirectory ? max(item.size, 1) : item.size
        try await runTransfer(
            config: config,
            commands: ["\(flag) \(quote(item.path)) \(quote(localURL.path))"],
            totalBytes: total,
            measure: { LocalTransferMeasure.size(of: localURL) },
            onProgress: onProgress
        )
        guard FileManager.default.fileExists(atPath: localURL.path) else {
            throw SFTPError.commandFailed("传输未完成，未将半成品标为成功。")
        }
    }

    static func createDirectory(
        named name: String,
        in remoteDirectory: String,
        config: ServerConnectionConfig
    ) async throws {
        try validateName(name)
        _ = try await run(
            config: config,
            commands: ["mkdir \(quote(RemotePath.child(name, of: remoteDirectory)))"]
        )
    }

    static func createFile(
        named name: String,
        in remoteDirectory: String,
        config: ServerConnectionConfig
    ) async throws {
        try validateName(name)
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerDash-empty-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: temporary.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: temporary) }
        _ = try await run(
            config: config,
            commands: [
                "put \(quote(temporary.path)) \(quote(RemotePath.child(name, of: remoteDirectory)))"
            ]
        )
    }

    static func rename(
        item: RemoteFileItem,
        to newName: String,
        config: ServerConnectionConfig
    ) async throws {
        try validateName(newName)
        let destination = RemotePath.child(newName, of: RemotePath.parent(of: item.path))
        _ = try await run(
            config: config,
            commands: ["rename \(quote(item.path)) \(quote(destination))"]
        )
    }

    static func move(
        item: RemoteFileItem,
        to remoteDirectory: String,
        config: ServerConnectionConfig
    ) async throws {
        let destination = RemotePath.child(item.name, of: remoteDirectory)
        _ = try await run(
            config: config,
            commands: ["rename \(quote(item.path)) \(quote(destination))"]
        )
    }

    static func delete(
        item: RemoteFileItem,
        config: ServerConnectionConfig,
        recursive: Bool = false
    ) async throws {
        let command: String
        if item.isDirectory {
            command = recursive ? "rm -r \(quote(item.path))" : "rmdir \(quote(item.path))"
        } else {
            command = "rm \(quote(item.path))"
        }
        _ = try await run(config: config, commands: [command])
    }

    static func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func validateName(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("/"),
              trimmed != ".",
              trimmed != ".." else {
            throw SFTPError.invalidName
        }
    }

    private static func uniquedLocalURL(_ url: URL) -> URL {
        let existing = Set(
            ((try? FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? [])
                .map(\.lastPathComponent)
        )
        let name = RemotePath.uniquedName(url.lastPathComponent, existing: existing)
        return url.deletingLastPathComponent().appendingPathComponent(name)
    }

    private static func remoteSize(config: ServerConnectionConfig, path: String) async throws -> Int64 {
        let listing = try await list(config: config, path: RemotePath.parent(of: path))
        return listing.items.first { $0.path == path }?.size ?? 0
    }

    private static func runTransfer(
        config: ServerConnectionConfig,
        commands: [String],
        totalBytes: Int64,
        measure: @escaping @Sendable () async -> Int64,
        onProgress: (@Sendable (SFTPProgress) -> Void)?
    ) async throws {
        let interval = PerformanceTrace.begin(.sftpTransfer)
        defer { PerformanceTrace.end(interval) }
        let started = Date()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = try await run(
                    config: config,
                    commands: commands,
                    totalTimeout: 21_600
                )
            }
            if let onProgress {
                group.addTask {
                    while !Task.isCancelled {
                        let transferred = await measure()
                        let elapsed = max(0.1, Date().timeIntervalSince(started))
                        let speed = Double(transferred) / elapsed
                        let remaining = speed > 0
                            ? Double(max(0, totalBytes - transferred)) / speed
                            : 0
                        PerformanceTrace.event(.sftpProgressPublish)
                        onProgress(
                            SFTPProgress(
                                transferredBytes: transferred,
                                totalBytes: totalBytes,
                                speedBytesPerSecond: speed,
                                remaining: remaining,
                                message: "已传输 \(DisplayFormat.bytes(Double(transferred)))"
                            )
                        )
                        try await Task.sleep(for: .milliseconds(400))
                    }
                }
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private static func run(
        config: ServerConnectionConfig,
        commands: [String],
        totalTimeout: TimeInterval = 60
    ) async throws -> String {
        let stdin = Data((commands + ["bye"]).joined(separator: "\n").appending("\n").utf8)
        do {
            let plan = try SystemOpenSSHConnectionProvider().launchPlan(
                for: config,
                purpose: .fileTransfer
            )
            let result = try await ConnectionProcessController.shared.run(
                ProcessRunRequest(
                    executable: plan.executable,
                    arguments: plan.arguments,
                    environment: plan.environment,
                    stdin: stdin,
                    connectTimeout: config.connectTimeout,
                    totalTimeout: totalTimeout,
                    maxOutputBytes: 4_000_000,
                    serverID: config.id,
                    module: .sftp,
                    host: config.host,
                    port: config.port
                )
            )
            if let commandError = firstCommandError(in: result.output + "\n" + result.error) {
                throw SFTPError.commandFailed(commandError)
            }
            EventLogStore.shared.append(
                serverID: config.id,
                module: .sftp,
                message: "SFTP 命令完成"
            )
            return result.output
        } catch is CancellationError {
            throw SFTPError.cancelled
        } catch let error as ConnectionError {
            if error == .cancelled {
                throw SFTPError.cancelled
            }
            EventLogStore.shared.append(
                serverID: config.id,
                module: .sftp,
                level: "error",
                message: "SFTP 命令失败（\(error.code)）"
            )
            switch error {
            case .hostKeyChanged, .hostKeyUntrusted:
                throw error
            default:
                break
            }
            throw SFTPError.commandFailed(error.localizedDescription)
        }
    }

    private static func firstCommandError(in output: String) -> String? {
        output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first { line in
                let lowered = line.lowercased()
                let firstFieldCount = line.split(whereSeparator: \.isWhitespace).first?.count ?? 0
                let looksLikeListingRow = line.first.map { "bcdlps-".contains($0) } == true &&
                    firstFieldCount >= 10
                return !looksLikeListingRow && (
                    lowered.contains("no such file") ||
                    lowered.contains("permission denied") ||
                    lowered.contains("couldn't") ||
                    lowered.contains("failure")
                )
            }
    }
}
#endif
