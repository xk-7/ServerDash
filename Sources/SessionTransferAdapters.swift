import CoreFoundation
import Foundation

enum SessionAdapterRegistry {
    static let importers: [any SessionImportAdapter] = [
        XShellSessionAdapter(),
        SecureCRTSessionAdapter(),
        MobaXtermSessionAdapter(),
        FinalShellSessionAdapter(),
        XTerminalSessionAdapter(),
        PuTTYSessionAdapter(),
        ServerDashSessionAdapter(),
        OpenSSHSessionAdapter()
    ]

    static let exporters: [any SessionExportAdapter] = [
        XShellSessionAdapter(),
        SecureCRTSessionAdapter(),
        MobaXtermSessionAdapter(),
        FinalShellSessionAdapter(),
        XTerminalSessionAdapter(),
        PuTTYSessionAdapter(),
        ServerDashSessionAdapter(),
        OpenSSHSessionAdapter()
    ]
}

struct INISection {
    var name: String
    var values: [String: String]
}

enum SessionTextDecoder {
    static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if data.starts(with: [0xFF, 0xFE]) {
            return String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        }
        if data.count >= 4 {
            let sample = data.prefix(min(data.count, 512))
            let evenNulls = sample.enumerated().count { $0.offset.isMultiple(of: 2) && $0.element == 0 }
            let oddNulls = sample.enumerated().count { !$0.offset.isMultiple(of: 2) && $0.element == 0 }
            if oddNulls > sample.count / 8,
               let value = String(data: data, encoding: .utf16LittleEndian) {
                return value
            }
            if evenNulls > sample.count / 8,
               let value = String(data: data, encoding: .utf16BigEndian) {
                return value
            }
        }
        let gb18030 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        for encoding in [String.Encoding.utf8, .windowsCP1252, gb18030, .isoLatin1] {
            if let value = String(data: data, encoding: encoding) { return value }
        }
        return nil
    }
}

enum SessionParsing {
    static func normalizedKey(_ key: String) -> String {
        var value = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let firstQuote = value.firstIndex(of: "\""), let lastQuote = value.lastIndex(of: "\""),
           firstQuote < lastQuote {
            value = String(value[value.index(after: firstQuote)..<lastQuote])
        }
        return value.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    static func normalizedFields(_ fields: [String: String]) -> [String: String] {
        fields.reduce(into: [:]) { result, item in
            let key = normalizedKey(item.key)
            if result[key]?.isEmpty != false { result[key] = cleanValue(item.value) }
        }
    }

    static func value(_ fields: [String: String], keys: [String]) -> String? {
        for key in keys {
            if let value = fields[normalizedKey(key)]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    static func parseINI(_ text: String) -> [INISection] {
        var sections: [INISection] = [INISection(name: "", values: [:])]
        for rawLine in logicalLines(text) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix(";"), !line.hasPrefix("#") else { continue }
            if line.hasPrefix("["), let end = line.firstIndex(of: "]") {
                let name = String(line[line.index(after: line.startIndex)..<end])
                sections.append(INISection(name: name, values: [:]))
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            sections[sections.count - 1].values[key] = cleanValue(value)
        }
        return sections
    }

    static func merge(_ sections: [INISection]) -> [String: String] {
        var result: [String: String] = [:]
        for section in sections {
            for (key, value) in section.values {
                let composite = section.name.isEmpty ? key : "\(section.name).\(key)"
                result[composite] = value
                if result[key] == nil { result[key] = value }
            }
        }
        return normalizedFields(result)
    }

    static func logicalLines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    static func parseCSV(_ text: String) -> [[String: String]] {
        let firstLine = logicalLines(text).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        let candidates: [Character] = [",", "\t", ";"]
        let delimiter = candidates.max { lhs, rhs in
            firstLine.filter { $0 == lhs }.count < firstLine.filter { $0 == rhs }.count
        } ?? ","
        let rows: [[String]]
        if firstLine.contains(delimiter) {
            rows = csvRows(text, delimiter: delimiter)
        } else {
            rows = logicalLines(text).map(whitespaceTokens).filter { !$0.isEmpty }
        }
        guard let header = rows.first, header.count > 0 else { return [] }
        return rows.dropFirst().filter { !$0.allSatisfy(\.isEmpty) }.map { row in
            var result: [String: String] = [:]
            for index in header.indices where index < row.count {
                result[header[index]] = row[index]
            }
            return result
        }
    }

    static func csvRows(_ text: String, delimiter: Character = ",") -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "\"" {
                let next = text.index(after: index)
                if quoted, next < text.endIndex, text[next] == "\"" {
                    field.append("\"")
                    index = next
                } else {
                    quoted.toggle()
                }
            } else if character == delimiter, !quoted {
                row.append(field)
                field = ""
            } else if (character == "\n" || character == "\r"), !quoted {
                if character == "\r" {
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "\n" { index = next }
                }
                row.append(field)
                if !row.allSatisfy(\.isEmpty) { rows.append(row) }
                row = []
                field = ""
            } else {
                field.append(character)
            }
            index = text.index(after: index)
        }
        row.append(field)
        if !row.allSatisfy(\.isEmpty) { rows.append(row) }
        return rows
    }

    static func whitespaceTokens(_ text: String) -> [String] {
        let characters = Array(text)
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if let activeQuote = quote {
                if character == "\\", index + 1 < characters.count,
                   characters[index + 1] == activeQuote || characters[index + 1] == "\\" {
                    index += 1
                    current.append(characters[index])
                } else if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character.isWhitespace {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(character)
            }
            index += 1
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    static func jsonSessionDictionaries(_ object: Any) -> [[String: Any]] {
        if let array = object as? [Any] {
            return array.flatMap(jsonSessionDictionaries)
        }
        guard let dictionary = object as? [String: Any] else { return [] }
        let keys = Set(dictionary.keys.map(normalizedKey))
        let hostKeys: Set<String> = ["host", "hostname", "hostaddress", "ip", "address"]
        if !keys.isDisjoint(with: hostKeys) {
            return [dictionary]
        }
        return dictionary.values.flatMap(jsonSessionDictionaries)
    }

    static func stringFields(_ values: [String: Any]) -> [String: String] {
        values.reduce(into: [:]) { result, item in
            switch item.value {
            case let string as String: result[item.key] = string
            case let number as NSNumber: result[item.key] = number.stringValue
            default: break
            }
        }
    }

    static func candidate(
        fields rawFields: [String: String],
        source: SessionTransferSource,
        path: String,
        fallbackName: String,
        fallbackGroup: String? = nil,
        allowPlaintextPassword: Bool = false,
        additionalWarnings: [String] = []
    ) -> SessionImportCandidate {
        let fields = normalizedFields(rawFields)
        var host = value(fields, keys: ["hostname", "host", "hostaddress", "server", "ip", "address"]) ?? ""
        var parsedPortFromURI: Int?
        var parsedUsernameFromURI: String?
        if let components = URLComponents(string: host), components.scheme?.lowercased() == "ssh" {
            host = components.host ?? host
            parsedPortFromURI = components.port
            parsedUsernameFromURI = components.user
        }
        let portText = value(fields, keys: ["port", "portnumber", "sshport", "ssh2port"])
        let parsedPort = parsePort(portText)
        let port = parsedPortFromURI ?? parsedPort ?? 22
        let username = value(fields, keys: ["username", "user", "usernamevalue", "login", "account"])
            ?? parsedUsernameFromURI ?? ""
        let name = value(fields, keys: ["sessionname", "title", "name", "label"])
            ?? fallbackName
        let group = value(fields, keys: ["folder", "group", "groupname", "subrep", "category"])
            ?? fallbackGroup
        let protocolName = value(fields, keys: ["protocol", "protocolname", "connectiontype", "type"])
        let rawKeyPath = value(fields, keys: ["identityfile", "privatekeypath", "publickeyfile", "userkey",
                                                    "identityfilenamev2", "privatekey"])
        let keyPath = SessionTransferSecurity.externalPrivateKeyPath(rawKeyPath)
        let auth = authenticationHint(fields: fields, keyPath: keyPath)
        let notes = value(fields, keys: ["note", "notes", "description", "remark", "remarks"])
        let defaultPath = value(fields, keys: ["defaultpath", "defaultremotepath", "initialpath", "sftppath"])
        let tagsText = value(fields, keys: ["tags", "tag"]) ?? ""
        let tags = tagsText.split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var warnings = additionalWarnings
        var errors: [String] = []
        if let protocolName, !isSSHProtocol(protocolName) {
            errors.append("不支持的协议：\(protocolName)")
        }
        if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors.append("缺少主机地址") }
        if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors.append("缺少用户名") }
        if parsedPortFromURI == nil, let portText, !cleanValue(portText).isEmpty, parsedPort == nil {
            errors.append("端口无效：\(cleanValue(portText))")
        }
        if !(1...65_535).contains(port) { errors.append("端口无效") }

        let rawPassword = allowPlaintextPassword
            ? value(fields, keys: ["password", "passwd", "pass"])
            : nil
        let password = isUsablePlaintextPassword(rawPassword) ? rawPassword : nil
        if !allowPlaintextPassword,
           value(fields, keys: ["password", "passwd", "passwordv2", "encryptedpassword"]) != nil {
            warnings.append("已忽略客户端加密密码，请在 ServerDash 中重新填写")
        }
        if rawKeyPath != nil, keyPath == nil {
            warnings.append("已忽略嵌入式私钥正文，请在身份与密钥中单独导入")
        }
        if value(fields, keys: ["passphrase", "keypassphrase", "privatekeypassword"]) != nil {
            warnings.append("已忽略私钥口令，请在 ServerDash 中重新填写")
        }
        if value(fields, keys: ["identityid", "credentialid", "credentials"]) != nil {
            warnings.append("已忽略其他客户端的凭据引用")
        }
        if value(fields, keys: ["initscript", "loginscript", "remotecommand"]) != nil {
            warnings.append("已忽略客户端专属脚本或远程命令")
        }
        if value(fields, keys: ["proxyjump", "proxycommand", "tunnel", "portforwarding"]) != nil {
            warnings.append("已忽略代理链、跳板机或端口转发配置")
        }

        return SessionImportCandidate(
            record: SessionTransferRecord(
                name: cleanValue(name),
                group: group.map(cleanValue),
                host: cleanValue(host),
                port: port,
                username: cleanValue(username),
                authentication: password != nil && auth == .privateKey ? .keyThenPassword
                    : (password != nil && auth == .unspecified ? .password : auth),
                externalPrivateKeyPath: keyPath,
                notes: notes,
                tags: tags,
                defaultRemotePath: defaultPath
            ),
            source: source,
            sourcePath: path,
            warnings: warnings,
            errors: errors,
            credential: password.map { EphemeralSessionCredential(password: $0) }
        )
    }

    static func parsePort(_ value: String?) -> Int? {
        guard let value else { return nil }
        let trimmed = cleanValue(value).replacingOccurrences(of: ",", with: "")
        if trimmed.lowercased().hasPrefix("0x") {
            return Int(trimmed.dropFirst(2), radix: 16)
        }
        return Int(trimmed)
    }

    static func pathGroup(_ path: String) -> String? {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard directory != ".", directory != "/", !directory.isEmpty else { return nil }
        let containerNames: Set<String> = ["config", "conn", "sessions", "xshell"]
        let components = directory.split(separator: "/").filter { !containerNames.contains($0.lowercased()) }
        return components.isEmpty ? nil : components.map(String.init).joined(separator: "/")
    }

    static func cleanValue(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.count >= 2,
           (result.hasPrefix("\"") && result.hasSuffix("\"") || result.hasPrefix("'") && result.hasSuffix("'")) {
            result = String(result.dropFirst().dropLast())
        }
        return result
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    static func safeLine(_ value: String) -> String {
        value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    static func safeFileComponent(_ value: String, fallback: String = "session") -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_. "))
        let sanitized = value.unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return sanitized.isEmpty ? fallback : String(sanitized.prefix(120))
    }

    private static func authenticationHint(fields: [String: String], keyPath: String?) -> AuthenticationHint {
        let value = self.value(fields, keys: ["authentication", "authenticationmethod", "auth", "authtype", "method", "logintype"])?
            .lowercased() ?? ""
        let hasKey = keyPath?.isEmpty == false || value.contains("publickey") || value.contains("privatekey")
            || value.contains("key")
        let hasPassword = value.contains("password") || value.contains("keyboard")
        if hasKey && hasPassword { return .keyThenPassword }
        if hasKey { return .privateKey }
        if hasPassword { return .password }
        return .unspecified
    }

    private static func isSSHProtocol(_ value: String) -> Bool {
        let normalized = value.lowercased()
        return normalized.contains("ssh") || normalized.contains("sftp") || normalized == "2"
    }

    private static func isUsablePlaintextPassword(_ value: String?) -> Bool {
        guard let value, !value.isEmpty else { return false }
        let lowered = value.lowercased()
        return value != "***" && !lowered.hasPrefix("enc:") && !lowered.hasPrefix("encrypted:")
    }
}

private func cleanValue(_ value: String) -> String {
    SessionParsing.cleanValue(value)
}

struct XShellSessionAdapter: SessionImportAdapter, SessionExportAdapter {
    let source: SessionTransferSource = .xShell
    let target: SessionTransferTarget = .xShell

    func confidence(for file: SessionSourceFile) -> Int {
        if file.pathExtension == "xsh" { return 100 }
        guard let text = SessionTextDecoder.decode(file.data) else { return 0 }
        return text.localizedCaseInsensitiveContains("[CONNECTION") ? 70 : 0
    }

    func inspect(_ files: [SessionSourceFile]) throws -> SessionAdapterInspection {
        var candidates: [SessionImportCandidate] = []
        for file in files where confidence(for: file) > 0 {
            try Task.checkCancellation()
            guard let text = SessionTextDecoder.decode(file.data) else { continue }
            let fields = SessionParsing.merge(SessionParsing.parseINI(text))
            var mapped = fields
            mapped["sessionname"] = SessionParsing.value(fields, keys: ["sessioninfo.name", "name"])
            mapped["hostname"] = SessionParsing.value(fields, keys: ["connection.host", "host"])
            mapped["port"] = SessionParsing.value(fields, keys: ["connection.port", "port"])
            mapped["username"] = SessionParsing.value(
                fields,
                keys: ["connectionauthentication.username", "username", "user"]
            )
            mapped["authentication"] = SessionParsing.value(
                fields,
                keys: ["connectionauthentication.method", "method"]
            )
            mapped["identityfile"] = SessionParsing.value(
                fields,
                keys: ["connectionauthentication.userkey", "userkey", "identityfile"]
            )
            candidates.append(SessionParsing.candidate(
                fields: mapped.compactMapValues { $0 },
                source: source,
                path: file.path,
                fallbackName: URL(fileURLWithPath: file.name).deletingPathExtension().lastPathComponent,
                fallbackGroup: SessionParsing.pathGroup(file.path)
            ))
        }
        return SessionAdapterInspection(candidates: candidates)
    }

    func render(
        _ records: [SessionTransferRecord],
        options: SessionExportOptions
    ) throws -> SessionExportArtifact {
        var entries: [(path: String, data: Data)] = []
        var usedPaths = Set<String>()
        for (index, record) in records.enumerated() {
            try Task.checkCancellation()
            let group = SessionParsing.safeFileComponent(record.group ?? "Sessions", fallback: "Sessions")
            let base = SessionParsing.safeFileComponent(record.name, fallback: "session-\(index + 1)")
            var path = "XShell/\(group)/\(base).xsh"
            var suffix = 2
            while usedPaths.contains(path.lowercased()) {
                path = "XShell/\(group)/\(base)-\(suffix).xsh"
                suffix += 1
            }
            usedPaths.insert(path.lowercased())
            let method: String
            switch record.authentication {
            case .password: method = "Password"
            case .privateKey: method = "PublicKey"
            case .keyThenPassword: method = "PublicKey,Password"
            case .unspecified: method = "PublicKey"
            }
            var lines = [
                "[CONNECTION]",
                "Host=\(SessionParsing.safeLine(record.host))",
                "Port=\(record.port)",
                "Protocol=SSH",
                "",
                "[CONNECTION:AUTHENTICATION]",
                "UserName=\(SessionParsing.safeLine(record.username))",
                "Method=\(method)"
            ]
            if let key = record.externalPrivateKeyPath, !key.isEmpty {
                lines.append("UserKey=\(SessionParsing.safeLine(key))")
            }
            lines.append(contentsOf: ["", "[SESSION_INFO]", "Name=\(SessionParsing.safeLine(record.name))", ""])
            entries.append((path, Data(lines.joined(separator: "\r\n").utf8)))
        }
        return SessionExportArtifact(
            suggestedFileName: "ServerDash-XShell.zip",
            data: try SessionArchiveWriter.makeArchive(entries: entries),
            warnings: SessionExportWarningBuilder.warnings(for: records)
        )
    }
}

struct SecureCRTSessionAdapter: SessionImportAdapter, SessionExportAdapter {
    let source: SessionTransferSource = .secureCRT
    let target: SessionTransferTarget = .secureCRT

    func confidence(for file: SessionSourceFile) -> Int {
        guard let text = SessionTextDecoder.decode(file.data) else { return 0 }
        let lower = text.lowercased()
        if file.pathExtension == "xml", lower.contains("vandyke") || lower.contains("securecrt") { return 100 }
        if lower.contains("s:\"hostname\"") || lower.contains("d:\"[ssh2] port\"") { return 95 }
        if ["csv", "tsv", "txt"].contains(file.pathExtension),
           lower.contains("hostname") || lower.contains("hostname/ip address") {
            return 80
        }
        return 0
    }

    func inspect(_ files: [SessionSourceFile]) throws -> SessionAdapterInspection {
        var candidates: [SessionImportCandidate] = []
        var warnings: [String] = []
        for file in files where confidence(for: file) > 0 {
            try Task.checkCancellation()
            guard let text = SessionTextDecoder.decode(file.data) else { continue }
            switch file.pathExtension {
            case "xml":
                let dictionaries = XMLSessionTreeParser.parse(data: file.data)
                for (index, dictionary) in dictionaries.enumerated() {
                    candidates.append(SessionParsing.candidate(
                        fields: dictionary,
                        source: source,
                        path: file.path,
                        fallbackName: SessionParsing.value(
                            SessionParsing.normalizedFields(dictionary), keys: ["session", "name"]
                        ) ?? "SecureCRT \(index + 1)",
                        fallbackGroup: SessionParsing.pathGroup(file.path)
                    ))
                }
                if dictionaries.isEmpty { warnings.append("未从 \(file.name) 识别出 SecureCRT 会话") }
            case "csv", "tsv", "txt":
                for fields in SessionParsing.parseCSV(text) {
                    candidates.append(SessionParsing.candidate(
                        fields: fields,
                        source: source,
                        path: file.path,
                        fallbackName: "SecureCRT 会话",
                        allowPlaintextPassword: true
                    ))
                }
            default:
                let lowerName = file.name.lowercased()
                guard lowerName != "default.ini", lowerName != "__folderdata__.ini" else { continue }
                var fields = SessionParsing.merge(SessionParsing.parseINI(text))
                if let rawPort = SessionParsing.value(fields, keys: ["ssh2port", "port"]),
                   rawPort.count == 8, rawPort.allSatisfy({ $0.isHexDigit }),
                   let port = Int(rawPort, radix: 16) {
                    fields["port"] = String(port)
                }
                candidates.append(SessionParsing.candidate(
                    fields: fields,
                    source: source,
                    path: file.path,
                    fallbackName: URL(fileURLWithPath: file.name).deletingPathExtension().lastPathComponent,
                    fallbackGroup: SessionParsing.pathGroup(file.path)
                ))
            }
        }
        return SessionAdapterInspection(candidates: candidates, warnings: warnings)
    }

    /// This renderer is intentionally reachable only from compatibility tests. The production
    /// migration service gates SecureCRT export until a generated file passes a real 9.6+ import.
    func render(
        _ records: [SessionTransferRecord],
        options: SessionExportOptions
    ) throws -> SessionExportArtifact {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += "<VanDyke version=\"3\" product=\"SecureCRT\">\n  <Sessions>\n"
        for record in records {
            try Task.checkCancellation()
            xml += "    <Session name=\"\(xmlEscaped(record.name))\">\n"
            xml += "      <string name=\"Hostname\">\(xmlEscaped(record.host))</string>\n"
            xml += "      <dword name=\"[SSH2] Port\">\(record.port)</dword>\n"
            xml += "      <string name=\"Username\">\(xmlEscaped(record.username))</string>\n"
            xml += "      <string name=\"Protocol Name\">SSH2</string>\n"
            if let key = record.externalPrivateKeyPath, !key.isEmpty {
                xml += "      <string name=\"Identity Filename V2\">\(xmlEscaped(key))</string>\n"
            }
            if let group = record.group, !group.isEmpty {
                xml += "      <string name=\"Folder\">\(xmlEscaped(group))</string>\n"
            }
            xml += "    </Session>\n"
        }
        xml += "  </Sessions>\n</VanDyke>\n"
        return SessionExportArtifact(
            suggestedFileName: "ServerDash-SecureCRT.xml",
            data: Data(xml.utf8),
            warnings: ["此格式必须先通过 SecureCRT 9.6+ 实机导入验证。"]
                + SessionExportWarningBuilder.warnings(for: records)
        )
    }
}

private final class XMLTreeNode {
    let name: String
    let attributes: [String: String]
    var text = ""
    var children: [XMLTreeNode] = []

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    func flattenedFields() -> [String: String] {
        var result = attributes.filter { !["name", "key"].contains($0.key.lowercased()) }
        let ownKey = attributes["name"] ?? attributes["key"] ?? name
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanText.isEmpty {
            result[ownKey] = cleanText
        } else if !children.isEmpty || name.lowercased().contains("session") {
            result["name"] = ownKey
        }
        for child in children {
            for (key, value) in child.flattenedFields() { result[key] = value }
        }
        return result
    }
}

private final class XMLSessionTreeParser: NSObject, XMLParserDelegate {
    private let root = XMLTreeNode(name: "root", attributes: [:])
    private var stack: [XMLTreeNode] = []

    static func parse(data: Data) -> [[String: String]] {
        let delegate = XMLSessionTreeParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { return [] }
        var matches: [[String: String]] = []
        delegate.collectLeafSessions(node: delegate.root, matches: &matches)
        return matches
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let node = XMLTreeNode(name: elementName, attributes: attributeDict)
        (stack.last ?? root).children.append(node)
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        _ = stack.popLast()
    }

    private func collectLeafSessions(
        node: XMLTreeNode,
        matches: inout [[String: String]]
    ) {
        let fields = node.flattenedFields()
        let isSession = Self.containsSession(fields)
        let hasSessionChild = node.children.contains { Self.containsSession($0.flattenedFields()) }
        if isSession && !hasSessionChild {
            matches.append(fields)
            return
        }
        for child in node.children { collectLeafSessions(node: child, matches: &matches) }
    }

    private static func containsSession(_ fields: [String: String]) -> Bool {
        let normalized = SessionParsing.normalizedFields(fields)
        let hasHost = SessionParsing.value(normalized, keys: ["hostname", "host"]) != nil
        let hasCompanion = SessionParsing.value(normalized, keys: ["username", "port", "ssh2port"]) != nil
        return hasHost && hasCompanion
    }
}

struct MobaXtermSessionAdapter: SessionImportAdapter, SessionExportAdapter {
    let source: SessionTransferSource = .mobaXterm
    let target: SessionTransferTarget = .mobaXterm

    func confidence(for file: SessionSourceFile) -> Int {
        if file.pathExtension == "mxtsessions" || file.name.lowercased() == "mobaxterm.ini" { return 100 }
        guard let text = SessionTextDecoder.decode(file.data) else { return 0 }
        return text.contains("#109#") && text.localizedCaseInsensitiveContains("[Bookmarks") ? 85 : 0
    }

    func inspect(_ files: [SessionSourceFile]) throws -> SessionAdapterInspection {
        var candidates: [SessionImportCandidate] = []
        var warnings: [String] = []
        for file in files where confidence(for: file) > 0 {
            try Task.checkCancellation()
            guard let text = SessionTextDecoder.decode(file.data) else { continue }
            for section in SessionParsing.parseINI(text) where section.name.lowercased().hasPrefix("bookmarks") {
                let group = section.values.first { SessionParsing.normalizedKey($0.key) == "subrep" }?.value
                for (name, rawValue) in section.values {
                    let key = SessionParsing.normalizedKey(name)
                    guard key != "subrep", key != "imgnum" else { continue }
                    guard let fields = parseBookmark(rawValue) else {
                        warnings.append("已跳过非 SSH/SFTP 或无法识别的 MobaXterm 会话：\(name)")
                        continue
                    }
                    var mapped = fields
                    mapped["name"] = name
                    mapped["group"] = group
                    candidates.append(SessionParsing.candidate(
                        fields: mapped.compactMapValues { $0 },
                        source: source,
                        path: file.path,
                        fallbackName: name,
                        fallbackGroup: group,
                        additionalWarnings: rawValue.localizedCaseInsensitiveContains("password")
                            ? ["已忽略 MobaXterm 凭据字段"] : []
                    ))
                }
            }
        }
        return SessionAdapterInspection(candidates: candidates, warnings: Array(Set(warnings)).sorted())
    }

    func render(
        _ records: [SessionTransferRecord],
        options: SessionExportOptions
    ) throws -> SessionExportArtifact {
        let groups = Dictionary(grouping: records, by: { $0.group ?? "ServerDash" })
        var lines: [String] = ["[MobaXterm sessions]", "ImgNum=42", ""]
        for (sectionIndex, group) in groups.keys.sorted().enumerated() {
            try Task.checkCancellation()
            lines.append(sectionIndex == 0 ? "[Bookmarks]" : "[Bookmarks_\(sectionIndex + 1)]")
            lines.append("SubRep=\(SessionParsing.safeLine(group))")
            lines.append("ImgNum=42")
            for record in groups[group, default: []] {
                try Task.checkCancellation()
                let name = SessionParsing.safeLine(record.name).replacingOccurrences(of: "=", with: "-")
                let host = percentSafe(record.host)
                let user = percentSafe(record.username)
                lines.append("\(name)=#109#0%\(host)%\(record.port)%\(user)%%-1%-1%%%%%0%0%0%%%-1%0%0%0%%1080%%0%0%1#")
            }
            lines.append("")
        }
        return SessionExportArtifact(
            suggestedFileName: "ServerDash.mxtsessions",
            data: Data(lines.joined(separator: "\r\n").utf8),
            warnings: SessionExportWarningBuilder.warnings(for: records)
        )
    }

    private func parseBookmark(_ value: String) -> [String: String?]? {
        guard let marker = value.range(of: "#109#"),
              let percent = value[marker.upperBound...].firstIndex(of: "%") else { return nil }
        let body = value[value.index(after: percent)...]
        let parts = body.split(separator: "%", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3 else { return nil }
        return ["host": percentDecoded(parts[0]), "port": parts[1], "username": percentDecoded(parts[2]),
                "protocol": "SSH"]
    }
}

struct FinalShellSessionAdapter: SessionImportAdapter, SessionExportAdapter {
    let source: SessionTransferSource = .finalShell
    let target: SessionTransferTarget = .finalShell

    func confidence(for file: SessionSourceFile) -> Int {
        guard file.pathExtension == "json",
              let object = try? JSONSerialization.jsonObject(with: file.data),
              let dictionary = object as? [String: Any] else { return 0 }
        let path = file.path.lowercased()
        let keys = Set(dictionary.keys.map(SessionParsing.normalizedKey))
        let rawKeys = Set(dictionary.keys.map { $0.lowercased() })
        if path.contains("/conn/") || path.hasPrefix("conn/") { return 95 }
        if keys.contains("host"),
           rawKeys.contains("user_name") || rawKeys.contains("authentication_type")
                || keys.contains("authenticationtype") {
            return 80
        }
        if keys.contains("host"), keys.contains("username") {
            // Generic JSON can also be XTerminal. Keep this score below the XTerminal
            // signature so automatic detection does not steal its exports.
            return 35
        }
        return 0
    }

    func inspect(_ files: [SessionSourceFile]) throws -> SessionAdapterInspection {
        var candidates: [SessionImportCandidate] = []
        var warnings: [String] = []
        for file in files where confidence(for: file) > 0 {
            try Task.checkCancellation()
            guard let object = try? JSONSerialization.jsonObject(with: file.data) else {
                warnings.append("无法解析：\(file.path)")
                continue
            }
            for (index, dictionary) in SessionParsing.jsonSessionDictionaries(object).enumerated() {
                var fields = SessionParsing.stringFields(dictionary)
                if fields["username"] == nil, let value = fields["user_name"] { fields["username"] = value }
                let normalized = SessionParsing.normalizedFields(fields)
                if let authType = SessionParsing.value(normalized, keys: ["authenticationtype"]) {
                    fields["authentication"] = authType == "0" ? "password" : "privateKey"
                }
                candidates.append(SessionParsing.candidate(
                    fields: fields,
                    source: source,
                    path: file.path,
                    fallbackName: URL(fileURLWithPath: file.name).deletingPathExtension().lastPathComponent
                        + (index == 0 ? "" : " \(index + 1)"),
                    fallbackGroup: SessionParsing.pathGroup(file.path),
                    additionalWarnings: ["FinalShell 专有凭据不会被解密"]
                ))
            }
        }
        return SessionAdapterInspection(candidates: candidates, warnings: warnings)
    }

    /// Kept behind SessionTransferTarget.exportAvailability until a real FinalShell import passes.
    func render(
        _ records: [SessionTransferRecord],
        options: SessionExportOptions
    ) throws -> SessionExportArtifact {
        var entries: [(path: String, data: Data)] = []
        for (index, record) in records.enumerated() {
            try Task.checkCancellation()
            var object: [String: Any] = [
                "name": record.name,
                "host": record.host,
                "port": record.port,
                "user_name": record.username,
                "authentication_type": record.authentication == .password ? 0 : 1
            ]
            if let group = record.group { object["group"] = group }
            if let notes = record.notes { object["remark"] = notes }
            if let path = record.externalPrivateKeyPath { object["private_key"] = path }
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            let name = SessionParsing.safeFileComponent(record.name, fallback: "session-\(index + 1)")
            entries.append(("conn/\(name)-\(index + 1).json", data))
        }
        return SessionExportArtifact(
            suggestedFileName: "ServerDash-FinalShell.zip",
            data: try SessionArchiveWriter.makeArchive(entries: entries),
            warnings: ["此格式必须先通过 FinalShell 3.9–4.6 实机导入验证。"]
                + SessionExportWarningBuilder.warnings(for: records)
        )
    }
}

struct XTerminalSessionAdapter: SessionImportAdapter, SessionExportAdapter {
    let source: SessionTransferSource = .xTerminal
    let target: SessionTransferTarget = .xTerminal

    func confidence(for file: SessionSourceFile) -> Int {
        guard let text = SessionTextDecoder.decode(file.data) else { return 0 }
        if file.pathExtension == "json",
           let object = try? JSONSerialization.jsonObject(with: file.data),
           !SessionParsing.jsonSessionDictionaries(object).isEmpty {
            return 65
        }
        let lower = text.lowercased()
        if lower.contains("host=") { return 55 }
        if text.contains("|"), SessionParsing.logicalLines(text).contains(where: { $0.split(separator: "|").count >= 3 }) {
            return 45
        }
        return 0
    }

    func inspect(_ files: [SessionSourceFile]) throws -> SessionAdapterInspection {
        var candidates: [SessionImportCandidate] = []
        for file in files where confidence(for: file) > 0 {
            try Task.checkCancellation()
            if file.pathExtension == "json",
               let object = try? JSONSerialization.jsonObject(with: file.data) {
                for (index, dictionary) in SessionParsing.jsonSessionDictionaries(object).enumerated() {
                    candidates.append(SessionParsing.candidate(
                        fields: SessionParsing.stringFields(dictionary),
                        source: source,
                        path: file.path,
                        fallbackName: "XTerminal \(index + 1)",
                        allowPlaintextPassword: true
                    ))
                }
                continue
            }
            guard let text = SessionTextDecoder.decode(file.data) else { continue }
            candidates.append(contentsOf: try parseText(text, path: file.path))
        }
        return SessionAdapterInspection(candidates: candidates)
    }

    func render(
        _ records: [SessionTransferRecord],
        options: SessionExportOptions
    ) throws -> SessionExportArtifact {
        let objects: [[String: Any]] = try records.map { record in
            try Task.checkCancellation()
            var object: [String: Any] = [
                "title": record.name,
                "host": record.host,
                "port": record.port,
                "username": record.username,
                "auth": xTerminalAuth(record.authentication)
            ]
            if let group = record.group { object["folder"] = group }
            if let note = record.notes { object["note"] = note }
            if let path = record.defaultRemotePath { object["defaultPath"] = path }
            if let key = record.externalPrivateKeyPath { object["privateKey"] = key }
            return object
        }
        let data = try JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return SessionExportArtifact(
            suggestedFileName: "ServerDash-XTerminal.json",
            data: data,
            warnings: SessionExportWarningBuilder.warnings(for: records)
        )
    }

    private func parseText(_ text: String, path: String) throws -> [SessionImportCandidate] {
        var candidates: [SessionImportCandidate] = []
        for (index, line) in SessionParsing.logicalLines(text).enumerated() {
            try Task.checkCancellation()
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("//") {
                continue
            }
            let parts = trimmed.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let fields: [String: String]
            if parts.count >= 3 {
                if parts[0].lowercased().contains("host"), parts[1].lowercased().contains("user") {
                    continue
                }
                let endpoint = parseEndpoint(parts[0])
                var mapped: [String: String] = [
                    "host": endpoint.host,
                    "username": parts[safe: 1]?.isEmpty == false ? parts[1] : (endpoint.username ?? "")
                ]
                if let port = endpoint.port { mapped["port"] = String(port) }
                if let password = parts[safe: 2], !password.isEmpty { mapped["password"] = password }
                if let title = parts[safe: 3], !title.isEmpty { mapped["title"] = title }
                if let note = parts[safe: 4], !note.isEmpty { mapped["note"] = note }
                fields = mapped
            } else {
                fields = keyValueFields(trimmed)
            }
            guard !fields.isEmpty else { continue }
            candidates.append(SessionParsing.candidate(
                fields: fields,
                source: source,
                path: path,
                fallbackName: "XTerminal \(index + 1)",
                allowPlaintextPassword: true
            ))
        }
        return candidates
    }

    private func parseEndpoint(_ value: String) -> (host: String, port: Int?, username: String?) {
        var endpoint = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: endpoint), components.scheme?.lowercased() == "ssh" {
            return (components.host ?? endpoint, components.port, components.user)
        }
        var username: String?
        if let separator = endpoint.lastIndex(of: "@") {
            username = String(endpoint[..<separator])
            endpoint = String(endpoint[endpoint.index(after: separator)...])
        }
        if endpoint.hasPrefix("["), let closing = endpoint.firstIndex(of: "]") {
            let host = String(endpoint[endpoint.index(after: endpoint.startIndex)..<closing])
            let suffix = endpoint[endpoint.index(after: closing)...]
            let port = suffix.hasPrefix(":") ? SessionParsing.parsePort(String(suffix.dropFirst())) : nil
            return (host, port, username)
        }
        if endpoint.filter({ $0 == ":" }).count == 1,
           let separator = endpoint.lastIndex(of: ":"),
           let port = SessionParsing.parsePort(String(endpoint[endpoint.index(after: separator)...])) {
            return (String(endpoint[..<separator]), port, username)
        }
        return (endpoint, nil, username)
    }

    private func keyValueFields(_ line: String) -> [String: String] {
        let characters = Array(line)
        var fields: [String: String] = [:]
        var index = 0
        while index < characters.count {
            while index < characters.count, characters[index].isWhitespace { index += 1 }
            let keyStart = index
            while index < characters.count, !characters[index].isWhitespace, characters[index] != "=" {
                index += 1
            }
            let key = String(characters[keyStart..<index])
            while index < characters.count, characters[index].isWhitespace { index += 1 }
            guard !key.isEmpty, index < characters.count, characters[index] == "=" else {
                while index < characters.count, !characters[index].isWhitespace { index += 1 }
                continue
            }
            index += 1
            while index < characters.count, characters[index].isWhitespace { index += 1 }
            var value = ""
            if index < characters.count, characters[index] == "\"" || characters[index] == "'" {
                let quote = characters[index]
                index += 1
                while index < characters.count, characters[index] != quote {
                    if characters[index] == "\\", index + 1 < characters.count,
                       characters[index + 1] == quote || characters[index + 1] == "\\" {
                        index += 1
                    }
                    value.append(characters[index])
                    index += 1
                }
                if index < characters.count { index += 1 }
            } else {
                while index < characters.count, !characters[index].isWhitespace {
                    value.append(characters[index])
                    index += 1
                }
            }
            fields[key] = value
        }
        return fields
    }
}

struct PuTTYSessionAdapter: SessionImportAdapter, SessionExportAdapter {
    let source: SessionTransferSource = .putty
    let target: SessionTransferTarget = .putty

    func confidence(for file: SessionSourceFile) -> Int {
        guard let text = SessionTextDecoder.decode(file.data) else { return 0 }
        let lower = text.lowercased()
        if file.pathExtension == "reg", lower.contains("\\putty\\sessions\\") { return 100 }
        if lower.contains("hostname=") && lower.contains("portnumber=") { return 75 }
        return 0
    }

    func inspect(_ files: [SessionSourceFile]) throws -> SessionAdapterInspection {
        var candidates: [SessionImportCandidate] = []
        for file in files where confidence(for: file) > 0 {
            try Task.checkCancellation()
            guard let text = SessionTextDecoder.decode(file.data) else { continue }
            if file.pathExtension == "reg" || text.localizedCaseInsensitiveContains("Windows Registry Editor") {
                for section in parseRegistry(text) {
                    candidates.append(SessionParsing.candidate(
                        fields: section.fields,
                        source: source,
                        path: file.path,
                        fallbackName: section.name,
                        fallbackGroup: SessionParsing.pathGroup(file.path)
                    ))
                }
            } else {
                let fields = SessionParsing.merge(SessionParsing.parseINI(text))
                candidates.append(SessionParsing.candidate(
                    fields: fields,
                    source: source,
                    path: file.path,
                    fallbackName: percentDecoded(file.name),
                    fallbackGroup: SessionParsing.pathGroup(file.path)
                ))
            }
        }
        return SessionAdapterInspection(candidates: candidates)
    }

    func render(
        _ records: [SessionTransferRecord],
        options: SessionExportOptions
    ) throws -> SessionExportArtifact {
        var lines = ["Windows Registry Editor Version 5.00", ""]
        var usedNames = Set<String>()
        for (index, record) in records.enumerated() {
            try Task.checkCancellation()
            var name = puttySessionName(record.name.isEmpty ? "Session \(index + 1)" : record.name)
            var suffix = 2
            while usedNames.contains(name.lowercased()) {
                name = puttySessionName("\(record.name) (\(suffix))")
                suffix += 1
            }
            usedNames.insert(name.lowercased())
            lines.append("[HKEY_CURRENT_USER\\Software\\SimonTatham\\PuTTY\\Sessions\\\(name)]")
            lines.append("\"HostName\"=\"\(registryEscaped(record.host))\"")
            lines.append(String(format: "\"PortNumber\"=dword:%08x", record.port))
            lines.append("\"UserName\"=\"\(registryEscaped(record.username))\"")
            lines.append("\"Protocol\"=\"ssh\"")
            if let key = record.externalPrivateKeyPath, !key.isEmpty {
                lines.append("\"PublicKeyFile\"=\"\(registryEscaped(key))\"")
            }
            lines.append("")
        }
        let body = lines.joined(separator: "\r\n")
        var data = Data([0xFF, 0xFE])
        data.append(body.data(using: .utf16LittleEndian) ?? Data())
        return SessionExportArtifact(
            suggestedFileName: "ServerDash-PuTTY.reg",
            data: data,
            warnings: SessionExportWarningBuilder.warnings(for: records)
        )
    }

    private func parseRegistry(_ text: String) -> [(name: String, fields: [String: String])] {
        var result: [(String, [String: String])] = []
        var currentName: String?
        var fields: [String: String] = [:]
        func appendCurrent() {
            if let currentName, !fields.isEmpty { result.append((currentName, fields)) }
        }
        for rawLine in SessionParsing.logicalLines(text) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("["), line.hasSuffix("]") {
                appendCurrent()
                fields = [:]
                let path = String(line.dropFirst().dropLast())
                guard let range = path.range(of: "\\Sessions\\", options: [.caseInsensitive, .backwards]) else {
                    currentName = nil
                    continue
                }
                currentName = percentDecoded(String(path[range.upperBound...]))
                continue
            }
            guard currentName != nil, line.hasPrefix("\""), let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals]).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            let rawValue = String(line[line.index(after: equals)...])
            if rawValue.lowercased().hasPrefix("dword:") {
                let hex = rawValue.dropFirst("dword:".count)
                fields[key] = Int(hex, radix: 16).map(String.init)
            } else {
                fields[key] = registryUnescaped(rawValue)
            }
        }
        appendCurrent()
        return result
    }
}

struct ServerDashSessionAdapter: SessionImportAdapter, SessionExportAdapter {
    let source: SessionTransferSource = .serverDash
    let target: SessionTransferTarget = .serverDash

    func confidence(for file: SessionSourceFile) -> Int {
        guard file.pathExtension == "json",
              let text = SessionTextDecoder.decode(file.data) else { return 0 }
        return text.contains("com.serverdash.sessions") ? 110 : 0
    }

    func inspect(_ files: [SessionSourceFile]) throws -> SessionAdapterInspection {
        var candidates: [SessionImportCandidate] = []
        var warnings: [String] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for file in files where confidence(for: file) > 0 {
            try Task.checkCancellation()
            do {
                let document = try decoder.decode(ServerDashSessionDocument.self, from: file.data)
                guard document.format == "com.serverdash.sessions", document.version == 1 else {
                    warnings.append("不支持的 ServerDash 文件版本：\(file.name)")
                    continue
                }
                for record in document.sessions {
                    candidates.append(validatedCandidate(record: record, source: source, path: file.path))
                }
            } catch {
                warnings.append("无法解析 ServerDash 会话文件：\(file.name)")
            }
        }
        return SessionAdapterInspection(candidates: candidates, warnings: warnings)
    }

    func render(
        _ records: [SessionTransferRecord],
        options: SessionExportOptions
    ) throws -> SessionExportArtifact {
        try Task.checkCancellation()
        let document = ServerDashSessionDocument(
            exportedAt: options.generatedAt,
            generator: .init(version: options.appVersion),
            sessions: records
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return SessionExportArtifact(
            suggestedFileName: "ServerDash-Sessions.json",
            data: try encoder.encode(document),
            warnings: SessionExportWarningBuilder.warnings(for: records)
        )
    }
}

struct OpenSSHSessionAdapter: SessionImportAdapter, SessionExportAdapter {
    let source: SessionTransferSource = .openSSH
    let target: SessionTransferTarget = .openSSH

    func confidence(for file: SessionSourceFile) -> Int {
        guard let text = SessionTextDecoder.decode(file.data) else { return 0 }
        let lowerName = file.name.lowercased()
        if lowerName == "config" || file.pathExtension == "conf" || file.pathExtension == "sshconfig" {
            return text.range(of: #"(?im)^\s*Host\s+\S+"#, options: .regularExpression) != nil ? 90 : 0
        }
        return text.range(of: #"(?im)^\s*Host\s+\S+"#, options: .regularExpression) != nil ? 60 : 0
    }

    func inspect(_ files: [SessionSourceFile]) throws -> SessionAdapterInspection {
        var candidates: [SessionImportCandidate] = []
        var warnings: [String] = []
        for file in files where confidence(for: file) > 0 {
            try Task.checkCancellation()
            guard let text = SessionTextDecoder.decode(file.data) else { continue }
            let parsed = try parse(text, path: file.path)
            candidates.append(contentsOf: parsed.candidates)
            warnings.append(contentsOf: parsed.warnings)
        }
        return SessionAdapterInspection(candidates: candidates, warnings: warnings)
    }

    func render(
        _ records: [SessionTransferRecord],
        options: SessionExportOptions
    ) throws -> SessionExportArtifact {
        var blocks: [String] = ["# Generated by ServerDash \(options.appVersion)", "# Passwords and private-key data are intentionally omitted.", ""]
        var aliases = Set<String>()
        for (index, record) in records.enumerated() {
            try Task.checkCancellation()
            let base = sshAlias(record.name, fallback: "server-\(index + 1)")
            var alias = base
            var suffix = 2
            while aliases.contains(alias.lowercased()) {
                alias = "\(base)-\(suffix)"
                suffix += 1
            }
            aliases.insert(alias.lowercased())
            if let group = record.group, !group.isEmpty { blocks.append("# Group: \(sshComment(group))") }
            if let notes = record.notes, !notes.isEmpty { blocks.append("# Note: \(sshComment(notes))") }
            blocks.append("Host \(alias)")
            blocks.append("    HostName \(sshQuoted(record.host))")
            blocks.append("    Port \(record.port)")
            blocks.append("    User \(sshQuoted(record.username))")
            if let key = record.externalPrivateKeyPath, !key.isEmpty {
                blocks.append("    IdentityFile \(sshQuoted(key))")
            }
            blocks.append("")
        }
        return SessionExportArtifact(
            suggestedFileName: "ServerDash-SSH-Config.conf",
            data: Data(blocks.joined(separator: "\n").utf8),
            warnings: SessionExportWarningBuilder.warnings(for: records)
        )
    }

    private func parse(_ text: String, path: String) throws -> SessionAdapterInspection {
        struct Block {
            var aliases: [String]
            var fields: [String: String]
            var warnings: [String]
        }
        var blocks: [Block] = []
        var current: Block?
        var globalWarnings: [String] = []
        for rawLine in SessionParsing.logicalLines(text) {
            try Task.checkCancellation()
            let uncommented = stripSSHComment(rawLine)
            let tokens = sshTokens(uncommented)
            guard let keyword = tokens.first?.lowercased() else { continue }
            if keyword == "host" {
                if let current { blocks.append(current) }
                let aliases = tokens.dropFirst().filter { !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") }
                current = aliases.isEmpty ? nil : Block(aliases: Array(aliases), fields: [:], warnings: [])
                continue
            }
            if keyword == "include" {
                globalWarnings.append("批量导入不会展开 Include；请直接选择被包含的文件")
                continue
            }
            if keyword == "match" {
                if let current { blocks.append(current) }
                current = nil
                globalWarnings.append("已跳过 Match 条件块；请在预览中检查主机字段")
                continue
            }
            guard current != nil, tokens.count >= 2 else { continue }
            let value = tokens.dropFirst().joined(separator: " ")
            switch keyword {
            case "hostname": current?.fields["hostname"] = value
            case "port": current?.fields["port"] = value
            case "user": current?.fields["username"] = value
            case "identityfile":
                if current?.fields["identityfile"] == nil { current?.fields["identityfile"] = value }
            case "proxyjump", "proxycommand":
                current?.warnings.append("已忽略跳板机或代理配置")
            case "remotecommand", "localforward", "remoteforward", "dynamicforward":
                current?.warnings.append("已忽略命令或端口转发配置")
            default: break
            }
        }
        if let current { blocks.append(current) }

        var candidates: [SessionImportCandidate] = []
        for block in blocks {
            for alias in block.aliases {
                var fields = block.fields
                fields["hostname"] = fields["hostname"] ?? alias
                fields["name"] = alias
                fields["authentication"] = fields["identityfile"] == nil ? "" : "publickey"
                candidates.append(SessionParsing.candidate(
                    fields: fields,
                    source: source,
                    path: path,
                    fallbackName: alias,
                    fallbackGroup: SessionParsing.pathGroup(path),
                    additionalWarnings: Array(Set(block.warnings)).sorted()
                ))
            }
        }
        return SessionAdapterInspection(candidates: candidates, warnings: Array(Set(globalWarnings)).sorted())
    }
}

private enum SessionExportWarningBuilder {
    static func warnings(for records: [SessionTransferRecord]) -> [String] {
        var warnings: [String] = []
        if records.contains(where: { $0.authentication == .password || $0.authentication == .keyThenPassword }) {
            warnings.append("密码不会写入导出文件，请在目标客户端重新配置。")
        }
        if records.contains(where: {
            ($0.authentication == .privateKey || $0.authentication == .keyThenPassword)
                && $0.externalPrivateKeyPath?.isEmpty != false
        }) {
            warnings.append("Keychain 私钥不会导出，请在目标客户端重新导入密钥。")
        }
        return warnings
    }
}

private func validatedCandidate(
    record: SessionTransferRecord,
    source: SessionTransferSource,
    path: String
) -> SessionImportCandidate {
    var record = record
    record.name = cleanValue(record.name)
    record.host = cleanValue(record.host)
    record.username = cleanValue(record.username)
    let rawKeyPath = record.externalPrivateKeyPath
    record.externalPrivateKeyPath = SessionTransferSecurity.externalPrivateKeyPath(rawKeyPath)
    var warnings: [String] = []
    if rawKeyPath != nil, record.externalPrivateKeyPath == nil {
        warnings.append("已忽略嵌入式私钥正文，请在身份与密钥中单独导入")
    }
    var errors: [String] = []
    if record.host.isEmpty { errors.append("缺少主机地址") }
    if record.username.isEmpty { errors.append("缺少用户名") }
    if !(1...65_535).contains(record.port) { errors.append("端口无效") }
    return SessionImportCandidate(
        record: record,
        source: source,
        sourcePath: path,
        warnings: warnings,
        errors: errors
    )
}

private func xmlEscaped(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
}

private func percentSafe(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~:"))) ?? value
}

private func percentDecoded(_ value: String) -> String {
    value.removingPercentEncoding ?? value
}

private func xTerminalAuth(_ hint: AuthenticationHint) -> String {
    switch hint {
    case .password: "password"
    case .privateKey: "privateKey"
    case .keyThenPassword: "privateKey,password"
    case .unspecified: "none"
    }
}

private func registryEscaped(_ value: String) -> String {
    SessionParsing.safeLine(value)
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

private func registryUnescaped(_ value: String) -> String {
    var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if result.hasPrefix("\""), result.hasSuffix("\"") { result = String(result.dropFirst().dropLast()) }
    return result.replacingOccurrences(of: "\\\"", with: "\"")
        .replacingOccurrences(of: "\\\\", with: "\\")
}

private func puttySessionName(_ value: String) -> String {
    value.utf8.map { byte in
        let allowed = (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
            || (byte >= 0x61 && byte <= 0x7A) || [0x20, 0x2D, 0x2E, 0x5F].contains(byte)
        return allowed ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
    }.joined()
}

private func sshAlias(_ value: String, fallback: String) -> String {
    let normalized = value.lowercased().unicodeScalars.map { scalar -> String in
        CharacterSet.alphanumerics.contains(scalar) || "-_.".unicodeScalars.contains(scalar) ? String(scalar) : "-"
    }.joined()
    let trimmed = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
    return trimmed.isEmpty ? fallback : trimmed
}

private func sshQuoted(_ value: String) -> String {
    let safe = SessionParsing.safeLine(value)
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(safe)\""
}

private func sshComment(_ value: String) -> String {
    SessionParsing.safeLine(value).replacingOccurrences(of: "#", with: "")
}

private func stripSSHComment(_ line: String) -> String {
    var quoted = false
    var escaped = false
    var result = ""
    for character in line {
        if escaped { result.append(character); escaped = false; continue }
        if character == "\\" { result.append(character); escaped = true; continue }
        if character == "\"" { quoted.toggle(); result.append(character); continue }
        if character == "#", !quoted { break }
        result.append(character)
    }
    return result
}

private func sshTokens(_ line: String) -> [String] {
    var result: [String] = []
    var token = ""
    var quoted = false
    var escaped = false
    for character in line {
        if escaped { token.append(character); escaped = false; continue }
        if character == "\\" { escaped = true; continue }
        if character == "\"" { quoted.toggle(); continue }
        if character.isWhitespace, !quoted {
            if !token.isEmpty { result.append(token); token = "" }
        } else {
            token.append(character)
        }
    }
    if !token.isEmpty { result.append(token) }
    return result
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
