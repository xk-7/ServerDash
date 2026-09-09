import CryptoKit
import Foundation

enum ConfigurationSyncError: LocalizedError {
    case invalidURL, invalidPackage, missingKey, unsupportedConditionalWrites, remoteChanged, localChanged
    case http(Int), message(String)
    var errorDescription: String? {
        switch self {
        case .invalidURL: "请输入有效的 HTTPS WebDAV 目录地址（不含用户名或密码）。"
        case .invalidPackage: "同步包格式无效、版本不兼容或超出限制。"
        case .missingKey: "请生成或导入 32 字节恢复密钥；连接已有同步目录时使用原恢复密钥。"
        case .unsupportedConditionalWrites: "此服务没有提供可靠的 ETag 条件写入；无法进行双向配置同步。"
        case .remoteChanged: "另一设备已更新配置。请重新预览后同步。"
        case .localChanged: "本机配置已在预览后改变。请重新预览。"
        case .http(let status): "WebDAV 请求失败（HTTP \(status)）。"
        case .message(let detail): detail
        }
    }
}

struct SyncConfigurationObject: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var kind: String
    var fields: [String: String]
    var deleted = false
    var name: String { fields["name"] ?? fields["title"] ?? kind }
    static let keys: [String: Set<String>] = [
        "ssh": ["name", "host", "port", "username", "authentication", "group", "tags", "notes", "sftpPath"],
        "rdp": ["name", "host", "port", "username", "domain", "group", "tags", "notes", "settings"],
        "vnc": ["name", "host", "port", "group", "tags", "notes"],
        "serial": ["name", "baud", "bits", "parity", "stop", "flow", "group", "tags", "notes"],
        "group": ["name", "parent"],
        "tag": ["name", "color"],
        "snippet": ["title", "command", "category", "notes", "favorite"],
        "advanced": ["server", "settings"],
        "route": ["server", "route"],
        "tunnel": ["server", "name", "direction", "bind", "port", "target", "targetPort"]
    ]
    func validate() throws {
        guard let allowed = Self.keys[kind], Set(fields.keys).isSubset(of: allowed),
              deleted || Set(fields.keys).isSuperset(of: kind == "group" ? allowed.subtracting(["parent"]) : allowed),
              fields.values.allSatisfy({ $0.utf8.count <= 262_144 && !$0.contains("\0") }) else { throw ConfigurationSyncError.invalidPackage }
    }
    func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

struct ConfigurationSyncPackage: Codable, Equatable, Sendable {
    var version = 1
    var spaceID: UUID
    var objects: [SyncConfigurationObject]
    func validate() throws {
        guard version == 1, objects.count <= 20_000, Set(objects.map(\.id)).count == objects.count else { throw ConfigurationSyncError.invalidPackage }
        try objects.forEach { try $0.validate() }
    }
}

enum ConfigurationSyncCrypto {
    private static let header = Data("ServerDash.ConfigSync.v1\n".utf8)
    static func newKey() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }
    static func encrypt(_ package: ConfigurationSyncPackage, key: Data) throws -> Data {
        guard key.count == 32 else { throw ConfigurationSyncError.missingKey }
        try package.validate()
        let bytes = try JSONEncoder().encode(package)
        guard bytes.count <= 32 * 1024 * 1024 else { throw ConfigurationSyncError.invalidPackage }
        let box = try AES.GCM.seal(bytes, using: SymmetricKey(data: key), authenticating: header)
        guard let combined = box.combined else { throw ConfigurationSyncError.invalidPackage }
        return header + combined
    }
    static func decrypt(_ data: Data, key: Data) throws -> ConfigurationSyncPackage {
        guard key.count == 32 else { throw ConfigurationSyncError.missingKey }
        guard data.count <= 32 * 1024 * 1024 + 1024, data.starts(with: header) else { throw ConfigurationSyncError.invalidPackage }
        let box = try AES.GCM.SealedBox(combined: data.dropFirst(header.count))
        let bytes = try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: header)
        let package = try JSONDecoder().decode(ConfigurationSyncPackage.self, from: bytes)
        try package.validate()
        return package
    }
}

enum SyncChoice: String, CaseIterable, Identifiable {
    case unresolved, local, remote, both
    var id: String { rawValue }
    var title: String { switch self { case .unresolved: "选择处理方式"; case .local: "使用本机"; case .remote: "使用远端"; case .both: "保留双方" } }
}

struct ConfigurationSyncChange: Identifiable {
    var id: UUID
    var local: SyncConfigurationObject?
    var remote: SyncConfigurationObject?
    var choice: SyncChoice
    var conflict: Bool
    var name: String { local?.name ?? remote?.name ?? "已删除配置" }
    var detail: String {
        if conflict { return "双方均有修改" }
        if choice == .local { return local?.deleted == true ? "删除远端配置" : "上传本机配置" }
        return remote?.deleted == true ? "删除本机配置" : "下载远端配置"
    }
}

enum ConfigurationSyncMerge {
    static func changes(local: [SyncConfigurationObject], remote: [SyncConfigurationObject], baseline: [UUID: SyncConfigurationObject]) -> [ConfigurationSyncChange] {
        let localByID = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        let remoteByID = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })
        return Set(localByID.keys).union(remoteByID.keys).union(baseline.keys).compactMap { id in
            let base = baseline[id]
            let l = localByID[id] ?? base.map { SyncConfigurationObject(id: id, kind: $0.kind, fields: $0.fields, deleted: true) }
            let r = remoteByID[id] ?? base.map { SyncConfigurationObject(id: id, kind: $0.kind, fields: $0.fields, deleted: true) }
            guard l != r else { return nil }
            let lc = l != base, rc = r != base
            let conflict = lc && rc
            return ConfigurationSyncChange(id: id, local: l, remote: r,
                choice: conflict ? .unresolved : (lc ? .local : .remote), conflict: conflict)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func resolve(local: [SyncConfigurationObject], remote: [SyncConfigurationObject], changes: [ConfigurationSyncChange]) throws -> [SyncConfigurationObject] {
        var merged = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })
        for object in local where merged[object.id] == nil { merged[object.id] = object }
        for change in changes {
            switch change.choice {
            case .unresolved: throw ConfigurationSyncError.message("请先处理所有同步冲突。")
            case .local: merged[change.id] = change.local
            case .remote: merged[change.id] = change.remote
            case .both:
                guard let kind = change.local?.kind, ["ssh", "rdp", "vnc", "serial", "snippet"].contains(kind) else {
                    throw ConfigurationSyncError.message("此类关联配置只能选择使用本机或远端版本。")
                }
                merged[change.id] = change.remote
                if var copy = change.local, !copy.deleted {
                    copy.id = UUID()
                    if let name = copy.fields["name"] { copy.fields["name"] = name + "（本机副本）" }
                    if let title = copy.fields["title"] { copy.fields["title"] = title + "（本机副本）" }
                    merged[copy.id] = copy
                }
            }
        }
        return normalize(Array(merged.values)).sorted { $0.id.uuidString < $1.id.uuidString }
    }
    static func normalize(_ objects: [SyncConfigurationObject]) -> [SyncConfigurationObject] {
        let deletedSSH = Set(objects.filter { $0.kind == "ssh" && $0.deleted }.map { $0.id.uuidString })
        let deletedGroups = objects.filter { $0.kind == "group" && $0.deleted }
        let liveGroupNames = Set(objects.filter { $0.kind == "group" && !$0.deleted }.compactMap { $0.fields["name"] })
        let liveTagNames = Set(objects.filter { $0.kind == "tag" && !$0.deleted }.compactMap { $0.fields["name"] })
        let deletedGroupNames = Set(deletedGroups.compactMap { $0.fields["name"] }).subtracting(liveGroupNames)
        let deletedTags = Set(objects.filter { $0.kind == "tag" && $0.deleted }.compactMap { $0.fields["name"] }).subtracting(liveTagNames)
        return objects.map { original in
            var object = original
            if ["advanced", "route", "tunnel"].contains(object.kind), let server = object.fields["server"], deletedSSH.contains(server) {
                object.deleted = true
            }
            if ["ssh", "rdp", "vnc", "serial"].contains(object.kind) {
                if let group = object.fields["group"], deletedGroupNames.contains(group) { object.fields["group"] = "默认分组" }
                if let text = object.fields["tags"] {
                    object.fields["tags"] = text.split(whereSeparator: { ",，;；".contains($0) })
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !deletedTags.contains($0) }.joined(separator: ",")
                }
            }
            if object.kind == "group", !object.deleted {
                var visited = Set<String>()
                while let parent = object.fields["parent"], let deleted = deletedGroups.first(where: { $0.id.uuidString == parent }), visited.insert(parent).inserted {
                    object.fields["parent"] = deleted.fields["parent"]
                }
            }
            return object
        }
    }
}

struct WebDAVSyncEndpoint: Equatable, Sendable {
    var directory: URL
    var username: String
    var password: String
    var resource: URL { directory.appendingPathComponent("ServerDash.configsync") }
    init(address: String, username: String, password: String) throws {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { throw ConfigurationSyncError.invalidURL }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if !components.path.hasSuffix("/") { components.path += "/" }
        directory = components.url!; self.username = username; self.password = password
    }
}

/// Never forwards credentials to redirects, and bounds the downloaded configuration.
private final class WebDAVSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor WebDAVSyncTransport {
    private let session: URLSession
    init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 120
            self.session = URLSession(configuration: configuration, delegate: WebDAVSessionDelegate(), delegateQueue: nil)
        }
    }
    func fetch(_ endpoint: WebDAVSyncEndpoint) async throws -> (Data?, String?) {
        let request = request(endpoint, method: "GET")
        let (stream, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw ConfigurationSyncError.invalidPackage }
        if response.statusCode == 404 { return (nil, nil) }
        guard response.statusCode == 200 else { throw ConfigurationSyncError.http(response.statusCode) }
        guard let etag = response.value(forHTTPHeaderField: "ETag"), Self.isStrongETag(etag) else { throw ConfigurationSyncError.unsupportedConditionalWrites }
        var data = Data()
        for try await byte in stream {
            guard data.count < 32 * 1024 * 1024 + 1024 else { throw ConfigurationSyncError.invalidPackage }
            data.append(byte)
        }
        return (data, etag)
    }
    func put(_ data: Data, endpoint: WebDAVSyncEndpoint, etag: String?) async throws {
        if let etag, !Self.isStrongETag(etag) { throw ConfigurationSyncError.unsupportedConditionalWrites }
        try await verifyConditionalWrites(endpoint)
        try Task.checkCancellation()
        var upload = request(endpoint, method: "PUT")
        upload.httpBody = data
        upload.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if let etag { upload.setValue(etag, forHTTPHeaderField: "If-Match") }
        else { upload.setValue("*", forHTTPHeaderField: "If-None-Match") }
        let (_, response) = try await session.data(for: upload)
        guard let response = response as? HTTPURLResponse else { throw ConfigurationSyncError.invalidPackage }
        if response.statusCode == 412 { throw ConfigurationSyncError.remoteChanged }
        guard [200, 201, 204].contains(response.statusCode) else { throw ConfigurationSyncError.http(response.statusCode) }
    }
    private static func isStrongETag(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count >= 2 && bytes.first == 34 && bytes.last == 34 &&
            bytes.dropFirst().dropLast().allSatisfy { $0 == 0x21 || (0x23...0x7e).contains($0) || $0 >= 0x80 }
    }
    private func verifyConditionalWrites(_ endpoint: WebDAVSyncEndpoint) async throws {
        // Some servers reject If-Match for missing files but ignore it on existing files,
        // or ignore If-None-Match altogether. Exercise both before touching user data.
        var probe = request(endpoint, method: "PUT")
        probe.url = endpoint.directory.appendingPathComponent(".serverdash-condition-\(UUID().uuidString)")
        probe.setValue("\"nonexistent-\(UUID().uuidString)\"", forHTTPHeaderField: "If-Match")
        probe.httpBody = Data()
        let (_, probeResponse) = try await session.data(for: probe)
        guard let probeHTTP = probeResponse as? HTTPURLResponse else { throw ConfigurationSyncError.invalidPackage }
        guard probeHTTP.statusCode == 412 else {
            if (200...299).contains(probeHTTP.statusCode) {
                var cleanup = probe; cleanup.httpMethod = "DELETE"; cleanup.httpBody = nil
                cleanup.setValue(nil, forHTTPHeaderField: "If-Match")
                _ = try? await session.data(for: cleanup)
            }
            throw ConfigurationSyncError.unsupportedConditionalWrites
        }
        var create = probe
        create.setValue(nil, forHTTPHeaderField: "If-Match")
        create.setValue("*", forHTTPHeaderField: "If-None-Match")
        var cleanup = create; cleanup.httpMethod = "DELETE"; cleanup.httpBody = nil
        cleanup.setValue(nil, forHTTPHeaderField: "If-None-Match")
        do {
            let (_, created) = try await session.data(for: create)
            guard let created = created as? HTTPURLResponse,
                  [200, 201, 204].contains(created.statusCode) else { throw ConfigurationSyncError.unsupportedConditionalWrites }
            let (_, duplicate) = try await session.data(for: create)
            guard (duplicate as? HTTPURLResponse)?.statusCode == 412 else { throw ConfigurationSyncError.unsupportedConditionalWrites }
            let (_, stale) = try await session.data(for: probe)
            guard (stale as? HTTPURLResponse)?.statusCode == 412 else { throw ConfigurationSyncError.unsupportedConditionalWrites }
        } catch {
            _ = try? await session.data(for: cleanup)
            throw error
        }
        _ = try? await session.data(for: cleanup)
    }
    private func request(_ endpoint: WebDAVSyncEndpoint, method: String) -> URLRequest {
        var request = URLRequest(url: endpoint.resource)
        request.httpMethod = method
        request.setValue("Basic " + Data((endpoint.username + ":" + endpoint.password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }
}
