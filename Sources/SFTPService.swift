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

enum SFTPError: LocalizedError {
    case commandFailed(String)
    case invalidResponse
    case invalidName

    var errorDescription: String? {
        switch self {
        case .commandFailed(let detail):
            detail.isEmpty ? "SFTP 操作失败。" : detail
        case .invalidResponse:
            "无法解析服务器返回的目录信息。"
        case .invalidName:
            "名称不能为空，也不能包含“/”。"
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

enum SFTPService {
    static func list(
        config: ServerConnectionConfig,
        path: String
    ) async throws -> SFTPDirectoryListing {
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
        config: ServerConnectionConfig
    ) async throws {
        let commands = localURLs.map { url in
            let destination = RemotePath.child(url.lastPathComponent, of: remoteDirectory)
            return "put -p \(quote(url.path)) \(quote(destination))"
        }
        _ = try await run(config: config, commands: commands)
    }

    static func download(
        item: RemoteFileItem,
        to localURL: URL,
        config: ServerConnectionConfig
    ) async throws {
        guard item.kind == .file || item.kind == .symbolicLink else {
            throw SFTPError.commandFailed("首版仅支持下载文件。")
        }
        _ = try await run(
            config: config,
            commands: ["get -p \(quote(item.path)) \(quote(localURL.path))"]
        )
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

    static func delete(
        item: RemoteFileItem,
        config: ServerConnectionConfig
    ) async throws {
        let command = item.isDirectory
            ? "rmdir \(quote(item.path))"
            : "rm \(quote(item.path))"
        _ = try await run(config: config, commands: [command])
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

    private static func run(
        config: ServerConnectionConfig,
        commands: [String]
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let inputPipe = Pipe()
            let outputPipe = Pipe()
            let errorPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
            process.arguments = arguments(for: config)
            process.environment = SSHSupport.environment(for: config)
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            do {
                try process.run()
            } catch {
                throw SFTPError.commandFailed(error.localizedDescription)
            }

            let outputTask = Task.detached {
                outputPipe.fileHandleForReading.readDataToEndOfFile()
            }
            let errorTask = Task.detached {
                errorPipe.fileHandleForReading.readDataToEndOfFile()
            }

            do {
                let commandText = (commands + ["bye"]).joined(separator: "\n") + "\n"
                try inputPipe.fileHandleForWriting.write(contentsOf: Data(commandText.utf8))
                try inputPipe.fileHandleForWriting.close()
            } catch {
                process.terminate()
                throw SFTPError.commandFailed(error.localizedDescription)
            }
            process.waitUntilExit()

            let output = String(
                decoding: await outputTask.value,
                as: UTF8.self
            )
            let errorOutput = String(
                decoding: await errorTask.value,
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)

            guard process.terminationStatus == 0 else {
                throw SFTPError.commandFailed(errorOutput)
            }
            if let commandError = firstCommandError(in: output + "\n" + errorOutput) {
                throw SFTPError.commandFailed(commandError)
            }
            return output
        }.value
    }

    private static func arguments(for config: ServerConnectionConfig) -> [String] {
        var arguments = [
            "-q",
            "-P", String(config.port),
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=yes"
        ]
        switch config.authentication {
        case .privateKey:
            if !config.privateKeyPath.isEmpty {
                arguments += [
                    "-i", NSString(string: config.privateKeyPath).expandingTildeInPath,
                    "-o", "IdentitiesOnly=yes"
                ]
            }
        case .password:
            arguments += [
                "-o", "PreferredAuthentications=password,keyboard-interactive",
                "-o", "PubkeyAuthentication=no"
            ]
        }
        arguments.append("\(config.username)@\(config.host)")
        return arguments
    }

    private static func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
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
