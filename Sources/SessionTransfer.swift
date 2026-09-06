import Foundation
import SwiftData
import ZIPFoundation

enum SessionTransferSource: String, CaseIterable, Identifiable, Codable, Sendable {
    case automatic
    case xShell
    case secureCRT
    case mobaXterm
    case finalShell
    case xTerminal
    case putty
    case serverDash
    case openSSH

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "自动识别"
        case .xShell: "XShell"
        case .secureCRT: "SecureCRT"
        case .mobaXterm: "MobaXterm"
        case .finalShell: "FinalShell"
        case .xTerminal: "XTerminal"
        case .putty: "PuTTY"
        case .serverDash: "ServerDash"
        case .openSSH: "OpenSSH Config"
        }
    }

    var subtitle: String {
        switch self {
        case .automatic: "根据文件名和内容判断来源"
        case .xShell: ".xsh 文件、文件夹或 ZIP"
        case .secureCRT: "XML、CSV 或 Sessions 配置目录"
        case .mobaXterm: "MobaXterm.ini 或 .mxtsessions"
        case .finalShell: "conn 配置目录或 ZIP"
        case .xTerminal: "JSON 或文本导出"
        case .putty: "Windows .reg 或 Unix sessions 目录"
        case .serverDash: "ServerDash 会话备份 JSON"
        case .openSSH: "OpenSSH config 文件"
        }
    }

    var symbol: String {
        switch self {
        case .automatic: "wand.and.stars"
        case .serverDash: "server.rack"
        case .openSSH: "terminal"
        case .putty: "shippingbox"
        default: "rectangle.connected.to.line.below"
        }
    }

    var supportsLocalDiscovery: Bool {
#if os(macOS)
        switch self {
        case .automatic, .secureCRT, .finalShell, .putty, .openSSH:
            true
        default:
            false
        }
#else
        false
#endif
    }
}

enum SessionTransferTarget: String, CaseIterable, Identifiable, Codable, Sendable {
    case xShell
    case secureCRT
    case mobaXterm
    case finalShell
    case xTerminal
    case putty
    case serverDash
    case openSSH

    var id: String { rawValue }

    var title: String {
        SessionTransferSource(rawValue: rawValue)?.title ?? rawValue
    }

    var subtitle: String {
        switch self {
        case .xShell: "生成不含密码的 .xsh 会话包"
        case .secureCRT: "SecureCRT 9.6+ XML（等待实机验证）"
        case .mobaXterm: "生成 .mxtsessions 会话文件"
        case .finalShell: "conn JSON 包（等待实机验证）"
        case .xTerminal: "生成 XTerminal JSON"
        case .putty: "生成 Windows 注册表 .reg"
        case .serverDash: "版本化、无凭据的通用 JSON"
        case .openSSH: "生成标准 SSH config"
        }
    }

    var suggestedExtension: String {
        switch self {
        case .xShell, .finalShell: "zip"
        case .secureCRT: "xml"
        case .mobaXterm: "mxtsessions"
        case .xTerminal, .serverDash: "json"
        case .putty: "reg"
        case .openSSH: "conf"
        }
    }

    var exportAvailability: SessionExportAvailability {
        switch self {
        case .secureCRT, .finalShell:
            .requiresExternalValidation
        default:
            .available
        }
    }
}

enum SessionExportAvailability: Sendable, Equatable {
    case available
    case requiresExternalValidation
}

enum AuthenticationHint: String, Codable, Sendable, CaseIterable {
    case password
    case privateKey
    case keyThenPassword
    case unspecified

    var title: String {
        switch self {
        case .password: "密码"
        case .privateKey: "SSH 私钥"
        case .keyThenPassword: "私钥优先，密码回退"
        case .unspecified: "未指定"
        }
    }

    var authenticationMethod: AuthenticationMethod {
        switch self {
        case .password: .password
        case .privateKey: .privateKey
        case .keyThenPassword: .keyThenPassword
        case .unspecified: .privateKey
        }
    }

    init(_ method: AuthenticationMethod) {
        switch method {
        case .password: self = .password
        case .privateKey: self = .privateKey
        case .keyThenPassword: self = .keyThenPassword
        }
    }
}

enum SessionTransferSecurity {
    static func externalPrivateKeyPath(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= 4_096,
              !value.contains("\0"),
              !value.contains("\n"),
              !value.contains("\r"),
              !value.localizedCaseInsensitiveContains("-----BEGIN") else {
            return nil
        }
        return value
    }
}

struct SessionTransferRecord: Codable, Sendable, Equatable {
    var name: String
    var group: String?
    var host: String
    var port: Int
    var username: String
    var authentication: AuthenticationHint
    var externalPrivateKeyPath: String?
    var notes: String?
    var tags: [String]
    var defaultRemotePath: String?

    init(
        name: String,
        group: String? = nil,
        host: String,
        port: Int = 22,
        username: String,
        authentication: AuthenticationHint = .unspecified,
        externalPrivateKeyPath: String? = nil,
        notes: String? = nil,
        tags: [String] = [],
        defaultRemotePath: String? = nil
    ) {
        self.name = name
        self.group = group
        self.host = host
        self.port = port
        self.username = username
        self.authentication = authentication
        self.externalPrivateKeyPath = externalPrivateKeyPath
        self.notes = notes
        self.tags = tags
        self.defaultRemotePath = defaultRemotePath
    }

    init(server: ServerRecord) {
        name = server.displayName
        group = server.groupName.isEmpty ? nil : server.groupName
        host = server.host.trimmingCharacters(in: .whitespacesAndNewlines)
        port = server.port
        username = server.username.trimmingCharacters(in: .whitespacesAndNewlines)
        authentication = AuthenticationHint(server.authentication)
#if os(macOS)
        externalPrivateKeyPath = server.identityID == nil
            ? SessionTransferSecurity.externalPrivateKeyPath(server.privateKeyPath)
            : nil
#else
        externalPrivateKeyPath = nil
#endif
        notes = server.notes.isEmpty ? nil : server.notes
        tags = server.tags
        defaultRemotePath = server.defaultSFTPPath == "." ? nil : server.defaultSFTPPath
    }
}

struct ServerDashSessionDocument: Codable, Sendable, Equatable {
    struct Generator: Codable, Sendable, Equatable {
        var name = "ServerDash"
        var version: String
    }

    var format = "com.serverdash.sessions"
    var version = 1
    var exportedAt: Date
    var generator: Generator
    var sessions: [SessionTransferRecord]
}

/// Deliberately does not conform to Codable or CustomStringConvertible. Secrets live only
/// for the lifetime of an import preview and are never included in diagnostics.
final class EphemeralSessionCredential: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPassword: String?

    init(password: String?) {
        let trimmed = password?.trimmingCharacters(in: .newlines)
        storedPassword = trimmed?.isEmpty == false ? trimmed : nil
    }

    var hasPassword: Bool {
        lock.withLock { storedPassword != nil }
    }

    func password() -> String? {
        lock.withLock { storedPassword }
    }

    func clear() {
        lock.withLock { storedPassword = nil }
    }

    deinit {
        storedPassword = nil
    }
}

struct SessionImportCandidate: Identifiable, @unchecked Sendable {
    let id: UUID
    var record: SessionTransferRecord
    let source: SessionTransferSource
    let sourcePath: String
    var warnings: [String]
    var errors: [String]
    let credential: EphemeralSessionCredential?
    var isDuplicate: Bool

    init(
        id: UUID = UUID(),
        record: SessionTransferRecord,
        source: SessionTransferSource,
        sourcePath: String,
        warnings: [String] = [],
        errors: [String] = [],
        credential: EphemeralSessionCredential? = nil,
        isDuplicate: Bool = false
    ) {
        self.id = id
        self.record = record
        self.source = source
        self.sourcePath = sourcePath
        self.warnings = warnings
        self.errors = errors
        self.credential = credential
        self.isDuplicate = isDuplicate
    }

    var isValid: Bool {
        errors.isEmpty && !record.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (1...65_535).contains(record.port)
    }

    var hasPlaintextPassword: Bool { credential?.hasPassword == true }

    var credentialStatus: String {
        if hasPlaintextPassword { return "检测到密码（已隐藏）" }
        if record.authentication == .privateKey || record.authentication == .keyThenPassword {
            return record.externalPrivateKeyPath?.isEmpty == false ? "引用外部私钥" : "凭据待配置"
        }
        return "凭据待配置"
    }
}

struct SessionImportPreview: @unchecked Sendable {
    var requestedSource: SessionTransferSource
    var detectedSources: [SessionTransferSource]
    var candidates: [SessionImportCandidate]
    var warnings: [String]

    var validCount: Int { candidates.count(where: \.isValid) }
    var duplicateCount: Int { candidates.count(where: \.isDuplicate) }
    var passwordCount: Int { candidates.count(where: \.hasPlaintextPassword) }
}

struct SessionImportSelection: @unchecked Sendable {
    var preview: SessionImportPreview
    var selectedIDs: Set<UUID>
    var duplicateOverrideIDs: Set<UUID> = []
    var identityMappingIDs: [UUID: UUID] = [:]
}

struct SessionImportResult: Sendable, Equatable {
    var importedCount: Int
    var skippedCount: Int
    var passwordCount: Int
}

enum SessionExportScope: String, CaseIterable, Identifiable, Sendable {
    case all
    case group
    case selected

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "全部"
        case .group: "分组"
        case .selected: "选择"
        }
    }
}

struct SessionExportOptions: Sendable, Equatable {
    var appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    var generatedAt: Date = .now
}

struct SessionExportArtifact: Sendable, Equatable {
    var suggestedFileName: String
    var data: Data
    var warnings: [String] = []
}

struct ExistingSessionKey: Hashable, Sendable {
    let host: String
    let port: Int
    let username: String

    init(host: String, port: Int, username: String) {
        self.host = Self.normalizedHost(host)
        self.port = port
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(server: ServerRecord) {
        self.init(host: server.host, port: server.port, username: server.username)
    }

    init(record: SessionTransferRecord) {
        self.init(host: record.host, port: record.port, username: record.username)
    }

    private static func normalizedHost(_ value: String) -> String {
        var host = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        while host.hasSuffix(".") { host.removeLast() }
        return host
    }
}

struct SessionSourceFile: Sendable, Equatable {
    var path: String
    var data: Data

    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var pathExtension: String { URL(fileURLWithPath: path).pathExtension.lowercased() }
}

enum SessionImportInput: @unchecked Sendable {
    case urls([URL])
    case files([SessionSourceFile])
}

struct SessionAdapterInspection: @unchecked Sendable {
    var candidates: [SessionImportCandidate]
    var warnings: [String] = []
}

protocol SessionImportAdapter: Sendable {
    var source: SessionTransferSource { get }
    func confidence(for file: SessionSourceFile) -> Int
    func inspect(_ files: [SessionSourceFile]) throws -> SessionAdapterInspection
}

protocol SessionExportAdapter: Sendable {
    var target: SessionTransferTarget { get }
    func render(
        _ records: [SessionTransferRecord],
        options: SessionExportOptions
    ) throws -> SessionExportArtifact
}

enum SessionMigrationError: LocalizedError, Equatable {
    case noInput
    case noSupportedSessions
    case unsupportedSource
    case unsupportedExport
    case exportRequiresValidation(String)
    case fileTooLarge(String)
    case archiveTooLarge
    case archiveEntryLimit
    case unsafeArchivePath(String)
    case symbolicLink(String)
    case unreadableFile(String)
    case invalidArchive
    case noSelection
    case credentialCleanupFailed

    var errorDescription: String? {
        switch self {
        case .noInput: "请选择配置文件或目录。"
        case .noSupportedSessions: "没有找到可导入的 SSH/SFTP 会话。"
        case .unsupportedSource: "无法识别所选文件的来源。"
        case .unsupportedExport: "暂不支持该导出格式。"
        case .exportRequiresValidation(let target): "\(target) 原生导出仍需目标客户端实机验证。"
        case .fileTooLarge(let name): "文件超过 16 MiB 限制：\(name)"
        case .archiveTooLarge: "ZIP 超过 64 MiB，或展开后超过 256 MiB。"
        case .archiveEntryLimit: "ZIP 项目数量超过 10,000。"
        case .unsafeArchivePath(let path): "ZIP 包含不安全路径：\(path)"
        case .symbolicLink(let path): "不允许导入符号链接：\(path)"
        case .unreadableFile(let name): "无法读取文件：\(name)"
        case .invalidArchive: "ZIP 文件损坏或格式不受支持。"
        case .noSelection: "请选择至少一个有效会话。"
        case .credentialCleanupFailed: "导入已回滚，但本机 Keychain 凭据清理失败，请在重试前检查系统钥匙串。"
        }
    }
}

actor SessionMigrationService {
    static let shared = SessionMigrationService()

    private let importers: [any SessionImportAdapter]
    private let exporters: [any SessionExportAdapter]

    init(
        importers: [any SessionImportAdapter] = SessionAdapterRegistry.importers,
        exporters: [any SessionExportAdapter] = SessionAdapterRegistry.exporters
    ) {
        self.importers = importers
        self.exporters = exporters
    }

    func preview(
        source: SessionTransferSource,
        input: SessionImportInput,
        existing: [ExistingSessionKey]
    ) throws -> SessionImportPreview {
        let files = try SessionImportFileLoader.load(input)
        guard !files.isEmpty else { throw SessionMigrationError.noInput }

        var candidates: [SessionImportCandidate] = []
        var warnings: [String] = []
        var detected: [SessionTransferSource] = []

        if source == .automatic {
            var assignments: [SessionTransferSource: [SessionSourceFile]] = [:]
            for file in files {
                try Task.checkCancellation()
                guard let importer = importers
                    .map({ ($0, $0.confidence(for: file)) })
                    .filter({ $0.1 > 0 })
                    .max(by: { $0.1 < $1.1 })?.0 else {
                    warnings.append("无法识别：\(file.path)")
                    continue
                }
                assignments[importer.source, default: []].append(file)
            }
            for importer in importers where assignments[importer.source] != nil {
                try Task.checkCancellation()
                let result = try importer.inspect(assignments[importer.source] ?? [])
                candidates.append(contentsOf: result.candidates)
                warnings.append(contentsOf: result.warnings)
                detected.append(importer.source)
            }
        } else {
            guard let importer = importers.first(where: { $0.source == source }) else {
                throw SessionMigrationError.unsupportedSource
            }
            let result = try importer.inspect(files)
            candidates = result.candidates
            warnings = result.warnings
            detected = [source]
        }

        let existingSet = Set(existing)
        var seen = existingSet
        for index in candidates.indices {
            let key = ExistingSessionKey(record: candidates[index].record)
            if seen.contains(key) {
                candidates[index].isDuplicate = true
                if !candidates[index].warnings.contains("与现有或本批会话重复") {
                    candidates[index].warnings.append("与现有或本批会话重复")
                }
            } else if candidates[index].isValid {
                seen.insert(key)
            }
        }

        guard !candidates.isEmpty || !warnings.isEmpty else {
            throw SessionMigrationError.noSupportedSessions
        }
        return SessionImportPreview(
            requestedSource: source,
            detectedSources: Array(Set(detected)).sorted(by: { $0.title < $1.title }),
            candidates: candidates,
            warnings: warnings
        )
    }

    func export(
        records: [SessionTransferRecord],
        target: SessionTransferTarget,
        options: SessionExportOptions = .init()
    ) throws -> SessionExportArtifact {
        try Task.checkCancellation()
        guard !records.isEmpty else { throw SessionMigrationError.noSelection }
        guard records.count <= SessionImportFileLoader.maxArchiveEntries else {
            throw SessionMigrationError.archiveEntryLimit
        }
        guard target.exportAvailability == .available else {
            throw SessionMigrationError.exportRequiresValidation(target.title)
        }
        guard let exporter = exporters.first(where: { $0.target == target }) else {
            throw SessionMigrationError.unsupportedExport
        }
        var omittedEmbeddedKey = false
        let sanitized = records.map { record in
            var record = record
            let rawPath = record.externalPrivateKeyPath
            record.externalPrivateKeyPath = SessionTransferSecurity.externalPrivateKeyPath(rawPath)
            if rawPath != nil, record.externalPrivateKeyPath == nil {
                omittedEmbeddedKey = true
            }
            return record
        }
        var artifact = try exporter.render(sanitized, options: options)
        try Task.checkCancellation()
        let outputLimit = target.suggestedExtension == "zip"
            ? SessionImportFileLoader.maxArchiveBytes
            : SessionImportFileLoader.maxFileBytes
        guard artifact.data.count <= outputLimit else {
            throw target.suggestedExtension == "zip"
                ? SessionMigrationError.archiveTooLarge
                : SessionMigrationError.fileTooLarge(artifact.suggestedFileName)
        }
        if omittedEmbeddedKey {
            artifact.warnings.append("已阻止将私钥正文写入导出文件，请在目标客户端重新导入密钥。")
        }
        return artifact
    }
}

@MainActor
enum SessionImportCommitter {
    static func commit(
        _ selection: SessionImportSelection,
        importPlaintextPasswords: Bool,
        existingServers: [ServerRecord],
        existingIdentities: [IdentityRecord] = [],
        credentialStore: SessionImportCredentialStore = .keychain,
        context: ModelContext
    ) throws -> SessionImportResult {
        defer { selection.preview.candidates.forEach { $0.credential?.clear() } }

        let candidates = selection.preview.candidates.filter { candidate in
            selection.selectedIDs.contains(candidate.id)
                && candidate.isValid
                && (!candidate.isDuplicate || selection.duplicateOverrideIDs.contains(candidate.id))
        }
        guard !candidates.isEmpty else { throw SessionMigrationError.noSelection }

        var usedNames = Set(existingServers.map { $0.displayName.lowercased() })
        var inserted: [ServerRecord] = []
        var passwordIDs: [UUID] = []
        do {
            for candidate in candidates {
                let record = candidate.record
                let id = UUID()
                let mappedIdentity = selection.identityMappingIDs[candidate.id].flatMap { identityID in
                    existingIdentities.first(where: { $0.id == identityID })
                }
                let baseName = record.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? record.host : record.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let name = uniqueName(baseName, usedNames: &usedNames)
                let keyPath = usableExternalKeyPath(record.externalPrivateKeyPath)
                let server = ServerRecord(
                    id: id,
                    name: name,
                    host: record.host.trimmingCharacters(in: .whitespacesAndNewlines),
                    port: record.port,
                    username: mappedIdentity?.username.trimmingCharacters(in: .whitespacesAndNewlines)
                        ?? record.username.trimmingCharacters(in: .whitespacesAndNewlines),
                    authentication: mappedIdentity?.authentication ?? record.authentication.authenticationMethod,
                    privateKeyPath: mappedIdentity == nil ? keyPath : "",
                    groupName: normalizedGroup(record.group),
                    tagsText: record.tags.joined(separator: ", "),
                    notes: record.notes ?? "",
                    identityID: mappedIdentity?.id,
                    defaultSFTPPath: normalizedRemotePath(record.defaultRemotePath)
                )
                context.insert(server)
                inserted.append(server)

                if mappedIdentity == nil, importPlaintextPasswords,
                   let password = candidate.credential?.password() {
                    try credentialStore.savePassword(password, id)
                    passwordIDs.append(id)
                }
            }
            try context.save()
        } catch {
            context.rollback()
            var cleanupFailed = false
            for id in passwordIDs {
                do { try credentialStore.deletePassword(id) }
                catch { cleanupFailed = true }
            }
            if cleanupFailed { throw SessionMigrationError.credentialCleanupFailed }
            throw error
        }

        return SessionImportResult(
            importedCount: inserted.count,
            skippedCount: selection.preview.candidates.count - inserted.count,
            passwordCount: passwordIDs.count
        )
    }

    private static func uniqueName(_ base: String, usedNames: inout Set<String>) -> String {
        guard usedNames.contains(base.lowercased()) else {
            usedNames.insert(base.lowercased())
            return base
        }
        var suffix = 2
        while usedNames.contains("\(base) (\(suffix))".lowercased()) { suffix += 1 }
        let value = "\(base) (\(suffix))"
        usedNames.insert(value.lowercased())
        return value
    }

    private static func normalizedGroup(_ value: String?) -> String {
        let group = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return group.isEmpty ? "默认分组" : group
    }

    private static func normalizedRemotePath(_ value: String?) -> String {
        let path = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? "." : path
    }

    private static func usableExternalKeyPath(_ value: String?) -> String {
#if os(macOS)
        guard let value = SessionTransferSecurity.externalPrivateKeyPath(value) else { return "" }
        let path = NSString(string: value).expandingTildeInPath
        return FileManager.default.isReadableFile(atPath: path) ? value : ""
#else
        return ""
#endif
    }
}

enum SessionCredentialReadiness: Sendable, Equatable {
    case ready
    case needsConfiguration
}

extension ServerRecord {
    var credentialReadiness: SessionCredentialReadiness {
        if identityID != nil { return .ready }
        let hasPassword = KeychainService.hasPassword(for: id)
#if os(macOS)
        let expandedPath = NSString(string: privateKeyPath).expandingTildeInPath
        let hasPrivateKey = !privateKeyPath.isEmpty && FileManager.default.isReadableFile(atPath: expandedPath)
#else
        let hasPrivateKey = false
#endif
        let ready: Bool
        switch authentication {
        case .password: ready = hasPassword
        case .privateKey: ready = hasPrivateKey
        case .keyThenPassword: ready = hasPrivateKey || hasPassword
        }
        return ready ? .ready : .needsConfiguration
    }
}

struct SessionImportCredentialStore {
    var savePassword: (_ password: String, _ credentialID: UUID) throws -> Void
    var deletePassword: (_ credentialID: UUID) throws -> Void

    static let keychain = SessionImportCredentialStore(
        savePassword: { password, credentialID in
            try KeychainService.savePassword(password, for: credentialID)
        },
        deletePassword: { credentialID in
            try KeychainService.deletePassword(for: credentialID)
        }
    )
}

enum SessionImportFileLoader {
    static let maxFileBytes = 16 * 1_024 * 1_024
    static let maxArchiveBytes = 64 * 1_024 * 1_024
    static let maxExpandedBytes = 256 * 1_024 * 1_024
    static let maxArchiveEntries = 10_000
    static let maxPathDepth = 32

    private struct LoadBudget {
        var itemCount = 0
        var expandedBytes = 0

        mutating func reserve(path: String, bytes: Int) throws {
            guard bytes <= SessionImportFileLoader.maxFileBytes else {
                throw SessionMigrationError.fileTooLarge(URL(fileURLWithPath: path).lastPathComponent)
            }
            itemCount += 1
            guard itemCount <= SessionImportFileLoader.maxArchiveEntries else {
                throw SessionMigrationError.archiveEntryLimit
            }
            expandedBytes += bytes
            guard expandedBytes <= SessionImportFileLoader.maxExpandedBytes else {
                throw SessionMigrationError.archiveTooLarge
            }
        }

        mutating func reconcile(expectedBytes: Int, actualBytes: Int, path: String) throws {
            guard actualBytes <= SessionImportFileLoader.maxFileBytes else {
                throw SessionMigrationError.fileTooLarge(path)
            }
            expandedBytes += actualBytes - expectedBytes
            guard expandedBytes <= SessionImportFileLoader.maxExpandedBytes else {
                throw SessionMigrationError.archiveTooLarge
            }
        }
    }

    static func load(_ input: SessionImportInput) throws -> [SessionSourceFile] {
        var budget = LoadBudget()
        switch input {
        case .files(let files):
            for file in files {
                try Task.checkCancellation()
                try budget.reserve(path: file.path, bytes: file.data.count)
            }
            return files
        case .urls(let urls):
            guard !urls.isEmpty else { throw SessionMigrationError.noInput }
            var files: [SessionSourceFile] = []
            for url in urls {
                try Task.checkCancellation()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                try append(
                    url: url,
                    relativeTo: url.deletingLastPathComponent(),
                    files: &files,
                    budget: &budget
                )
            }
            return files
        }
    }

    private static func append(
        url: URL,
        relativeTo root: URL,
        files: inout [SessionSourceFile],
        budget: inout LoadBudget
    ) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
        if values.isSymbolicLink == true { throw SessionMigrationError.symbolicLink(url.lastPathComponent) }
        if values.isDirectory == true {
            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { throw SessionMigrationError.unreadableFile(url.lastPathComponent) }
            while let item = enumerator.nextObject() as? URL {
                try Task.checkCancellation()
                let child = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if child.isSymbolicLink == true { throw SessionMigrationError.symbolicLink(item.lastPathComponent) }
                if child.isDirectory != true {
                    try appendFile(url: item, relativeTo: url, files: &files, budget: &budget)
                }
            }
        } else {
            try appendFile(url: url, relativeTo: root, files: &files, budget: &budget)
        }
    }

    private static func appendFile(
        url: URL,
        relativeTo root: URL,
        files: inout [SessionSourceFile],
        budget: inout LoadBudget
    ) throws {
        if url.pathExtension.lowercased() == "zip" {
            try appendArchive(url: url, files: &files, budget: &budget)
            return
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxFileBytes else { throw SessionMigrationError.fileTooLarge(url.lastPathComponent) }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            throw SessionMigrationError.unreadableFile(url.lastPathComponent)
        }
        let rootPath = root.standardizedFileURL.path
        let itemPath = url.standardizedFileURL.path
        let relative = itemPath.hasPrefix(rootPath + "/")
            ? String(itemPath.dropFirst(rootPath.count + 1)) : url.lastPathComponent
        try budget.reserve(path: relative, bytes: data.count)
        files.append(SessionSourceFile(path: relative, data: data))
    }

    private static func appendArchive(
        url: URL,
        files: inout [SessionSourceFile],
        budget: inout LoadBudget
    ) throws {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxArchiveBytes else { throw SessionMigrationError.archiveTooLarge }
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read, pathEncoding: nil)
        } catch {
            throw SessionMigrationError.invalidArchive
        }
        for entry in archive {
            try Task.checkCancellation()
            try validateArchivePath(entry.path)
            if entry.type == .symlink { throw SessionMigrationError.symbolicLink(entry.path) }
            guard entry.uncompressedSize <= UInt64(Int.max) else {
                throw SessionMigrationError.fileTooLarge(entry.path)
            }
            try budget.reserve(
                path: entry.path,
                bytes: entry.type == .file ? Int(entry.uncompressedSize) : 0
            )
            guard entry.type == .file else { continue }
            guard entry.uncompressedSize <= UInt64(maxFileBytes) else {
                throw SessionMigrationError.fileTooLarge(entry.path)
            }
            var data = Data()
            data.reserveCapacity(Int(entry.uncompressedSize))
            do {
                _ = try archive.extract(entry) { chunk in
                    try Task.checkCancellation()
                    data.append(chunk)
                    if data.count > maxFileBytes { throw SessionMigrationError.fileTooLarge(entry.path) }
                }
            } catch let error as SessionMigrationError {
                throw error
            } catch {
                throw SessionMigrationError.invalidArchive
            }
            try budget.reconcile(
                expectedBytes: Int(entry.uncompressedSize),
                actualBytes: data.count,
                path: entry.path
            )
            files.append(SessionSourceFile(path: entry.path, data: data))
        }
    }

    static func validateArchivePath(_ path: String) throws {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard !normalized.hasPrefix("/"), !normalized.hasPrefix("~"),
              !normalized.contains(":/"), components.count <= maxPathDepth,
              !components.contains("..") else {
            throw SessionMigrationError.unsafeArchivePath(path)
        }
    }
}

enum SessionArchiveWriter {
    static func makeArchive(entries: [(path: String, data: Data)]) throws -> Data {
        guard entries.count <= SessionImportFileLoader.maxArchiveEntries else {
            throw SessionMigrationError.archiveEntryLimit
        }
        let archive = try Archive(data: Data(), accessMode: .create)
        var expandedBytes = 0
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            try SessionImportFileLoader.validateArchivePath(entry.path)
            let data = entry.data
            guard data.count <= SessionImportFileLoader.maxFileBytes else {
                throw SessionMigrationError.fileTooLarge(entry.path)
            }
            expandedBytes += data.count
            guard expandedBytes <= SessionImportFileLoader.maxExpandedBytes else {
                throw SessionMigrationError.archiveTooLarge
            }
            try archive.addEntry(
                with: entry.path,
                type: .file,
                uncompressedSize: Int64(data.count),
                compressionMethod: .deflate
            ) { position, size in
                let start = Int(position)
                let end = min(data.count, start + size)
                guard start < end else { return Data() }
                return data.subdata(in: start..<end)
            }
        }
        guard let data = archive.data else { throw SessionMigrationError.invalidArchive }
        guard data.count <= SessionImportFileLoader.maxArchiveBytes else {
            throw SessionMigrationError.archiveTooLarge
        }
        return data
    }
}

enum SessionLocalDiscovery {
    static func urls(for source: SessionTransferSource) -> [URL] {
#if os(macOS)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates: [URL]
        switch source {
        case .automatic:
            candidates = urls(for: .secureCRT) + urls(for: .finalShell) + urls(for: .putty) + urls(for: .openSSH)
        case .secureCRT:
            candidates = [
                home.appendingPathComponent("Library/Application Support/VanDyke/SecureCRT/Config/Sessions"),
                home.appendingPathComponent(".vandyke/Config/Sessions")
            ]
        case .finalShell:
            candidates = [
                home.appendingPathComponent("Library/FinalShell/conn"),
                home.appendingPathComponent(".finalshell/conn")
            ]
        case .putty:
            candidates = [home.appendingPathComponent(".putty/sessions")]
        case .openSSH:
            candidates = [home.appendingPathComponent(".ssh/config")]
        default:
            candidates = []
        }
        return candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
#else
        return []
#endif
    }
}
