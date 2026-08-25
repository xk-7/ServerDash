import Darwin
import Foundation

enum SSHConfigField: String, CaseIterable, Codable, Sendable {
    case hostName
    case user
    case port
    case identityFile
    case proxyJump
    case proxyCommand
    case serverAliveInterval

    var title: String {
        switch self {
        case .hostName: "HostName"
        case .user: "User"
        case .port: "Port"
        case .identityFile: "IdentityFile"
        case .proxyJump: "ProxyJump"
        case .proxyCommand: "ProxyCommand"
        case .serverAliveInterval: "ServerAliveInterval"
        }
    }
}

struct SSHConfigSource: Hashable, Codable, Sendable {
    var file: String
    var line: Int
    var matchedHostPatterns: [String]

    var display: String {
        "\(file):\(line)"
    }
}

struct SSHConfigResolvedValue: Identifiable, Hashable, Codable, Sendable {
    var field: SSHConfigField
    var value: String
    var source: SSHConfigSource

    var id: String {
        "\(field.rawValue)|\(source.file)|\(source.line)|\(value)"
    }
}

struct SSHConfigUnsupportedDirective: Identifiable, Hashable, Codable, Sendable {
    var name: String
    var source: SSHConfigSource
    var reason: String

    var id: String {
        "\(name)|\(source.file)|\(source.line)"
    }
}

enum SSHConfigIssueKind: String, Codable, Sendable {
    case includeLoop
    case unreadableFile
    case invalidValue
    case resourceLimit
}

struct SSHConfigIssue: Identifiable, Hashable, Codable, Sendable {
    var kind: SSHConfigIssueKind
    var message: String
    var sourceFile: String
    var line: Int?

    var id: String {
        "\(kind.rawValue)|\(sourceFile)|\(line ?? 0)|\(message)"
    }
}

struct SSHConfigMatch: Identifiable, Hashable, Codable, Sendable {
    var patterns: [String]
    var source: SSHConfigSource

    var id: String {
        "\(source.file)|\(source.line)|\(patterns.joined(separator: ","))"
    }
}

struct SSHConfigResolutionReport: Hashable, Codable, Sendable {
    var alias: String
    var values: [SSHConfigResolvedValue]
    var matches: [SSHConfigMatch]
    var unsupported: [SSHConfigUnsupportedDirective]
    var issues: [SSHConfigIssue]

    func value(_ field: SSHConfigField) -> String? {
        if field == .identityFile {
            let identities = values.filter { $0.field == .identityFile }.map(\.value)
            return identities.isEmpty ? nil : identities.joined(separator: ", ")
        }
        return values.first { $0.field == field }?.value
    }

    func resolved(_ field: SSHConfigField) -> SSHConfigResolvedValue? {
        values.first { $0.field == field }
    }
}

struct SSHConfigRouteImport: Sendable {
    var route: ConnectionRoute
    var endpoint: ConnectionEndpoint
    var reports: [SSHConfigResolutionReport]
}

enum SSHConfigImportError: LocalizedError, Equatable {
    case unresolvedAlias(String)
    case missingUser(String)
    case invalidPort(String)
    case routeLoop(String)

    var errorDescription: String? {
        switch self {
        case .unresolvedAlias(let alias):
            "SSH Config 无法解析别名 \(alias)。"
        case .missingUser(let alias):
            "SSH Config 中 \(alias) 未解析出 User。"
        case .invalidPort(let value):
            "SSH Config 端口无效：\(value)。"
        case .routeLoop(let alias):
            "ProxyJump 路线包含循环：\(alias)。"
        }
    }
}

struct SSHConfigImporter {
    private let fileManager: FileManager
    private let maxIncludeFiles: Int
    private let maxFileBytes: Int

    init(
        fileManager: FileManager = .default,
        maxIncludeFiles: Int = 256,
        maxFileBytes: Int = 2_000_000
    ) {
        self.fileManager = fileManager
        self.maxIncludeFiles = max(1, maxIncludeFiles)
        self.maxFileBytes = max(1_024, maxFileBytes)
    }

    func resolve(alias: String, from rootURL: URL) -> SSHConfigResolutionReport {
        let normalizedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        var state = EvaluationState(alias: normalizedAlias)
        var activeFiles: [String] = []
        var includeCount = 0
        _ = evaluate(
            fileURL: rootURL.standardizedFileURL,
            matches: true,
            currentPatterns: ["*"],
            activeFiles: &activeFiles,
            includeCount: &includeCount,
            state: &state
        )
        if state.firstValue[.hostName] == nil {
            state.firstValue[.hostName] = SSHConfigResolvedValue(
                field: .hostName,
                value: normalizedAlias,
                source: SSHConfigSource(
                    file: rootURL.path,
                    line: 0,
                    matchedHostPatterns: ["implicit destination"]
                )
            )
        }
        if state.firstValue[.port] == nil {
            state.firstValue[.port] = SSHConfigResolvedValue(
                field: .port,
                value: "22",
                source: SSHConfigSource(
                    file: rootURL.path,
                    line: 0,
                    matchedHostPatterns: ["OpenSSH default"]
                )
            )
        }
        var values = SSHConfigField.allCases.compactMap { field in
            field == .identityFile ? nil : state.firstValue[field]
        }
        values.append(contentsOf: state.identityFiles)
        return SSHConfigResolutionReport(
            alias: normalizedAlias,
            values: values,
            matches: state.matches,
            unsupported: state.unsupported,
            issues: state.issues
        )
    }

    func importRoute(alias: String, from rootURL: URL) throws -> SSHConfigRouteImport {
        var reports: [SSHConfigResolutionReport] = []
        var visiting = Set<String>()
        var hops: [ConnectionHop] = []
        let finalReport = resolve(alias: alias, from: rootURL)
        let finalEndpoint = try endpoint(from: finalReport, explicit: nil)
        try appendJumps(
            from: finalReport,
            rootURL: rootURL,
            visiting: &visiting,
            hops: &hops,
            reports: &reports
        )
        reports.append(finalReport)
        let route = ConnectionRoute(
            name: "SSH Config · \(alias)",
            hops: hops,
            importedProxyCommand: finalReport.value(.proxyCommand),
            importedProxyCommandConfirmed: false
        )
        _ = try route.validated(finalEndpoint: finalEndpoint)
        return SSHConfigRouteImport(
            route: route,
            endpoint: finalEndpoint,
            reports: reports
        )
    }

    private func appendJumps(
        from report: SSHConfigResolutionReport,
        rootURL: URL,
        visiting: inout Set<String>,
        hops: inout [ConnectionHop],
        reports: inout [SSHConfigResolutionReport]
    ) throws {
        guard let jumpValue = report.value(.proxyJump),
              jumpValue.lowercased() != "none" else { return }
        for rawSpec in jumpValue.split(separator: ",") {
            let spec = parseJumpSpec(String(rawSpec))
            guard visiting.insert(spec.alias.lowercased()).inserted else {
                throw SSHConfigImportError.routeLoop(spec.alias)
            }
            let jumpReport = resolve(alias: spec.alias, from: rootURL)
            try appendJumps(
                from: jumpReport,
                rootURL: rootURL,
                visiting: &visiting,
                hops: &hops,
                reports: &reports
            )
            let endpoint = try endpoint(from: jumpReport, explicit: spec)
            let identity = jumpReport.values.first { $0.field == .identityFile }?.value
            let credential: CredentialReference = identity.map {
                .externalPrivateKey(path: $0)
            } ?? .sshAgent
            let timeout = TimeInterval(
                jumpReport.value(.serverAliveInterval).flatMap(Int.init) ?? 8
            )
            let normalizedKey = endpoint.normalizedKey
            if !hops.contains(where: { $0.endpoint.normalizedKey == normalizedKey }) {
                hops.append(
                    ConnectionHop(
                        name: spec.alias,
                        endpoint: endpoint,
                        credential: credential,
                        connectTimeout: timeout
                    )
                )
                reports.append(jumpReport)
            }
            visiting.remove(spec.alias.lowercased())
        }
    }

    private func endpoint(
        from report: SSHConfigResolutionReport,
        explicit: JumpSpec?
    ) throws -> ConnectionEndpoint {
        let host = report.value(.hostName) ?? explicit?.alias ?? report.alias
        let user = explicit?.user ?? report.value(.user) ?? NSUserName()
        let portText = explicit?.port.map(String.init) ?? report.value(.port) ?? "22"
        guard let port = Int(portText), (1...65_535).contains(port) else {
            throw SSHConfigImportError.invalidPort(portText)
        }
        return try ConnectionEndpoint(host: host, port: port, username: user)
            .validated(label: report.alias)
    }

    @discardableResult
    private func evaluate(
        fileURL: URL,
        matches initialMatches: Bool,
        currentPatterns initialPatterns: [String],
        activeFiles: inout [String],
        includeCount: inout Int,
        state: inout EvaluationState
    ) -> (Bool, [String]) {
        let path = fileURL.standardizedFileURL.path
        if activeFiles.contains(path) {
            state.issues.append(
                SSHConfigIssue(
                    kind: .includeLoop,
                    message: "Include 循环已阻止：\((activeFiles + [path]).joined(separator: " → "))",
                    sourceFile: path,
                    line: nil
                )
            )
            return (initialMatches, initialPatterns)
        }
        guard includeCount < maxIncludeFiles else {
            state.issues.append(
                SSHConfigIssue(
                    kind: .resourceLimit,
                    message: "Include 文件数量超过 \(maxIncludeFiles) 个。",
                    sourceFile: path,
                    line: nil
                )
            )
            return (initialMatches, initialPatterns)
        }
        includeCount += 1
        activeFiles.append(path)
        defer { _ = activeFiles.popLast() }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        } catch {
            state.issues.append(
                SSHConfigIssue(
                    kind: .unreadableFile,
                    message: "文件不可读或权限不足。",
                    sourceFile: path,
                    line: nil
                )
            )
            return (initialMatches, initialPatterns)
        }
        guard data.count <= maxFileBytes,
              let contents = String(data: data, encoding: .utf8) else {
            state.issues.append(
                SSHConfigIssue(
                    kind: .resourceLimit,
                    message: "文件超过大小上限或不是 UTF-8。",
                    sourceFile: path,
                    line: nil
                )
            )
            return (initialMatches, initialPatterns)
        }

        var currentMatches = initialMatches
        var currentPatterns = initialPatterns
        for (offset, rawLine) in contents.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).enumerated() {
            let lineNumber = offset + 1
            let tokens = Self.tokens(String(rawLine))
            guard let first = tokens.first else { continue }
            let parsed = Self.directiveAndValues(first: first, rest: Array(tokens.dropFirst()))
            let directive = parsed.directive.lowercased()
            let values = parsed.values
            if directive == "host" {
                currentPatterns = values
                currentMatches = Self.matches(alias: state.alias, patterns: values)
                if currentMatches {
                    let source = SSHConfigSource(
                        file: path,
                        line: lineNumber,
                        matchedHostPatterns: values
                    )
                    state.matches.append(SSHConfigMatch(patterns: values, source: source))
                }
                continue
            }
            if directive == "match" {
                let source = SSHConfigSource(
                    file: path,
                    line: lineNumber,
                    matchedHostPatterns: currentPatterns
                )
                if currentMatches {
                    state.unsupported.append(
                        SSHConfigUnsupportedDirective(
                            name: "Match",
                            source: source,
                            reason: "Match 条件不会被猜测解析；块内字段不会导入。"
                        )
                    )
                }
                currentMatches = false
                currentPatterns = ["Match"]
                continue
            }
            guard currentMatches else { continue }
            let source = SSHConfigSource(
                file: path,
                line: lineNumber,
                matchedHostPatterns: currentPatterns
            )
            if directive == "include" {
                for includePattern in values {
                    for includedURL in includeURLs(
                        pattern: includePattern,
                        relativeTo: fileURL.deletingLastPathComponent()
                    ) {
                        let result = evaluate(
                            fileURL: includedURL,
                            matches: currentMatches,
                            currentPatterns: currentPatterns,
                            activeFiles: &activeFiles,
                            includeCount: &includeCount,
                            state: &state
                        )
                        currentMatches = result.0
                        currentPatterns = result.1
                    }
                }
                continue
            }
            guard let field = Self.supportedField(directive) else {
                state.unsupported.append(
                    SSHConfigUnsupportedDirective(
                        name: first,
                        source: source,
                        reason: "当前 Provider 不支持此指令。"
                    )
                )
                continue
            }
            let value = values.joined(separator: " ")
            guard !value.isEmpty else {
                state.issues.append(
                    SSHConfigIssue(
                        kind: .invalidValue,
                        message: "\(field.title) 缺少值。",
                        sourceFile: path,
                        line: lineNumber
                    )
                )
                continue
            }
            let resolved = SSHConfigResolvedValue(field: field, value: value, source: source)
            if field == .identityFile {
                state.identityFiles.append(resolved)
            } else if state.firstValue[field] == nil {
                state.firstValue[field] = resolved
            }
        }
        return (currentMatches, currentPatterns)
    }

    private func includeURLs(pattern: String, relativeTo directory: URL) -> [URL] {
        let expanded = NSString(string: pattern).expandingTildeInPath
        let candidate = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : directory.appendingPathComponent(expanded)
        let standardized = candidate.standardizedFileURL
        guard Self.hasWildcard(standardized.path) else {
            return fileManager.fileExists(atPath: standardized.path) ? [standardized] : []
        }
        let components = standardized.pathComponents
        guard let wildcardIndex = components.firstIndex(where: Self.hasWildcard) else { return [] }
        let prefix = components.prefix(wildcardIndex).joined(separator: "/")
        let searchRoot = URL(fileURLWithPath: prefix.isEmpty ? "/" : "/" + prefix)
        guard let enumerator = fileManager.enumerator(
            at: searchRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var matches: [URL] = []
        for case let url as URL in enumerator {
            if matches.count >= maxIncludeFiles { break }
            let path = url.standardizedFileURL.path
            if Self.fnmatch(standardized.path, path, FNM_PATHNAME) == 0 {
                matches.append(url.standardizedFileURL)
            }
        }
        return matches.sorted { $0.path < $1.path }
    }

    private static func fnmatch(_ pattern: String, _ value: String, _ flags: Int32 = 0) -> Int32 {
        pattern.withCString { patternPointer in
            value.withCString { valuePointer in
                Darwin.fnmatch(patternPointer, valuePointer, flags)
            }
        }
    }

    private static func matches(alias: String, patterns: [String]) -> Bool {
        var positive = false
        for pattern in patterns {
            let negated = pattern.hasPrefix("!")
            let value = negated ? String(pattern.dropFirst()) : pattern
            guard fnmatch(value.lowercased(), alias.lowercased()) == 0 else { continue }
            if negated { return false }
            positive = true
        }
        return positive
    }

    private static func hasWildcard(_ value: String) -> Bool {
        value.contains("*") || value.contains("?") || value.contains("[")
    }

    private static func supportedField(_ value: String) -> SSHConfigField? {
        switch value {
        case "hostname": .hostName
        case "user": .user
        case "port": .port
        case "identityfile": .identityFile
        case "proxyjump": .proxyJump
        case "proxycommand": .proxyCommand
        case "serveraliveinterval": .serverAliveInterval
        default: nil
        }
    }

    private static func directiveAndValues(
        first: String,
        rest: [String]
    ) -> (directive: String, values: [String]) {
        if let equal = first.firstIndex(of: "=") {
            let key = String(first[..<equal])
            let value = String(first[first.index(after: equal)...])
            return (key, (value.isEmpty ? [] : [value]) + rest)
        }
        if rest.first == "=" {
            return (first, Array(rest.dropFirst()))
        }
        return (first, rest)
    }

    static func tokens(_ line: String) -> [String] {
        var tokens: [String] = []
        var token = ""
        var quote: Character?
        var escaping = false
        for character in line {
            if escaping {
                token.append(character)
                escaping = false
                continue
            }
            if character == "\\" {
                escaping = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    token.append(character)
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                continue
            }
            if character == "#" {
                break
            }
            if character.isWhitespace {
                if !token.isEmpty {
                    tokens.append(token)
                    token = ""
                }
                continue
            }
            token.append(character)
        }
        if escaping { token.append("\\") }
        if !token.isEmpty { tokens.append(token) }
        return tokens
    }

    private func parseJumpSpec(_ raw: String) -> JumpSpec {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var user: String?
        if let at = value.lastIndex(of: "@") {
            user = String(value[..<at])
            value = String(value[value.index(after: at)...])
        }
        var port: Int?
        if value.hasPrefix("[") {
            if let close = value.firstIndex(of: "]") {
                let after = value.index(after: close)
                if after < value.endIndex, value[after] == ":" {
                    port = Int(value[value.index(after: after)...])
                }
                value = String(value[value.index(after: value.startIndex)..<close])
            }
        } else if value.filter({ $0 == ":" }).count == 1,
                  let colon = value.lastIndex(of: ":"),
                  let parsedPort = Int(value[value.index(after: colon)...]) {
            port = parsedPort
            value = String(value[..<colon])
        }
        return JumpSpec(alias: value, user: user, port: port)
    }
}

private struct EvaluationState {
    var alias: String
    var firstValue: [SSHConfigField: SSHConfigResolvedValue] = [:]
    var identityFiles: [SSHConfigResolvedValue] = []
    var matches: [SSHConfigMatch] = []
    var unsupported: [SSHConfigUnsupportedDirective] = []
    var issues: [SSHConfigIssue] = []
}

private struct JumpSpec {
    var alias: String
    var user: String?
    var port: Int?
}

enum SSHDraftValueOrigin: String, Codable, Sendable {
    case imported
    case userOverride
}

struct SSHDraftValue<Value: Equatable & Sendable>: Equatable, Sendable {
    var value: Value
    var origin: SSHDraftValueOrigin

    mutating func synchronize(_ importedValue: Value) {
        guard origin == .imported else { return }
        value = importedValue
    }
}

struct SSHImportedConnectionDraft: Equatable, Sendable {
    var host: SSHDraftValue<String>
    var port: SSHDraftValue<Int>
    var user: SSHDraftValue<String>
    var identityFile: SSHDraftValue<String>
    var proxyJump: SSHDraftValue<String>
    var serverAliveInterval: SSHDraftValue<Int>

    mutating func synchronize(with report: SSHConfigResolutionReport) throws {
        host.synchronize(report.value(.hostName) ?? report.alias)
        guard let parsedPort = Int(report.value(.port) ?? "22") else {
            throw SSHConfigImportError.invalidPort(report.value(.port) ?? "")
        }
        port.synchronize(parsedPort)
        user.synchronize(report.value(.user) ?? NSUserName())
        identityFile.synchronize(
            report.values.first { $0.field == .identityFile }?.value ?? ""
        )
        proxyJump.synchronize(report.value(.proxyJump) ?? "")
        serverAliveInterval.synchronize(
            Int(report.value(.serverAliveInterval) ?? "0") ?? 0
        )
    }
}
