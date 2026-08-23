import CryptoKit
import Foundation
import Security

enum KeychainError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            SecCopyErrorMessageString(status, nil) as String? ?? "Keychain 错误：\(status)"
        case .invalidData:
            "无法读取 Keychain 中的凭据"
        }
    }
}

enum KeychainService {
    static let serviceName = "com.serverdash.credentials"

    static func savePassword(_ password: String, for credentialID: UUID) throws {
        let account = credentialID.uuidString
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        let status: OSStatus
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        } else {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    static func password(for credentialID: UUID) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: credentialID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        return password
    }

    static func hasPassword(for credentialID: UUID) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: credentialID.uuidString,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func deletePassword(for credentialID: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: credentialID.uuidString
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

enum SSHSupport {
    static func arguments(
        for config: ServerConnectionConfig,
        strictHostChecking: String,
        batchMode: Bool = false,
        remoteCommand: String? = nil
    ) -> [String] {
        var arguments = [
            "-p", String(config.port),
            "-o", "ConnectTimeout=8",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=\(strictHostChecking)"
        ]

        switch config.authentication {
        case .privateKey:
            if !config.privateKeyPath.isEmpty {
                arguments += ["-i", NSString(string: config.privateKeyPath).expandingTildeInPath]
                arguments += ["-o", "IdentitiesOnly=yes"]
            }
        case .password:
            arguments += ["-o", "PreferredAuthentications=password,keyboard-interactive"]
            arguments += ["-o", "PubkeyAuthentication=no"]
        }
        if batchMode {
            arguments += ["-o", "BatchMode=yes"]
        }

        arguments.append("\(config.username)@\(config.host)")
        if let remoteCommand {
            arguments.append(remoteCommand)
        }
        return arguments
    }

    static func environment(for config: ServerConnectionConfig) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"

        if config.authentication == .password, KeychainService.hasPassword(for: config.credentialID) {
            environment["SSH_ASKPASS"] = askPassHelperURL.path
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = environment["DISPLAY"] ?? ":0"
            environment["SERVERDASH_KEYCHAIN_SERVICE"] = KeychainService.serviceName
            environment["SERVERDASH_KEYCHAIN_ACCOUNT"] = config.credentialID.uuidString
        }
        return environment
    }

    private static let askPassHelperURL: URL = {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerDash", isDirectory: true)
        let file = directory.appendingPathComponent("serverdash-askpass")
        let script = """
        #!/bin/sh
        exec /usr/bin/security find-generic-password \
          -s "$SERVERDASH_KEYCHAIN_SERVICE" \
          -a "$SERVERDASH_KEYCHAIN_ACCOUNT" -w
        """
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try Data(script.utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        } catch {
            return URL(fileURLWithPath: "/usr/bin/false")
        }
        return file
    }()
}

struct SSHHostKeyProbe: Identifiable, Hashable, Sendable {
    let id = UUID()
    let host: String
    let port: Int
    let algorithm: String
    let fingerprint: String
    let keyLine: String
}

enum SSHValidationError: LocalizedError {
    case hostKeyUnavailable(String)
    case invalidHostKey
    case cannotSaveHostKey(String)

    var errorDescription: String? {
        switch self {
        case .hostKeyUnavailable(let detail):
            detail.isEmpty ? "无法获取服务器主机指纹，请检查地址和端口。" : detail
        case .invalidHostKey:
            "服务器返回了无效的 SSH 主机密钥。"
        case .cannotSaveHostKey(let detail):
            "无法保存 SSH 主机指纹：\(detail)"
        }
    }
}

enum SSHConnectionValidator {
    static func pendingHostKey(for config: ServerConnectionConfig) async throws -> SSHHostKeyProbe? {
        let knownHostsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/known_hosts")
        let lookupHost = config.port == 22 ? config.host : "[\(config.host)]:\(config.port)"

        return try await Task.detached(priority: .utility) {
            if FileManager.default.fileExists(atPath: knownHostsURL.path) {
                let lookup = run(
                    executable: "/usr/bin/ssh-keygen",
                    arguments: ["-F", lookupHost, "-f", knownHostsURL.path]
                )
                if lookup.status == 0, !lookup.output.isEmpty {
                    return nil
                }
            }

            let scan = run(
                executable: "/usr/bin/ssh-keyscan",
                arguments: ["-T", "8", "-p", String(config.port), config.host]
            )
            let validLines = scan.output
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .filter { line in
                    !line.hasPrefix("#") && line.split(separator: " ").count >= 3
                }

            guard !validLines.isEmpty else {
                let detail = scan.error.trimmingCharacters(in: .whitespacesAndNewlines)
                throw SSHValidationError.hostKeyUnavailable(detail)
            }

            let preferredLine = validLines.first {
                $0.split(separator: " ").dropFirst().first == "ssh-ed25519"
            } ?? validLines[0]
            let fields = preferredLine.split(separator: " ")
            guard fields.count >= 3,
                  let keyData = Data(base64Encoded: String(fields[2])) else {
                throw SSHValidationError.invalidHostKey
            }

            let digest = SHA256.hash(data: keyData)
            let fingerprint = Data(digest)
                .base64EncodedString()
                .replacingOccurrences(of: "=", with: "")

            return SSHHostKeyProbe(
                host: config.host,
                port: config.port,
                algorithm: displayName(for: String(fields[1])),
                fingerprint: "SHA256:\(fingerprint)",
                keyLine: preferredLine
            )
        }.value
    }

    static func trust(_ probe: SSHHostKeyProbe) async throws {
        let sshDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true)
        let knownHostsURL = sshDirectory.appendingPathComponent("known_hosts")

        try await Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(
                    at: sshDirectory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                var contents = (try? String(contentsOf: knownHostsURL, encoding: .utf8)) ?? ""
                if !contents.isEmpty && !contents.hasSuffix("\n") {
                    contents.append("\n")
                }
                if !contents.split(whereSeparator: \.isNewline).contains(Substring(probe.keyLine)) {
                    contents.append(probe.keyLine)
                    contents.append("\n")
                    try contents.write(to: knownHostsURL, atomically: true, encoding: .utf8)
                }
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: knownHostsURL.path
                )
            } catch {
                throw SSHValidationError.cannotSaveHostKey(error.localizedDescription)
            }
        }.value
    }

    private static func displayName(for algorithm: String) -> String {
        switch algorithm {
        case "ssh-ed25519": "ED25519"
        case "ecdsa-sha2-nistp256": "ECDSA"
        case "ssh-rsa": "RSA"
        default: algorithm
        }
    }

    private static func run(executable: String, arguments: [String]) -> (
        status: Int32,
        output: String,
        error: String
    ) {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (-1, "", error.localizedDescription)
        }
        return (
            process.terminationStatus,
            String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}

struct SSHKeyInspection: Sendable {
    let algorithm: String
    let fingerprint: String
}

enum SSHKeyInspectionError: LocalizedError {
    case invalidFile(String)

    var errorDescription: String? {
        switch self {
        case .invalidFile(let detail):
            detail.isEmpty ? "无法读取 SSH 密钥。" : detail
        }
    }
}

enum SSHKeyInspector {
    static func inspect(filePath: String) async throws -> SSHKeyInspection {
        let expandedPath = NSString(string: filePath).expandingTildeInPath
        return try await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: expandedPath) else {
                throw SSHKeyInspectionError.invalidFile("密钥文件不存在。")
            }

            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            process.arguments = ["-lf", expandedPath, "-E", "sha256"]
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                throw SSHKeyInspectionError.invalidFile(error.localizedDescription)
            }

            let output = String(
                decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let errorOutput = String(
                decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0 else {
                throw SSHKeyInspectionError.invalidFile(errorOutput)
            }

            let fields = output.split(separator: " ")
            guard fields.count >= 2 else {
                throw SSHKeyInspectionError.invalidFile("无法识别密钥指纹。")
            }
            let algorithm = fields.last
                .map(String.init)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "()")) ?? "SSH"
            return SSHKeyInspection(
                algorithm: algorithm,
                fingerprint: String(fields[1])
            )
        }.value
    }
}

enum MonitoringError: LocalizedError {
    case commandFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message):
            message.isEmpty ? "SSH 采集失败" : message
        case .invalidResponse:
            "服务器返回了无法识别的监控数据"
        }
    }
}

enum SSHMonitoringService {
    static let remoteCommand = #"""
    sh -lc '
    cpu_idle=$(LC_ALL=C top -bn1 2>/dev/null | awk "/Cpu\\(s\\)/ {for(i=1;i<=NF;i++) if(\$i ~ /id/) {gsub(/[^0-9.]/,\"\",\$i); print \$i; exit}}")
    [ -z "$cpu_idle" ] && cpu_idle=100
    cpu=$(awk -v idle="$cpu_idle" "BEGIN {printf \"%.2f\", 100-idle}")
    cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
    set -- $(cat /proc/loadavg 2>/dev/null || echo "0 0 0")
    load1=$1; load5=$2; load15=$3
    mem_total=$(awk "/MemTotal/ {print \$2}" /proc/meminfo 2>/dev/null)
    mem_available=$(awk "/MemAvailable/ {print \$2}" /proc/meminfo 2>/dev/null)
    swap_total=$(awk "/SwapTotal/ {print \$2}" /proc/meminfo 2>/dev/null)
    swap_free=$(awk "/SwapFree/ {print \$2}" /proc/meminfo 2>/dev/null)
    set -- $(df -B1 / 2>/dev/null | awk "NR==2 {print \$3, \$2}")
    disk_used=$1; disk_total=$2
    set -- $(awk -F"[: ]+" "NR>2 {rx+=\$3; tx+=\$11} END {print rx+0, tx+0}" /proc/net/dev 2>/dev/null)
    net_rx=$1; net_tx=$2
    uptime_text=$(uptime -p 2>/dev/null | sed "s/^up //" || true)
    distro=$(awk -F= "/^PRETTY_NAME=/ {gsub(/^\\\"|\\\"$/,\"\",\$2); print \$2}" /etc/os-release 2>/dev/null)
    kernel=$(uname -sr 2>/dev/null)
    users=$(who 2>/dev/null | wc -l | tr -d " ")
    processes=$(ps -e --no-headers 2>/dev/null | wc -l | tr -d " ")
    printf "cpu=%s\ncores=%s\nload1=%s\nload5=%s\nload15=%s\n" "$cpu" "$cores" "$load1" "$load5" "$load15"
    printf "mem_total_kb=%s\nmem_available_kb=%s\nswap_total_kb=%s\nswap_free_kb=%s\n" "$mem_total" "$mem_available" "$swap_total" "$swap_free"
    printf "disk_used=%s\ndisk_total=%s\nnet_rx=%s\nnet_tx=%s\n" "$disk_used" "$disk_total" "$net_rx" "$net_tx"
    printf "uptime=%s\ndistro=%s\nkernel=%s\nusers=%s\nprocesses=%s\n" "$uptime_text" "$distro" "$kernel" "$users" "$processes"
    ps -eo pid=,comm=,%cpu=,%mem= --sort=-%cpu 2>/dev/null | awk "NR<=5 {printf \"proc=%s|%s|%s|%s\\n\", \$1, \$2, \$3, \$4}"
    '
    """#

    static func collect(_ config: ServerConnectionConfig) async throws -> ServerSnapshot {
        let arguments = SSHSupport.arguments(
            for: config,
            strictHostChecking: "yes",
            batchMode: config.authentication == .privateKey,
            remoteCommand: remoteCommand
        )
        let environment = SSHSupport.environment(for: config)

        return try await Task.detached(priority: .utility) {
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = arguments
            process.environment = environment
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            do {
                try process.run()
            } catch {
                throw MonitoringError.commandFailed(error.localizedDescription)
            }

            process.waitUntilExit()
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(decoding: outputData, as: UTF8.self)
            let errorOutput = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard process.terminationStatus == 0 else {
                throw MonitoringError.commandFailed(errorOutput)
            }
            return try MonitoringResponseParser.parse(output)
        }.value
    }
}

enum MonitoringResponseParser {
    static func parse(_ output: String) throws -> ServerSnapshot {
        var values: [String: String] = [:]
        var processes: [ProcessMetric] = []

        for line in output.split(whereSeparator: \.isNewline) {
            let text = String(line)
            guard let separator = text.firstIndex(of: "=") else { continue }
            let key = String(text[..<separator])
            let value = String(text[text.index(after: separator)...])
            if key == "proc" {
                let fields = value.split(separator: "|", omittingEmptySubsequences: false)
                if fields.count == 4 {
                    processes.append(
                        ProcessMetric(
                            name: String(fields[1]),
                            pid: Int(fields[0]) ?? 0,
                            cpu: Double(fields[2]) ?? 0,
                            memory: Double(fields[3]) ?? 0
                        )
                    )
                }
            } else {
                values[key] = value
            }
        }

        guard values["cpu"] != nil, values["mem_total_kb"] != nil else {
            throw MonitoringError.invalidResponse
        }

        let memoryTotal = number(values["mem_total_kb"]) * 1024
        let memoryAvailable = number(values["mem_available_kb"]) * 1024
        let swapTotal = number(values["swap_total_kb"]) * 1024
        let swapFree = number(values["swap_free_kb"]) * 1024

        return ServerSnapshot(
            capturedAt: .now,
            cpuUsage: number(values["cpu"]),
            coreCount: integer(values["cores"]),
            load1: number(values["load1"]),
            load5: number(values["load5"]),
            load15: number(values["load15"]),
            memoryUsedBytes: max(0, memoryTotal - memoryAvailable),
            memoryTotalBytes: memoryTotal,
            swapUsedBytes: max(0, swapTotal - swapFree),
            swapTotalBytes: swapTotal,
            diskUsedBytes: number(values["disk_used"]),
            diskTotalBytes: number(values["disk_total"]),
            networkReceivedBytes: number(values["net_rx"]),
            networkSentBytes: number(values["net_tx"]),
            downloadBytesPerSecond: 0,
            uploadBytesPerSecond: 0,
            uptime: values["uptime"] ?? "—",
            distribution: values["distro"] ?? "Linux",
            kernel: values["kernel"] ?? "—",
            loggedInUsers: integer(values["users"]),
            processCount: integer(values["processes"]),
            topProcesses: processes
        )
    }

    private static func number(_ value: String?) -> Double {
        Double(value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    }

    private static func integer(_ value: String?) -> Int {
        Int(value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    }
}
