import CryptoKit
import Foundation
import LocalAuthentication
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
        try deleteSecret(account: credentialID.uuidString)
    }

    static func saveSecret(_ value: String, account: String) throws {
        let data = Data(value.utf8)
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

    static func secret(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
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
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        return value
    }

    static func deleteSecret(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    static func passphraseAccount(for keyID: UUID) -> String {
        "passphrase.\(keyID.uuidString)"
    }

    static func importedKeyAccount(for keyID: UUID) -> String {
        "imported-key.\(keyID.uuidString)"
    }

    static func proxyAccount(for routeID: UUID, revision: UUID) -> String {
        "proxy.\(routeID.uuidString).\(revision.uuidString)"
    }
}

enum KeyMaterialStore {
    static func materializePrivateKey(for config: ServerConnectionConfig) throws -> String? {
        if config.usesImportedKey, let keyID = config.sshKeyID,
           let pem = try KeychainService.secret(account: KeychainService.importedKeyAccount(for: keyID)) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ServerDash/keys", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let file = directory.appendingPathComponent(keyID.uuidString)
            try Data(pem.utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return file.path
        }
        if !config.privateKeyPath.isEmpty {
            return NSString(string: config.privateKeyPath).expandingTildeInPath
        }
        return nil
    }

    static func cleanupTemporaryKey(for config: ServerConnectionConfig) {
        guard config.usesImportedKey, let keyID = config.sshKeyID else { return }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerDash/keys/\(keyID.uuidString)")
        try? FileManager.default.removeItem(at: file)
    }

    static func cleanupAll() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerDash/keys", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
    }
}

enum SSHSupport {
    static var userKnownHostsOption: String {
        "UserKnownHostsFile=\(quotedConfigurationValue(TrustedHostStore.knownHostsURL.path))"
    }

    static func quotedConfigurationValue(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Compatibility helper for previews/tests. Production connection entry points use
    /// `ConnectionProvider.launchPlan` so executable, arguments and environment stay atomic.
    /// A credential error returns a fail-closed identity configuration and never lets OpenSSH
    /// try ssh-agent or default key files.
    static func arguments(
        for config: ServerConnectionConfig,
        strictHostChecking: String,
        batchMode: Bool = false,
        remoteCommand: String? = nil
    ) -> [String] {
        (try? directArguments(
            for: config,
            strictHostChecking: strictHostChecking,
            batchMode: batchMode,
            remoteCommand: remoteCommand
        )) ?? failClosedArguments(
            for: config,
            strictHostChecking: strictHostChecking,
            batchMode: batchMode,
            remoteCommand: remoteCommand
        )
    }

    static func directArguments(
        for config: ServerConnectionConfig,
        strictHostChecking: String,
        batchMode: Bool = false,
        remoteCommand: String? = nil
    ) throws -> [String] {
        var arguments = [
            "-p", String(config.port),
            "-o", "ConnectTimeout=\(Int(config.connectTimeout))",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=\(strictHostChecking)",
            "-o", userKnownHostsOption,
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "UpdateHostKeys=no"
        ]

        let keyPath = try explicitKeyPath(for: config)
        switch config.authentication {
        case .privateKey:
            guard let keyPath else {
                throw ConnectionRouteError.credentialUnavailable(
                    hopID: config.id,
                    reason: "目标私钥缺失"
                )
            }
            arguments += ["-i", keyPath, "-o", "IdentitiesOnly=yes"]
        case .password:
            arguments += ["-o", "PreferredAuthentications=password,keyboard-interactive"]
            arguments += ["-o", "PubkeyAuthentication=no"]
        case .keyThenPassword:
            if let keyPath {
                arguments += ["-i", keyPath, "-o", "IdentitiesOnly=yes"]
            } else {
                // Do not silently fall back to unrelated ssh-agent or default-file identities.
                arguments += ["-o", "PubkeyAuthentication=no"]
            }
            arguments += ["-o", "PreferredAuthentications=publickey,password"]
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

    static func directArgumentsForSFTP(config: ServerConnectionConfig) throws -> [String] {
        var arguments = [
            "-q",
            "-P", String(config.port),
            "-o", "ConnectTimeout=\(Int(config.connectTimeout))",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=yes",
            "-o", userKnownHostsOption,
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "UpdateHostKeys=no"
        ]
        let keyPath = try explicitKeyPath(for: config)
        switch config.authentication {
        case .privateKey:
            guard let keyPath else {
                throw ConnectionRouteError.credentialUnavailable(
                    hopID: config.id,
                    reason: "目标私钥缺失"
                )
            }
            arguments += ["-i", keyPath, "-o", "IdentitiesOnly=yes"]
        case .password:
            arguments += [
                "-o", "PreferredAuthentications=password,keyboard-interactive",
                "-o", "PubkeyAuthentication=no"
            ]
        case .keyThenPassword:
            if let keyPath {
                arguments += ["-i", keyPath, "-o", "IdentitiesOnly=yes"]
            } else {
                arguments += ["-o", "PubkeyAuthentication=no"]
            }
            arguments += ["-o", "PreferredAuthentications=publickey,password"]
        }
        arguments.append("\(config.username)@\(config.host)")
        return arguments
    }

    private static func explicitKeyPath(for config: ServerConnectionConfig) throws -> String? {
        let path: String?
        do {
            path = try KeyMaterialStore.materializePrivateKey(for: config)
        } catch {
            throw ConnectionRouteError.credentialUnavailable(
                hopID: config.id,
                reason: "私钥读取失败"
            )
        }
        guard let path, !path.isEmpty else { return nil }
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw ConnectionRouteError.credentialUnavailable(
                hopID: config.id,
                reason: "私钥文件不可读"
            )
        }
        return path
    }

    private static func failClosedArguments(
        for config: ServerConnectionConfig,
        strictHostChecking: String,
        batchMode: Bool,
        remoteCommand: String?
    ) -> [String] {
        var arguments = [
            "-p", String(config.port),
            "-o", "ConnectTimeout=\(Int(config.connectTimeout))",
            "-o", "StrictHostKeyChecking=\(strictHostChecking)",
            "-o", userKnownHostsOption,
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "UpdateHostKeys=no",
            "-o", "IdentitiesOnly=yes",
            "-o", "IdentityAgent=none",
            "-o", "PubkeyAuthentication=no",
            "-o", "PasswordAuthentication=no",
            "-o", "KbdInteractiveAuthentication=no"
        ]
        if batchMode { arguments += ["-o", "BatchMode=yes"] }
        arguments.append("\(config.username)@\(config.host)")
        if let remoteCommand { arguments.append(remoteCommand) }
        return arguments
    }

    static func environment(for config: ServerConnectionConfig) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        if PrivacySettings.disableLocationLookup {
            environment["SERVERDASH_DISABLE_GEO"] = "1"
        }

        let needsAskPass =
            (config.authentication.usesPassword && KeychainService.hasPassword(for: config.credentialID)) ||
            (config.hasPassphrase && config.sshKeyID != nil)
        if needsAskPass {
            environment["SSH_ASKPASS"] = askPassHelperURL.path
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = environment["DISPLAY"] ?? ":0"
            environment["SERVERDASH_KEYCHAIN_SERVICE"] = KeychainService.serviceName
            if config.hasPassphrase, let keyID = config.sshKeyID,
               !KeychainService.hasPassword(for: config.credentialID) {
                environment["SERVERDASH_KEYCHAIN_ACCOUNT"] = KeychainService.passphraseAccount(for: keyID)
            } else {
                environment["SERVERDASH_KEYCHAIN_ACCOUNT"] = config.credentialID.uuidString
            }
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
    var additionalKeyLines: [String] = []
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
        switch try await TrustedHostStore.inspect(config) {
        case .trusted:
            return nil
        case .unknown(let probe):
            return probe
        case .changed(_, let probe):
            return probe
        }
    }

    static func inspect(
        _ config: ServerConnectionConfig,
        forceScan: Bool = false
    ) async throws -> HostTrustDecision {
        try await TrustedHostStore.inspect(config, forceScan: forceScan)
    }

    static func trust(_ probe: SSHHostKeyProbe, replacing: Bool = false) async throws {
        try await Task.detached(priority: .utility) {
            do {
                try TrustedHostStore.trust(probe, replacing: replacing)
            } catch {
                throw SSHValidationError.cannotSaveHostKey(error.localizedDescription)
            }
        }.value
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

    static func publicKey(filePath: String) async throws -> String {
        let expandedPath = NSString(string: filePath).expandingTildeInPath
        return try await Task.detached(priority: .utility) {
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            process.arguments = ["-y", "-f", expandedPath]
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            try process.run()
            process.waitUntilExit()
            let output = String(
                decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0, !output.isEmpty else {
                throw SSHKeyInspectionError.invalidFile("无法导出公钥。")
            }
            return output
        }.value
    }
}

enum LocalAuth {
    static func authenticate(reason: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let context = LAContext()
            var error: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
                continuation.resume(returning: true)
                return
            }
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}

enum MonitoringError: LocalizedError {
    case commandFailed(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message):
            message.isEmpty ? "SSH 采集失败" : message
        case .invalidResponse(let detail):
            detail.isEmpty
                ? "服务器返回了无法识别的监控数据"
                : "服务器返回了无法识别的监控数据：\(detail)"
        }
    }
}

enum SSHMonitoringService {
    static let remoteCommand = #"""
    sh -lc '
    sample_base="/tmp/serverdash-sample-$$"
    cpu_a="${sample_base}.cpu.a"
    cpu_b="${sample_base}.cpu.b"
    disk_a="${sample_base}.disk.a"
    disk_b="${sample_base}.disk.b"
    grep "^cpu" /proc/stat 2>/dev/null > "$cpu_a"
    cat /proc/diskstats 2>/dev/null > "$disk_a"
    sleep 0.25
    grep "^cpu" /proc/stat 2>/dev/null > "$cpu_b"
    cat /proc/diskstats 2>/dev/null > "$disk_b"
    cpu_metrics=$(awk "NR==FNR {u[\$1]=\$2; n[\$1]=\$3; s[\$1]=\$4; i[\$1]=\$5; w[\$1]=\$6; q[\$1]=\$7; z[\$1]=\$8; t[\$1]=\$9; next} {k=\$1; du=\$2-u[k]; dn=\$3-n[k]; ds=\$4-s[k]; di=\$5-i[k]; dw=\$6-w[k]; dq=\$7-q[k]; dz=\$8-z[k]; dt=\$9-t[k]; total=du+dn+ds+di+dw+dq+dz+dt; if(total<=0) next; user_pct=du*100/total; nice_pct=dn*100/total; system_pct=(ds+dq+dz)*100/total; wait_pct=dw*100/total; steal_pct=dt*100/total; if(k==\"cpu\") printf \"cpu=%.2f\\n\", 100-(di*100/total); else if(k ~ /^cpu[0-9]+$/) printf \"core=%s|%.2f|%.2f|%.2f|%.2f|%.2f\\n\", substr(k,4), user_pct, system_pct, nice_pct, wait_pct, steal_pct}" "$cpu_a" "$cpu_b")
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
    awk -F"[: ]+" "NR>2 {name=\$2; rx=\$3; tx=\$11; if(name !~ /^(lo|docker|veth|br-|virbr|tun|tap|tailscale|zt)/) {printf \"iface=%s|%.0f|%.0f\\n\", name, rx, tx; score=rx+tx; if(score>max){max=score; active=name; arx=rx; atx=tx}}} END {printf \"active_iface=%s\\nnet_rx=%.0f\\nnet_tx=%.0f\\n\", active, arx+0, atx+0}" /proc/net/dev 2>/dev/null
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
    uid=$(id -u 2>/dev/null || echo 0)
    slow_cache="/tmp/serverdash-monitor-${uid}.cache"
    now=$(date +%s)
    cache_time=$(stat -c %Y "$slow_cache" 2>/dev/null || echo 0)
    cache_age=$((now-cache_time))
    if [ ! -s "$slow_cache" ] || [ "$cache_age" -gt 15 ]; then
      slow_tmp="${slow_cache}.$$"
      {
        df -B1 -PT 2>/dev/null | awk "NR>1 {dev=\$1; type=\$2; total=\$3; used=\$4; mount=\$7; for(i=8;i<=NF;i++) mount=mount \" \" \$i; if(type !~ /^(tmpfs|devtmpfs|overlay|squashfs|proc|sysfs|cgroup|cgroup2|tracefs|debugfs|securityfs|pstore|efivarfs|mqueue|hugetlbfs|fusectl)$/ && dev !~ /^\\/dev\\/loop/) {gsub(/[|]/,\"/\",dev); gsub(/[|]/,\"/\",mount); printf \"fs=%s|%s|%.0f|%.0f|%s\\n\", dev, type, used, total, mount}}"
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
        geo_cache="/tmp/serverdash-geo-${uid}.json"
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
    """#

    static let fallbackRemoteCommand = #"""
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
    """#

    static func probeCapabilities(_ config: ServerConnectionConfig) async throws -> ServerCapabilities {
        let command = #"""
        sh -lc '
        printf "os=%s\n" "$(uname -s 2>/dev/null)"
        printf "distro=%s\n" "$(awk -F= "/^ID=/ {gsub(/\"/,\"\",\$2); print \$2}" /etc/os-release 2>/dev/null)"
        command -v docker >/dev/null 2>&1 && echo docker=1 || echo docker=0
        command -v nvidia-smi >/dev/null 2>&1 && echo gpu=1 || echo gpu=0
        command -v vnstat >/dev/null 2>&1 && echo vnstat=1 || echo vnstat=0
        [ -r /proc/stat ] && echo proc=1 || echo proc=0
        df --version >/dev/null 2>&1 && echo gnu=1 || echo gnu=0
        '
        """#
        let output = try await run(config, command: command)
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let text = String(line)
            guard let separator = text.firstIndex(of: "=") else { continue }
            values[String(text[..<separator])] = String(text[text.index(after: separator)...])
        }
        let distro = values["distro"] ?? ""
        let limited = distro == "alpine" || (values["gnu"] != "1")
        return ServerCapabilities(
            platform: (values["os"] ?? "Linux").lowercased(),
            family: distro,
            gnuCoreutils: values["gnu"] == "1",
            hasProc: values["proc"] == "1",
            hasDocker: values["docker"] == "1",
            hasGPU: values["gpu"] == "1",
            hasVnStat: values["vnstat"] == "1",
            limitedSupport: limited
        )
    }

    static func collect(_ config: ServerConnectionConfig) async throws -> ServerSnapshot {
        let interval = PerformanceTrace.begin(.monitorCollect)
        defer { PerformanceTrace.end(interval) }
        if await MonitoringCompatibilityRegistry.shared.requiresFallback(for: config.id) {
            let output = try await run(config, command: fallbackRemoteCommand)
            return try MonitoringResponseParser.parse(output)
        }

        do {
            let output = try await run(config, command: remoteCommand)
            return try MonitoringResponseParser.parse(output)
        } catch MonitoringError.invalidResponse {
            await MonitoringCompatibilityRegistry.shared.markFallbackRequired(for: config.id)
            let output = try await run(config, command: fallbackRemoteCommand)
            return try MonitoringResponseParser.parse(output)
        }
    }

    private static func run(
        _ config: ServerConnectionConfig,
        command: String
    ) async throws -> String {
        let interval = PerformanceTrace.begin(.sshRemoteCommand)
        defer { PerformanceTrace.end(interval) }
        let plan = try SystemOpenSSHConnectionProvider().launchPlan(
            for: config,
            purpose: .remoteCommand(command)
        )
        let result = try await ConnectionProcessController.shared.run(
            ProcessRunRequest(
                executable: plan.executable,
                arguments: plan.arguments,
                environment: plan.environment,
                connectTimeout: config.connectTimeout,
                totalTimeout: 60,
                maxOutputBytes: 512_000,
                serverID: config.id,
                module: .monitoring,
                host: config.host,
                port: config.port
            )
        )
        return result.output
    }
}

private actor MonitoringCompatibilityRegistry {
    static let shared = MonitoringCompatibilityRegistry()

    private var fallbackServerIDs: Set<UUID> = []

    func requiresFallback(for serverID: UUID) -> Bool {
        fallbackServerIDs.contains(serverID)
    }

    func markFallbackRequired(for serverID: UUID) {
        fallbackServerIDs.insert(serverID)
    }
}

enum MonitoringResponseParser {
    static func parse(_ output: String) throws -> ServerSnapshot {
        let interval = PerformanceTrace.begin(.monitorParse)
        defer { PerformanceTrace.end(interval) }
        var values: [String: String] = [:]
        var processes: [ProcessMetric] = []
        var cores: [CPUCoreMetric] = []
        var interfaces: [NetworkInterfaceMetric] = []
        var filesystems: [FilesystemMetric] = []
        var diskIO: [DiskIOMetric] = []
        var gpus: [GPUMetric] = []
        var gpuProcesses: [GPUProcessMetric] = []
        var dockerContainers: [DockerContainerMetric] = []

        for line in output.split(whereSeparator: \.isNewline) {
            let text = String(line)
            guard let separator = text.firstIndex(of: "=") else { continue }
            let key = String(text[..<separator])
            let value = String(text[text.index(after: separator)...])
            switch key {
            case "proc":
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
                } else if fields.count >= 7 {
                    processes.append(
                        ProcessMetric(
                            name: String(fields[2]),
                            pid: Int(fields[0]) ?? 0,
                            cpu: Double(fields[3]) ?? 0,
                            memory: Double(fields[4]) ?? 0,
                            user: String(fields[1]),
                            arguments: fields.dropFirst(6).map(String.init).joined(separator: "|"),
                            threadCount: Int(fields[5]) ?? 0
                        )
                    )
                }
            case "core":
                let fields = value.split(separator: "|", omittingEmptySubsequences: false)
                if fields.count == 6 {
                    cores.append(
                        CPUCoreMetric(
                            index: Int(fields[0]) ?? 0,
                            user: Double(fields[1]) ?? 0,
                            system: Double(fields[2]) ?? 0,
                            nice: Double(fields[3]) ?? 0,
                            ioWait: Double(fields[4]) ?? 0,
                            steal: Double(fields[5]) ?? 0
                        )
                    )
                }
            case "iface":
                let fields = value.split(separator: "|", omittingEmptySubsequences: false)
                if fields.count == 3 {
                    interfaces.append(
                        NetworkInterfaceMetric(
                            name: String(fields[0]),
                            receivedBytes: Double(fields[1]) ?? 0,
                            sentBytes: Double(fields[2]) ?? 0
                        )
                    )
                }
            case "fs":
                let fields = value.split(separator: "|", omittingEmptySubsequences: false)
                if fields.count >= 5 {
                    filesystems.append(
                        FilesystemMetric(
                            device: String(fields[0]),
                            mountPoint: fields.dropFirst(4).map(String.init).joined(separator: "|"),
                            filesystemType: String(fields[1]),
                            usedBytes: Double(fields[2]) ?? 0,
                            totalBytes: Double(fields[3]) ?? 0
                        )
                    )
                }
            case "diskio":
                let fields = value.split(separator: "|", omittingEmptySubsequences: false)
                if fields.count == 9 {
                    diskIO.append(
                        DiskIOMetric(
                            device: String(fields[0]),
                            readBytesPerSecond: Double(fields[1]) ?? 0,
                            writeBytesPerSecond: Double(fields[2]) ?? 0,
                            readIOPS: Double(fields[3]) ?? 0,
                            writeIOPS: Double(fields[4]) ?? 0,
                            readLatencyMilliseconds: Double(fields[5]) ?? 0,
                            writeLatencyMilliseconds: Double(fields[6]) ?? 0,
                            lifetimeReadBytes: Double(fields[7]) ?? 0,
                            lifetimeWriteBytes: Double(fields[8]) ?? 0
                        )
                    )
                }
            case "gpu":
                let fields = value.split(separator: "|", omittingEmptySubsequences: false)
                if fields.count == 10 {
                    gpus.append(
                        GPUMetric(
                            index: Int(fields[0]) ?? 0,
                            uuid: String(fields[1]),
                            name: String(fields[2]),
                            utilization: Double(fields[3]) ?? 0,
                            memoryUsedBytes: (Double(fields[4]) ?? 0) * 1_048_576,
                            memoryTotalBytes: (Double(fields[5]) ?? 0) * 1_048_576,
                            fanPercent: optionalNumber(fields[6]),
                            temperatureCelsius: optionalNumber(fields[7]),
                            powerWatts: optionalNumber(fields[8]),
                            powerLimitWatts: optionalNumber(fields[9])
                        )
                    )
                }
            case "gproc":
                let fields = value.split(separator: "|", omittingEmptySubsequences: false)
                if fields.count == 4 {
                    gpuProcesses.append(
                        GPUProcessMetric(
                            gpuID: String(fields[0]),
                            pid: Int(fields[1]) ?? 0,
                            name: String(fields[2]),
                            memoryBytes: (Double(fields[3]) ?? 0) * 1_048_576
                        )
                    )
                }
            case "dcont":
                let fields = value.split(separator: "|", omittingEmptySubsequences: false)
                if fields.count >= 5 {
                    dockerContainers.append(
                        DockerContainerMetric(
                            id: String(fields[0]),
                            name: String(fields[1]),
                            image: String(fields[2]),
                            state: String(fields[3]),
                            status: fields.dropFirst(4).map(String.init).joined(separator: "|")
                        )
                    )
                }
            default:
                values[key] = value
            }
        }

        guard values["mem_total_kb"] != nil else {
            let preview = output
                .prefix(320)
                .replacingOccurrences(of: "\n", with: " ↵ ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw MonitoringError.invalidResponse(
                preview.isEmpty ? "SSH 命令没有返回数据" : "原始输出：\(preview)"
            )
        }

        let memoryTotal = number(values["mem_total_kb"]) * 1024
        let memoryAvailable = number(values["mem_available_kb"]) * 1024
        let memoryFree = number(values["mem_free_kb"]) * 1024
        let memoryCached = number(values["mem_cached_kb"]) * 1024
        let memoryBuffers = number(values["mem_buffers_kb"]) * 1024
        let swapTotal = number(values["swap_total_kb"]) * 1024
        let swapFree = number(values["swap_free_kb"]) * 1024
        let hasDetailedMemory = memoryFree + memoryCached + memoryBuffers > 0
        let memoryUsed = hasDetailedMemory
            ? max(0, memoryTotal - memoryFree - memoryCached - memoryBuffers)
            : max(0, memoryTotal - memoryAvailable)
        let activeInterface = values["active_iface"] ?? ""
        interfaces = interfaces.map { item in
            var updated = item
            updated.isActive = item.name == activeInterface
            return updated
        }
        let vnStatHistory = VnStatPayloadParser.parse(values["vnstat_json"])
        let vnStatAvailable = boolean(values["vnstat_available"])

        return ServerSnapshot(
            capturedAt: .now,
            cpuUsage: number(values["cpu"]),
            coreCount: integer(values["cores"]),
            load1: number(values["load1"]),
            load5: number(values["load5"]),
            load15: number(values["load15"]),
            memoryUsedBytes: memoryUsed,
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
            topProcesses: Array(processes.prefix(8)),
            cpuModel: values["cpu_model"] ?? "",
            cpuTemperatureCelsius: optionalNumber(values["cpu_temp"]),
            cpuCores: cores.sorted { $0.index < $1.index },
            memoryCachedBytes: memoryCached + memoryBuffers,
            memoryFreeBytes: hasDetailedMemory ? memoryFree : memoryAvailable,
            memoryBuffersBytes: memoryBuffers,
            activeNetworkInterface: activeInterface,
            networkInterfaces: interfaces,
            filesystems: filesystems,
            diskIO: diskIO,
            processes: processes,
            vnStatAvailable: vnStatAvailable,
            vnStatCollecting: vnStatAvailable && vnStatHistory.isEmpty,
            vnStatSource: values["vnstat_source"] ?? "",
            vnStatHistory: vnStatHistory,
            gpuDriverVersion: values["gpu_driver"] ?? "",
            cudaVersion: values["cuda_version"] ?? "",
            gpus: gpus,
            gpuProcesses: gpuProcesses,
            dockerAvailable: boolean(values["docker_available"]),
            dockerVersion: values["docker_version"] ?? "",
            dockerContainers: dockerContainers,
            geoLocation: GeoPayloadParser.parse(values["geo_json"])
        )
    }

    private static func number(_ value: String?) -> Double {
        Double(value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    }

    private static func integer(_ value: String?) -> Int {
        Int(value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    }

    private static func boolean(_ value: String?) -> Bool {
        value == "1" || value?.lowercased() == "true"
    }

    private static func optionalNumber<S: StringProtocol>(_ value: S?) -> Double? {
        guard let value else { return nil }
        let text = String(value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard
              !text.isEmpty,
              text.lowercased() != "n/a",
              let number = Double(text) else {
            return nil
        }
        return number
    }
}

enum VnStatPayloadParser {
    static func parse(_ base64: String?) -> [VnStatTrafficPoint] {
        guard let base64,
              let data = Data(base64Encoded: base64),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let interfaces = root["interfaces"] as? [[String: Any]],
              let firstInterface = interfaces.first,
              let traffic = firstInterface["traffic"] as? [String: Any] else {
            return []
        }

        var points: [VnStatTrafficPoint] = []
        points += parseEntries(traffic["hour"], period: .hourly)
        let daily = parseEntries(traffic["day"], period: .daily)
        points += daily
        points += aggregateWeeks(daily)
        points += parseEntries(traffic["month"], period: .monthly)
        points += parseEntries(traffic["year"], period: .yearly)
        return points.sorted { $0.timestamp < $1.timestamp }
    }

    private static func parseEntries(
        _ value: Any?,
        period: VnStatPeriod
    ) -> [VnStatTrafficPoint] {
        guard let entries = value as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let rx = numeric(entry["rx"]),
                  let tx = numeric(entry["tx"]),
                  let timestamp = timestamp(for: entry) else {
                return nil
            }
            return VnStatTrafficPoint(
                period: period,
                timestamp: timestamp,
                receivedBytes: rx,
                sentBytes: tx
            )
        }
    }

    private static func timestamp(for entry: [String: Any]) -> TimeInterval? {
        if let timestamp = numeric(entry["timestamp"]) {
            return timestamp
        }
        guard let date = entry["date"] as? [String: Any],
              let year = integer(date["year"]) else {
            return nil
        }
        let time = entry["time"] as? [String: Any]
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = integer(date["month"]) ?? 1
        components.day = integer(date["day"]) ?? 1
        components.hour = integer(time?["hour"]) ?? 0
        components.minute = integer(time?["minute"]) ?? 0
        return components.date?.timeIntervalSince1970
    }

    private static func aggregateWeeks(
        _ daily: [VnStatTrafficPoint]
    ) -> [VnStatTrafficPoint] {
        let calendar = Calendar(identifier: .iso8601)
        let groups = Dictionary(grouping: daily) { point -> DateComponents in
            calendar.dateComponents(
                [.yearForWeekOfYear, .weekOfYear],
                from: point.date
            )
        }
        return groups.values.compactMap { group in
            guard let first = group.min(by: { $0.timestamp < $1.timestamp }) else { return nil }
            return VnStatTrafficPoint(
                period: .weekly,
                timestamp: first.timestamp,
                receivedBytes: group.reduce(0) { $0 + $1.receivedBytes },
                sentBytes: group.reduce(0) { $0 + $1.sentBytes }
            )
        }
    }

    private static func numeric(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        numeric(value).map(Int.init)
    }
}

enum GeoPayloadParser {
    static func parse(_ base64: String?) -> ServerGeoLocation? {
        guard let base64,
              let data = Data(base64Encoded: base64),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ip = payload["ip"] as? String else {
            return nil
        }
        let coordinates = (payload["loc"] as? String)?
            .split(separator: ",")
            .compactMap { Double($0) }
        return ServerGeoLocation(
            publicIP: ip,
            city: payload["city"] as? String ?? "",
            region: payload["region"] as? String ?? "",
            country: payload["country"] as? String ?? "",
            organization: payload["org"] as? String ?? "",
            latitude: coordinates?.count == 2 ? coordinates?[0] : nil,
            longitude: coordinates?.count == 2 ? coordinates?[1] : nil
        )
    }
}
