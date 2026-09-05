import Darwin
import Foundation
import SwiftData

enum ConnectionCapability: String, CaseIterable, Codable, Sendable {
    case interactiveShell
    case remoteCommand
    case fileTransfer
    case localForward
    case remoteForward
    case dynamicForward
    case jumpHosts
    case socks5Proxy
    case httpConnectProxy
}

enum ConnectionPurpose: Sendable, Equatable {
    case interactiveShell
    case remoteCommand(String)
    case fileTransfer
    case portForward(PortForwardRule)
}

protocol InteractiveShellSession: Sendable {
    var id: UUID { get }
    func cancel() async
}

protocol RemoteCommandSession: Sendable {
    var id: UUID { get }
    func cancel() async
}

protocol FileTransferSession: Sendable {
    var id: UUID { get }
    func cancel() async
}

#if os(macOS)
protocol PortForwardSession: Sendable {
    var id: UUID { get }
    func snapshot() async -> PortForwardSnapshot
    func stop() async throws
}
#endif

protocol HostKeyVerifier: Sendable {
    func verify(
        _ endpoint: ConnectionEndpoint,
        serverID: UUID,
        source: HostTrustSource,
        forceScan: Bool
    ) async throws
}

protocol CredentialProvider: Sendable {
    func resolve(
        _ reference: CredentialReference,
        hopID: UUID
    ) throws -> ResolvedCredential
}

protocol ConnectionProvider: Sendable {
    var capabilities: Set<ConnectionCapability> { get }

    func launchPlan(
        for config: ServerConnectionConfig,
        purpose: ConnectionPurpose
    ) throws -> OpenSSHLaunchPlan
}

struct ConnectionEndpoint: Hashable, Codable, Sendable {
    var host: String
    var port: Int
    var username: String

    var normalizedKey: String {
        "\(host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()):\(port)"
    }

    func validated(label: String) throws -> ConnectionEndpoint {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, !trimmedUser.isEmpty, (1...65_535).contains(port) else {
            throw ConnectionRouteError.invalidEndpoint(label)
        }
        guard !trimmedHost.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespaces.contains($0)
        }), !trimmedUser.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespaces.contains($0)
        }) else {
            throw ConnectionRouteError.invalidEndpoint(label)
        }
        return ConnectionEndpoint(host: trimmedHost, port: port, username: trimmedUser)
    }
}

enum CredentialReference: Hashable, Codable, Sendable {
    case sshAgent
    case externalPrivateKey(path: String)
    case importedPrivateKey(keyID: UUID, hasPassphrase: Bool)
    case password(accountID: UUID)
}

struct ConnectionHop: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var name: String
    var endpoint: ConnectionEndpoint
    var credential: CredentialReference
    var connectTimeout: TimeInterval

    init(
        id: UUID = UUID(),
        name: String,
        endpoint: ConnectionEndpoint,
        credential: CredentialReference,
        connectTimeout: TimeInterval = 8
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.credential = credential
        self.connectTimeout = max(1, connectTimeout)
    }
}

enum NetworkProxyKind: String, CaseIterable, Codable, Sendable {
    case socks5
    case httpConnect

    var netcatValue: String {
        switch self {
        case .socks5: "5"
        case .httpConnect: "connect"
        }
    }
}

struct NetworkProxy: Hashable, Codable, Sendable {
    var kind: NetworkProxyKind
    var host: String
    var port: Int
    var username: String?
    /// The Keychain account reference only. The secret itself is never serialized here.
    var secretAccount: String?
}

struct ConnectionRoute: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var revision: UUID
    var name: String
    var hops: [ConnectionHop]
    var proxy: NetworkProxy?
    var importedProxyCommand: String?
    var importedProxyCommandConfirmed: Bool

    init(
        id: UUID = UUID(),
        revision: UUID = UUID(),
        name: String,
        hops: [ConnectionHop] = [],
        proxy: NetworkProxy? = nil,
        importedProxyCommand: String? = nil,
        importedProxyCommandConfirmed: Bool = false
    ) {
        self.id = id
        self.revision = revision
        self.name = name
        self.hops = hops
        self.proxy = proxy
        self.importedProxyCommand = importedProxyCommand
        self.importedProxyCommandConfirmed = importedProxyCommandConfirmed
    }

    static let direct = ConnectionRoute(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
        revision: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "直接连接"
    )

    var isDirect: Bool {
        hops.isEmpty && proxy == nil && importedProxyCommand == nil
    }

    func validated(finalEndpoint: ConnectionEndpoint) throws -> ConnectionRoute {
        let final = try finalEndpoint.validated(label: "目标服务器")
        guard hops.count <= 8 else {
            throw ConnectionRouteError.tooManyHops(hops.count)
        }
        var visited = Set<String>()
        for (index, hop) in hops.enumerated() {
            let endpoint = try hop.endpoint.validated(label: "第 \(index + 1) 跳")
            guard visited.insert(endpoint.normalizedKey).inserted else {
                throw ConnectionRouteError.routeLoop(endpoint.normalizedKey)
            }
        }
        guard visited.insert(final.normalizedKey).inserted else {
            throw ConnectionRouteError.routeLoop(final.normalizedKey)
        }
        if let proxy {
            let host = proxy.host.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty, (1...65_535).contains(proxy.port),
                  !host.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0) ||
                          CharacterSet.whitespaces.contains($0)
                  }) else {
                throw ConnectionRouteError.invalidProxy
            }
            let username = proxy.username?.isEmpty == false ? proxy.username : nil
            let secretAccount = proxy.secretAccount?.isEmpty == false ? proxy.secretAccount : nil
            guard (username == nil) == (secretAccount == nil) else {
                throw ConnectionRouteError.proxyCredentialMissing
            }
            if let secretAccount,
               (try KeychainService.secret(account: secretAccount)) == nil {
                throw ConnectionRouteError.proxyCredentialMissing
            }
        }
        if let command = importedProxyCommand,
           !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !importedProxyCommandConfirmed {
            throw ConnectionRouteError.proxyCommandRequiresConfirmation
        }
        return self
    }
}

enum ConnectionFailureStage: String, Codable, Sendable {
    case resolving
    case proxyNegotiation
    case connecting
    case trust
    case authentication
    case openingChannel
}

struct ConnectionRouteFailure: LocalizedError, Equatable, Sendable {
    var hopIndex: Int?
    var hopID: UUID?
    var endpoint: ConnectionEndpoint
    var stage: ConnectionFailureStage
    var diagnosticCode: String
    var detail: String

    var errorDescription: String? {
        let location = hopIndex.map { "第 \($0 + 1) 跳" } ?? "目标服务器"
        return "\(location)在\(stage.title)阶段失败（\(diagnosticCode)）：\(detail)"
    }
}

private extension ConnectionFailureStage {
    var title: String {
        switch self {
        case .resolving: "地址解析"
        case .proxyNegotiation: "代理协商"
        case .connecting: "建立连接"
        case .trust: "主机信任"
        case .authentication: "身份认证"
        case .openingChannel: "打开通道"
        }
    }
}

enum ConnectionRouteError: LocalizedError, Equatable, Sendable {
    case invalidEndpoint(String)
    case invalidProxy
    case proxyCredentialMissing
    case proxyCommandRequiresConfirmation
    case routeLoop(String)
    case tooManyHops(Int)
    case credentialUnavailable(hopID: UUID, reason: String)
    case multipleInteractiveCredentialsUnsupported
    case unsafeListenRequiresConfirmation(String)
    case remoteForwardRequiresConfirmation
    case portUnavailable(Int)
    case tunnelLaunchFailed(String)
    case tunnelReadinessTimedOut
    case tunnelStopTimedOut
    case portStillInUse(Int)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let label):
            "\(label)的主机、端口或用户名无效。"
        case .invalidProxy:
            "代理主机或端口无效。"
        case .proxyCredentialMissing:
            "代理凭据引用缺失；不会回退为匿名代理。"
        case .proxyCommandRequiresConfirmation:
            "导入的 ProxyCommand 可执行本机命令，必须明确确认后才能使用。"
        case .routeLoop(let endpoint):
            "连接路线包含循环：\(endpoint)。"
        case .tooManyHops(let count):
            "连接路线包含 \(DisplayFormat.integer(count)) 跳，超过 8 跳安全上限。"
        case .credentialUnavailable(_, let reason):
            "路线身份不可用：\(reason)。不会尝试其他身份。"
        case .multipleInteractiveCredentialsUnsupported:
            "多个交互式凭据无法可靠区分，已阻止连接。"
        case .unsafeListenRequiresConfirmation(let address):
            "监听 \(address) 会向其他网络设备暴露端口，必须明确确认。"
        case .remoteForwardRequiresConfirmation:
            "Remote Forward 会在远端服务器建立监听端口，必须明确确认。"
        case .portUnavailable(let port):
            "本地端口 \(port) 已被占用。"
        case .tunnelLaunchFailed(let detail):
            detail.isEmpty ? "无法启动 SSH 隧道。" : "无法启动 SSH 隧道：\(detail)"
        case .tunnelReadinessTimedOut:
            "SSH 隧道未在期限内进入 Ready。"
        case .tunnelStopTimedOut:
            "SSH 隧道进程未在停止期限内退出。"
        case .portStillInUse(let port):
            "SSH 隧道已停止，但端口 \(port) 仍被占用。"
        }
    }
}

enum ResolvedCredential: Sendable, Equatable {
    case sshAgent
    case privateKey(path: String, passphraseAccount: String?)
    case password(account: String)
    case keyThenPassword(
        path: String,
        passphraseAccount: String?,
        passwordAccount: String?
    )
}

struct SystemCredentialProvider: CredentialProvider {
    func resolve(
        _ reference: CredentialReference,
        hopID: UUID
    ) throws -> ResolvedCredential {
        switch reference {
        case .sshAgent:
            return .sshAgent
        case .externalPrivateKey(let path):
            let expanded = NSString(string: path).expandingTildeInPath
            guard !expanded.isEmpty,
                  FileManager.default.isReadableFile(atPath: expanded) else {
                throw ConnectionRouteError.credentialUnavailable(
                    hopID: hopID,
                    reason: "私钥文件不可读"
                )
            }
            return .privateKey(path: expanded, passphraseAccount: nil)
        case .importedPrivateKey(let keyID, let hasPassphrase):
            let path: String
            do {
                path = try RouteKeyMaterialStore.materializeImportedKey(keyID: keyID)
            } catch {
                throw ConnectionRouteError.credentialUnavailable(
                    hopID: hopID,
                    reason: "导入私钥读取失败"
                )
            }
            let account = hasPassphrase ? KeychainService.passphraseAccount(for: keyID) : nil
            if let account, (try KeychainService.secret(account: account)) == nil {
                throw ConnectionRouteError.credentialUnavailable(
                    hopID: hopID,
                    reason: "私钥口令缺失"
                )
            }
            return .privateKey(path: path, passphraseAccount: account)
        case .password(let accountID):
            guard try KeychainService.password(for: accountID) != nil else {
                throw ConnectionRouteError.credentialUnavailable(
                    hopID: hopID,
                    reason: "密码凭据缺失"
                )
            }
            return .password(account: accountID.uuidString)
        }
    }
}

enum RouteKeyMaterialStore {
    private static var directory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerDash/routes/keys", isDirectory: true)
    }

    static func materializeImportedKey(keyID: UUID) throws -> String {
        guard let pem = try KeychainService.secret(
            account: KeychainService.importedKeyAccount(for: keyID)
        ) else {
            throw ConnectionRouteError.credentialUnavailable(
                hopID: keyID,
                reason: "导入私钥不存在"
            )
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let file = directory.appendingPathComponent(keyID.uuidString)
        try Data(pem.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: file.path
        )
        return file.path
    }

    static func cleanupAll() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerDash/routes", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
    }
}

struct OpenSSHLaunchPlan: Sendable, Equatable {
    var executable: String
    var arguments: [String]
    var environment: [String: String]
    var routeRevision: UUID
    var diagnosticEndpoints: [ConnectionEndpoint]
}

struct SystemOpenSSHConnectionProvider: ConnectionProvider {
    let credentialProvider: any CredentialProvider

    init(credentialProvider: any CredentialProvider = SystemCredentialProvider()) {
        self.credentialProvider = credentialProvider
    }

    let capabilities: Set<ConnectionCapability> = [
        .interactiveShell,
        .remoteCommand,
        .fileTransfer,
        .localForward,
        .remoteForward,
        .dynamicForward,
        .jumpHosts,
        .socks5Proxy,
        .httpConnectProxy
    ]

    func launchPlan(
        for config: ServerConnectionConfig,
        purpose: ConnectionPurpose
    ) throws -> OpenSSHLaunchPlan {
        let finalEndpoint = ConnectionEndpoint(
            host: config.host,
            port: config.port,
            username: config.username
        )
        let route = try config.route.validated(finalEndpoint: finalEndpoint)
        if route.isDirect {
            return try directPlan(config: config, purpose: purpose)
        }
        return try routedPlan(
            config: config,
            finalEndpoint: finalEndpoint,
            route: route,
            purpose: purpose
        )
    }

    private func directPlan(
        config: ServerConnectionConfig,
        purpose: ConnectionPurpose
    ) throws -> OpenSSHLaunchPlan {
        var arguments: [String]
        var executable = "/usr/bin/ssh"
        switch purpose {
        case .fileTransfer:
            executable = "/usr/bin/sftp"
            arguments = try SSHSupport.directArgumentsForSFTP(config: config)
        case .interactiveShell:
            arguments = try SSHSupport.directArguments(
                for: config,
                strictHostChecking: "yes"
            )
        case .remoteCommand(let command):
            arguments = try SSHSupport.directArguments(
                for: config,
                strictHostChecking: "yes",
                batchMode: !config.authentication.usesPassword,
                remoteCommand: command
            )
        case .portForward(let rule):
            arguments = try SSHSupport.directArguments(
                for: config,
                strictHostChecking: "yes"
            )
            arguments.insert(contentsOf: rule.openSSHArguments, at: 0)
        }
        return OpenSSHLaunchPlan(
            executable: executable,
            arguments: arguments,
            environment: SSHSupport.environment(for: config),
            routeRevision: routeRevision(config.route),
            diagnosticEndpoints: [
                ConnectionEndpoint(host: config.host, port: config.port, username: config.username)
            ]
        )
    }

    private func routedPlan(
        config: ServerConnectionConfig,
        finalEndpoint: ConnectionEndpoint,
        route: ConnectionRoute,
        purpose: ConnectionPurpose
    ) throws -> OpenSSHLaunchPlan {
        var resolvedHops: [(ConnectionHop, ResolvedCredential)] = []
        for hop in route.hops {
            resolvedHops.append((hop, try credentialProvider.resolve(hop.credential, hopID: hop.id)))
        }
        let finalCredential = try resolveFinalCredential(config)
        let materialized = try OpenSSHRouteMaterializer.materialize(
            route: route,
            finalEndpoint: finalEndpoint,
            finalCredential: finalCredential,
            resolvedHops: resolvedHops
        )

        var executable = "/usr/bin/ssh"
        var arguments = ["-F", materialized.configurationURL.path]
        switch purpose {
        case .interactiveShell:
            arguments.append(materialized.finalAlias)
        case .remoteCommand(let command):
            arguments += [materialized.finalAlias, command]
        case .fileTransfer:
            executable = "/usr/bin/sftp"
            arguments.append(materialized.finalAlias)
        case .portForward(let rule):
            arguments += rule.openSSHArguments
            arguments.append(materialized.finalAlias)
        }
        return OpenSSHLaunchPlan(
            executable: executable,
            arguments: arguments,
            environment: materialized.environment,
            routeRevision: route.revision,
            diagnosticEndpoints: route.hops.map(\.endpoint) + [finalEndpoint]
        )
    }

    private func resolveFinalCredential(
        _ config: ServerConnectionConfig
    ) throws -> ResolvedCredential {
        switch config.authentication {
        case .password:
            return try credentialProvider.resolve(
                .password(accountID: config.credentialID),
                hopID: config.id
            )
        case .privateKey:
            return try resolveFinalPrivateKey(config)
        case .keyThenPassword:
            let hasExplicitKey = config.usesImportedKey || !config.privateKeyPath.isEmpty
            guard hasExplicitKey else {
                return try credentialProvider.resolve(
                    .password(accountID: config.credentialID),
                    hopID: config.id
                )
            }
            // Resolve the explicit key first. A read/materialization failure must never
            // become a password or ssh-agent fallback.
            let key = try resolveFinalPrivateKey(config)
            guard case .privateKey(let path, let passphraseAccount) = key else {
                throw ConnectionRouteError.credentialUnavailable(
                    hopID: config.id,
                    reason: "目标私钥解析失败"
                )
            }
            let passwordAccount: String? = {
                guard let password = try? credentialProvider.resolve(
                    .password(accountID: config.credentialID),
                    hopID: config.id
                ), case .password(let account) = password else {
                    return nil
                }
                return account
            }()
            return .keyThenPassword(
                path: path,
                passphraseAccount: passphraseAccount,
                passwordAccount: passwordAccount
            )
        }
    }

    private func resolveFinalPrivateKey(
        _ config: ServerConnectionConfig
    ) throws -> ResolvedCredential {
        let resolved: ResolvedCredential
        if config.usesImportedKey, let keyID = config.sshKeyID {
            resolved = try credentialProvider.resolve(
                .importedPrivateKey(keyID: keyID, hasPassphrase: config.hasPassphrase),
                hopID: config.id
            )
        } else if !config.privateKeyPath.isEmpty {
            resolved = try credentialProvider.resolve(
                .externalPrivateKey(path: config.privateKeyPath),
                hopID: config.id
            )
        } else {
            throw ConnectionRouteError.credentialUnavailable(
                hopID: config.id,
                reason: "目标身份缺失"
            )
        }
        guard case .privateKey(let path, let providerAccount) = resolved else {
            throw ConnectionRouteError.credentialUnavailable(
                hopID: config.id,
                reason: "目标私钥解析失败"
            )
        }
        guard providerAccount == nil,
              config.hasPassphrase,
              let keyID = config.sshKeyID else {
            return resolved
        }
        let account = KeychainService.passphraseAccount(for: keyID)
        guard try KeychainService.secret(account: account) != nil else {
            throw ConnectionRouteError.credentialUnavailable(
                hopID: config.id,
                reason: "私钥口令缺失"
            )
        }
        return .privateKey(path: path, passphraseAccount: account)
    }

    private func routeRevision(_ route: ConnectionRoute) -> UUID {
        route.revision
    }
}

private struct MaterializedOpenSSHRoute {
    var configurationURL: URL
    var finalAlias: String
    var environment: [String: String]
}

private enum OpenSSHRouteMaterializer {
    static func materialize(
        route: ConnectionRoute,
        finalEndpoint: ConnectionEndpoint,
        finalCredential: ResolvedCredential,
        resolvedHops: [(ConnectionHop, ResolvedCredential)]
    ) throws -> MaterializedOpenSSHRoute {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerDash/routes/config", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let file = directory.appendingPathComponent("\(route.revision.uuidString).conf")
        let finalAlias = "serverdash-target-\(route.revision.uuidString.lowercased())"
        let hopAliases = resolvedHops.enumerated().map { index, _ in
            "serverdash-hop-\(index + 1)-\(route.revision.uuidString.lowercased())"
        }
        var lines = [
            "Host *",
            "    BatchMode no",
            "    StrictHostKeyChecking yes",
            "    UserKnownHostsFile \(quote(TrustedHostStore.knownHostsURL.path))",
            "    GlobalKnownHostsFile /dev/null",
            "    UpdateHostKeys no",
            "    ServerAliveInterval 15",
            "    ServerAliveCountMax 3",
            "    ForwardAgent no",
            "    ExitOnForwardFailure yes"
        ]
        var interactiveAccounts: [(pattern: String, account: String)] = []
        for (index, item) in resolvedHops.enumerated() {
            let (hop, credential) = item
            lines += hostBlock(
                alias: hopAliases[index],
                endpoint: hop.endpoint,
                timeout: hop.connectTimeout,
                credential: credential,
                interactiveAccounts: &interactiveAccounts
            )
            if index == 0 {
                lines += try proxyLines(route: route)
            }
        }
        lines += hostBlock(
            alias: finalAlias,
            endpoint: finalEndpoint,
            timeout: 8,
            credential: finalCredential,
            interactiveAccounts: &interactiveAccounts
        )
        if resolvedHops.isEmpty {
            lines += try proxyLines(route: route)
        } else {
            lines.append("    ProxyJump \(hopAliases.joined(separator: ","))")
        }
        try (lines.joined(separator: "\n") + "\n")
            .write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: file.path
        )

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        if !interactiveAccounts.isEmpty {
            let helper = try makeAskPassHelper(
                routeRevision: route.revision,
                accounts: interactiveAccounts
            )
            environment["SSH_ASKPASS"] = helper.path
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = environment["DISPLAY"] ?? ":0"
            environment["SERVERDASH_KEYCHAIN_SERVICE"] = KeychainService.serviceName
        }
        return MaterializedOpenSSHRoute(
            configurationURL: file,
            finalAlias: finalAlias,
            environment: environment
        )
    }

    private static func hostBlock(
        alias: String,
        endpoint: ConnectionEndpoint,
        timeout: TimeInterval,
        credential: ResolvedCredential,
        interactiveAccounts: inout [(pattern: String, account: String)]
    ) -> [String] {
        var lines = [
            "Host \(alias)",
            "    HostName \(quote(endpoint.host))",
            "    Port \(endpoint.port)",
            "    User \(quote(endpoint.username))",
            "    HostKeyAlias \(quote(hostKeyAlias(endpoint)))",
            "    ConnectTimeout \(max(1, Int(timeout)))"
        ]
        switch credential {
        case .sshAgent:
            lines += ["    IdentitiesOnly no"]
        case .privateKey(let path, let passphraseAccount):
            lines += [
                "    IdentityFile \(quote(path))",
                "    IdentitiesOnly yes",
                "    PreferredAuthentications publickey"
            ]
            if let passphraseAccount {
                interactiveAccounts.append((path, passphraseAccount))
            }
        case .password(let account):
            lines += [
                "    PubkeyAuthentication no",
                "    PreferredAuthentications password,keyboard-interactive"
            ]
            interactiveAccounts.append(("\(endpoint.username)@\(endpoint.host)", account))
        case .keyThenPassword(let path, let passphraseAccount, let passwordAccount):
            lines += [
                "    IdentityFile \(quote(path))",
                "    IdentitiesOnly yes",
                "    PreferredAuthentications publickey,password,keyboard-interactive"
            ]
            if let passphraseAccount {
                interactiveAccounts.append((path, passphraseAccount))
            }
            if let passwordAccount {
                interactiveAccounts.append((
                    "\(endpoint.username)@\(endpoint.host)",
                    passwordAccount
                ))
            }
        }
        return lines
    }

    private static func proxyLines(route: ConnectionRoute) throws -> [String] {
        if let proxy = route.proxy {
            let bridge = try RouteProxyBridge.materialize()
            let username = proxy.username ?? ""
            let account = proxy.secretAccount ?? ""
            let command = [
                "/usr/bin/perl",
                shellQuote(bridge.path),
                shellQuote(proxy.kind.rawValue),
                shellQuote(proxy.host),
                String(proxy.port),
                "%h",
                "%p",
                shellQuote(username),
                shellQuote(account)
            ].joined(separator: " ")
            return ["    ProxyCommand \(command)"]
        }
        if let command = route.importedProxyCommand,
           route.importedProxyCommandConfirmed {
            return ["    ProxyCommand \(command)"]
        }
        return []
    }

    private static func makeAskPassHelper(
        routeRevision: UUID,
        accounts: [(pattern: String, account: String)]
    ) throws -> URL {
        let distinct = Dictionary(grouping: accounts, by: \.pattern)
        guard distinct.values.allSatisfy({ Set($0.map(\.account)).count == 1 }) else {
            throw ConnectionRouteError.multipleInteractiveCredentialsUnsupported
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerDash/routes/askpass", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let file = directory.appendingPathComponent(routeRevision.uuidString)
        var script = "#!/bin/sh\nprompt=$1\naccount=''\ncase \"$prompt\" in\n"
        for item in distinct.sorted(by: { $0.key < $1.key }) {
            let pattern = item.key
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "*", with: "\\*")
                .replacingOccurrences(of: "?", with: "\\?")
            let account = item.value[0].account
                .replacingOccurrences(of: "'", with: "'\\''")
            script += "  *\"\(pattern)\"*) account='\(account)' ;;\n"
        }
        script += "esac\n[ -n \"$account\" ] || exit 1\n"
        script += "exec /usr/bin/security find-generic-password -s \"$SERVERDASH_KEYCHAIN_SERVICE\" -a \"$account\" -w\n"
        try Data(script.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: file.path
        )
        return file
    }

    private static func quote(_ value: String) -> String {
        SSHSupport.quotedConfigurationValue(value)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func hostKeyAlias(_ endpoint: ConnectionEndpoint) -> String {
        endpoint.port == 22 ? endpoint.host : "[\(endpoint.host)]:\(endpoint.port)"
    }
}

private enum RouteProxyBridge {
    static func materialize() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerDash/routes/proxy", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let file = directory.appendingPathComponent("proxy-bridge.pl")
        let script = #"""
        #!/usr/bin/perl
        use strict;
        use warnings;
        use IO::Socket::INET;
        use IO::Select;
        use MIME::Base64 qw(encode_base64);

        my ($kind, $proxy_host, $proxy_port, $target_host, $target_port, $user, $account) = @ARGV;
        die "invalid proxy arguments\n" unless defined $account && $proxy_port =~ /^\d+$/ && $target_port =~ /^\d+$/;
        my $secret = '';
        if (length $account) {
            open(my $keychain, '-|', '/usr/bin/security', 'find-generic-password',
                '-s', 'com.serverdash.credentials', '-a', $account, '-w') or die "proxy credential unavailable\n";
            local $/;
            $secret = <$keychain> // '';
            close($keychain) or die "proxy credential unavailable\n";
            $secret =~ s/[\r\n]+\z//;
            die "proxy credential unavailable\n" unless length $secret;
        }
        my $socket = IO::Socket::INET->new(
            PeerHost => $proxy_host,
            PeerPort => int($proxy_port),
            Proto => 'tcp',
            Timeout => 10
        ) or die "proxy connect failed\n";
        binmode($socket);
        binmode(STDIN);
        binmode(STDOUT);

        sub read_exact {
            my ($handle, $length) = @_;
            my $value = '';
            while (length($value) < $length) {
                my $count = sysread($handle, my $chunk, $length - length($value));
                die "proxy handshake truncated\n" unless defined($count) && $count > 0;
                $value .= $chunk;
            }
            return $value;
        }
        sub write_all {
            my ($handle, $value) = @_;
            my $offset = 0;
            while ($offset < length($value)) {
                my $count = syswrite($handle, $value, length($value) - $offset, $offset);
                die "proxy write failed\n" unless defined($count) && $count > 0;
                $offset += $count;
            }
        }

        if ($kind eq 'socks5') {
            my $methods = length($account) ? "\x00\x02" : "\x00";
            write_all($socket, pack('CC', 5, length($methods)) . $methods);
            my ($version, $method) = unpack('CC', read_exact($socket, 2));
            die "SOCKS5 negotiation failed\n" unless $version == 5 && $method != 255;
            if ($method == 2) {
                die "SOCKS5 credentials unavailable\n" unless length($user) && length($secret) && length($user) < 256 && length($secret) < 256;
                write_all($socket, pack('CC', 1, length($user)) . $user . pack('C', length($secret)) . $secret);
                my ($auth_version, $status) = unpack('CC', read_exact($socket, 2));
                die "SOCKS5 authentication failed\n" unless $auth_version == 1 && $status == 0;
            } elsif ($method != 0) {
                die "SOCKS5 method unsupported\n";
            }
            die "target host too long\n" unless length($target_host) < 256;
            write_all($socket, pack('CCCC', 5, 1, 0, 3) . pack('C', length($target_host)) . $target_host . pack('n', $target_port));
            my ($reply_version, $reply, $reserved, $address_type) = unpack('CCCC', read_exact($socket, 4));
            die "SOCKS5 connect failed\n" unless $reply_version == 5 && $reply == 0;
            if ($address_type == 1) { read_exact($socket, 4); }
            elsif ($address_type == 3) { my $length = unpack('C', read_exact($socket, 1)); read_exact($socket, $length); }
            elsif ($address_type == 4) { read_exact($socket, 16); }
            else { die "SOCKS5 address type unsupported\n"; }
            read_exact($socket, 2);
        } elsif ($kind eq 'httpConnect') {
            my $request = "CONNECT $target_host:$target_port HTTP/1.1\r\nHost: $target_host:$target_port\r\n";
            if (length($account)) {
                my $encoded = encode_base64("$user:$secret", '');
                $request .= "Proxy-Authorization: Basic $encoded\r\n";
            }
            write_all($socket, $request . "Connection: keep-alive\r\n\r\n");
            my $headers = '';
            while (index($headers, "\r\n\r\n") < 0) {
                die "HTTP CONNECT response too large\n" if length($headers) >= 16_384;
                $headers .= read_exact($socket, 1);
            }
            my ($status) = $headers =~ m{\AHTTP/\d(?:\.\d)?\s+(\d{3})};
            die "HTTP CONNECT failed\n" unless defined($status) && $status >= 200 && $status < 300;
        } else {
            die "proxy kind unsupported\n";
        }
        $secret = '';

        my $selector = IO::Select->new();
        $selector->add(\*STDIN);
        $selector->add($socket);
        while (my @ready = $selector->can_read()) {
            for my $input (@ready) {
                my $count = sysread($input, my $buffer, 32_768);
                exit 0 unless defined($count) && $count > 0;
                if (fileno($input) == fileno(STDIN)) { write_all($socket, $buffer); }
                else { write_all(\*STDOUT, $buffer); }
            }
        }
        """#
        try Data(script.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: file.path
        )
        return file
    }
}

enum RouteFailureClassifier {
    static func classify(
        stderr: String,
        route: ConnectionRoute,
        finalEndpoint: ConnectionEndpoint
    ) -> ConnectionRouteFailure {
        let lowered = stderr.lowercased()
        let endpoints = route.hops.map(\.endpoint) + [finalEndpoint]
        let matchedIndex = endpoints.firstIndex { endpoint in
            lowered.contains(endpoint.host.lowercased())
        }
        let isFinal = matchedIndex == endpoints.indices.last
        let stage: ConnectionFailureStage
        let code: String
        if lowered.contains("proxy") || lowered.contains("socks") || lowered.contains("connect failed") {
            stage = .proxyNegotiation
            code = "SSH_ROUTE_PROXY"
        } else if lowered.contains("host key") || lowered.contains("identification has changed") {
            stage = .trust
            code = "SSH_ROUTE_TRUST"
        } else if lowered.contains("permission denied") || lowered.contains("authentication") {
            stage = .authentication
            code = "SSH_ROUTE_AUTH"
        } else if lowered.contains("resolve hostname") || lowered.contains("name or service not known") {
            stage = .resolving
            code = "SSH_ROUTE_DNS"
        } else if lowered.contains("channel") || lowered.contains("administratively prohibited") {
            stage = .openingChannel
            code = "SSH_ROUTE_CHANNEL"
        } else {
            stage = .connecting
            code = "SSH_ROUTE_CONNECT"
        }
        let resolvedIndex = matchedIndex ?? endpoints.indices.last!
        return ConnectionRouteFailure(
            hopIndex: isFinal ? nil : (resolvedIndex < route.hops.count ? resolvedIndex : nil),
            hopID: resolvedIndex < route.hops.count ? route.hops[resolvedIndex].id : nil,
            endpoint: endpoints[resolvedIndex],
            stage: stage,
            diagnosticCode: code,
            detail: sanitized(stderr)
        )
    }

    private static func sanitized(_ value: String) -> String {
        let firstLine = value.split(whereSeparator: \.isNewline).first.map(String.init) ?? "连接失败"
        return String(firstLine.prefix(512))
    }
}

@Model
final class ConnectionRouteRecord {
    @Attribute(.unique) var id: UUID
    var serverID: UUID?
    var name: String
    var revision: UUID
    var routeJSON: String
    var sourceAlias: String
    var sourcePathHint: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        serverID: UUID? = nil,
        name: String,
        revision: UUID = UUID(),
        routeJSON: String,
        sourceAlias: String = "",
        sourcePathHint: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.serverID = serverID
        self.name = name
        self.revision = revision
        self.routeJSON = routeJSON
        self.sourceAlias = sourceAlias
        self.sourcePathHint = sourcePathHint
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    convenience init(
        route: ConnectionRoute,
        serverID: UUID?,
        sourceAlias: String = "",
        sourcePathHint: String = ""
    ) throws {
        let data = try JSONEncoder().encode(route)
        self.init(
            id: route.id,
            serverID: serverID,
            name: route.name,
            revision: route.revision,
            routeJSON: String(decoding: data, as: UTF8.self),
            sourceAlias: sourceAlias,
            sourcePathHint: sourcePathHint
        )
    }

    var route: ConnectionRoute? {
        guard let data = routeJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ConnectionRoute.self, from: data)
    }
}

enum PortForwardDirection: String, CaseIterable, Codable, Sendable {
    case local
    case remote
    case dynamic

    var title: String {
        switch self {
        case .local: "Local"
        case .remote: "Remote"
        case .dynamic: "Dynamic SOCKS"
        }
    }
}

struct PortForwardRule: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var name: String
    var serverID: UUID
    var direction: PortForwardDirection
    var bindAddress: String
    var listenPort: Int
    var targetHost: String
    var targetPort: Int

    init(
        id: UUID = UUID(),
        name: String,
        serverID: UUID,
        direction: PortForwardDirection,
        bindAddress: String = "127.0.0.1",
        listenPort: Int,
        targetHost: String = "",
        targetPort: Int = 0
    ) {
        self.id = id
        self.name = name
        self.serverID = serverID
        self.direction = direction
        self.bindAddress = bindAddress.isEmpty ? "127.0.0.1" : bindAddress
        self.listenPort = listenPort
        self.targetHost = targetHost
        self.targetPort = targetPort
    }

    var isWildcardExposure: Bool {
        let normalized = bindAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "0.0.0.0" || normalized == "::" || normalized == "[::]" || normalized == "*"
    }

    func validate(
        exposureConfirmed: Bool,
        remoteForwardConfirmed: Bool = false
    ) throws {
        guard (1...65_535).contains(listenPort) else {
            throw ConnectionRouteError.portUnavailable(listenPort)
        }
        if direction != .dynamic {
            guard !targetHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (1...65_535).contains(targetPort) else {
                throw ConnectionRouteError.invalidEndpoint("转发目标")
            }
        }
        if isWildcardExposure && !exposureConfirmed {
            throw ConnectionRouteError.unsafeListenRequiresConfirmation(bindAddress)
        }
        if direction == .remote && !remoteForwardConfirmed {
            throw ConnectionRouteError.remoteForwardRequiresConfirmation
        }
    }

    var operationRisk: String {
        direction == .remote || isWildcardExposure ? "高" : "低"
    }

    var openSSHArguments: [String] {
        let spec: String
        switch direction {
        case .local:
            spec = "\(bindAddress):\(listenPort):\(targetHost):\(targetPort)"
        case .remote:
            spec = "\(bindAddress):\(listenPort):\(targetHost):\(targetPort)"
        case .dynamic:
            spec = "\(bindAddress):\(listenPort)"
        }
        let flag: String
        switch direction {
        case .local: flag = "-L"
        case .remote: flag = "-R"
        case .dynamic: flag = "-D"
        }
        return [
            "-N",
            "-T",
            "-o", "ExitOnForwardFailure=yes",
            flag, spec
        ]
    }
}

@Model
final class PortForwardRuleRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var serverID: UUID
    var directionRawValue: String
    var bindAddress: String
    var listenPort: Int
    var targetHost: String
    var targetPort: Int
    var createdAt: Date
    var updatedAt: Date

    init(
        rule: PortForwardRule,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        id = rule.id
        name = rule.name
        serverID = rule.serverID
        directionRawValue = rule.direction.rawValue
        bindAddress = rule.bindAddress
        listenPort = rule.listenPort
        targetHost = rule.targetHost
        targetPort = rule.targetPort
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var rule: PortForwardRule {
        PortForwardRule(
            id: id,
            name: name,
            serverID: serverID,
            direction: PortForwardDirection(rawValue: directionRawValue) ?? .local,
            bindAddress: bindAddress,
            listenPort: listenPort,
            targetHost: targetHost,
            targetPort: targetPort
        )
    }
}
