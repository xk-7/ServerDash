#if os(macOS)
import AppKit
import CryptoKit
import Foundation

struct RemoteFileRevision: Codable, Equatable, Sendable {
    var size: Int64
    var modifiedNS: Int64
    var inode: UInt64
    var mode: UInt16
    var uid: UInt32
    var gid: UInt32
    var sha256: String
}

struct DesktopFileMetadata: Codable, Sendable {
    var path: String
    var kind: String
    var revision: RemoteFileRevision?
}

struct DirectoryManifestEntry: Codable, Equatable, Sendable {
    var path: String
    var kind: String
    var size: Int64
    var sha256: String
    var modifiedNS: Int64
    var inode: UInt64? = nil
}

enum DesktopFileError: LocalizedError, Equatable {
    case operation(String)
    case conflict
    case unsupportedFile
    case tooLarge
    case invalidEncoding
    var errorDescription: String? {
        switch self {
        case .operation(let text): text
        case .conflict: "远程文件已经变化。请重新载入、另存为，或明确选择覆盖。"
        case .unsupportedFile: "只能编辑普通文本文件；符号链接、目录和二进制文件不能直接编辑。"
        case .tooLarge: "文件或目录超过本次操作的大小或项目数量限制。"
        case .invalidEncoding: "当前编码无法无损读取或保存此文件，请选择正确的编码。"
        }
    }
}

enum RemoteArchiveFormat: String, CaseIterable, Identifiable {
    case tarGzip = "tar.gz", zip
    var id: String { rawValue }
}

enum DesktopFilePreferences {
    private static let testRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("serverdash-remote-files-tests-" + UUID().uuidString, isDirectory: true)
    static var promptDirectorySync: Bool {
        get { UserDefaults.standard.object(forKey: "sftpPromptDirectorySync") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "sftpPromptDirectorySync") }
    }
    static var downloadDirectory: String {
        get { UserDefaults.standard.string(forKey: "sftpDownloadDirectory") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "sftpDownloadDirectory") }
    }
    static var editorFileLimit: Int {
        max(1, min(32, UserDefaults.standard.object(forKey: "sftpEditorFileLimit") as? Int ?? 5))
    }
    static var editorByteLimit: Int {
        max(1, min(100, UserDefaults.standard.object(forKey: "sftpEditorTotalMB") as? Int ?? 10)) * 1_024 * 1_024
    }
    static var root: URL {
        // Hosted UI tests may initialize shared stores; never read or rewrite real drafts/bindings.
        if NSClassFromString("XCTestCase") != nil ||
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
            ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil { return testRoot }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ServerDash/RemoteFiles", isDirectory: true)
    }
    static func directory(_ component: String) throws -> URL {
        let url = root.appendingPathComponent(component, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }
    static func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// The access object shares the app's credentials, route revisions, and host-trust gate.
@MainActor final class DesktopFileAccess {
    let server: ServerRecord
    private weak var appState: AppState?
    init(server: ServerRecord, appState: AppState) { self.server = server; self.appState = appState }
    var endpointIdentity: String {
        let config = appState?.connectionConfig(for: server) ?? server.connectionConfig
        return identity(config)
    }
    private func identity(_ config:ServerConnectionConfig)->String {"\(config.host.lowercased())|\(config.port)|\(config.username)"}
    func perform<T>(matching endpoint:String? = nil, _ work: (ServerConnectionConfig) async throws -> T) async throws -> T {
        try Task.checkCancellation()
        guard let appState else { throw CancellationError() }
        let config = appState.connectionConfig(for: server)
        guard endpoint == nil || endpoint == identity(config) else {throw DesktopFileError.operation("主机地址或用户已变化，本次文件操作已停止。")}
        return try await appState.performTrustedConnection(config, source: .sftp) { try await work(config) }
    }
}

enum DesktopFileOperations {
    struct Response: Decodable {
        var ok: Bool
        var error: String?
        var metadata: DesktopFileMetadata?
        var entries: [DirectoryManifestEntry]?
        var exists: Bool?
    }
    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func displaySize(_ bytes: Int64) -> String {
        if bytes < 1_024 { return "\(bytes) B" }
        if bytes < 1_048_576 { return String(format: "%.1f KB", Double(bytes) / 1_024) }
        if bytes < 1_073_741_824 { return String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        return String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func inspect(path: String, config: ServerConnectionConfig, limit: Int = DesktopFilePreferences.editorByteLimit) async throws -> DesktopFileMetadata {
        let result = try await request(["action": "inspect", "path": path, "limit": limit], config: config)
        guard let metadata = result.metadata else { throw DesktopFileError.operation("没有收到远程文件信息。") }
        return metadata
    }
    static func manifest(path: String, config: ServerConnectionConfig) async throws -> [DirectoryManifestEntry] {
        try await request(["action": "manifest", "path": path], config: config).entries ?? []
    }
    static func isAbsent(path:String,config:ServerConnectionConfig) async throws -> Bool {
        let response=try await request(["action":"exists","path":path],config:config)
        guard let exists=response.exists else{throw DesktopFileError.operation("无法确认远端文件是否仍然缺失。")}
        return !exists
    }
    static func delete(path:String,expected:DirectoryManifestEntry,config:ServerConnectionConfig) async throws {
        let snapshot=try JSONSerialization.jsonObject(with:JSONEncoder().encode(expected))
        _ = try await request(["action":"delete","path":path,"expectedEntry":snapshot,"limit":536_870_912],config:config)
    }
    static func mutate(action: String, paths: [String], destination: String = "", policy: SFTPConflictPolicy = .skip,
                       mode: UInt16 = 0o644, recursive: Bool = false, format: RemoteArchiveFormat = .tarGzip,
                       config: ServerConnectionConfig) async throws {
        _ = try await request(["action": action, "paths": paths, "destination": destination,
            "policy": policy.rawValue, "mode": Int(mode), "recursive": recursive, "format": format.rawValue], config: config)
    }
    static func read(path: String, config: ServerConnectionConfig, limit: Int) async throws -> (Data, RemoteFileRevision) {
        let before = try await inspect(path: path, config: config, limit: limit)
        guard before.kind == "file", let revision = before.revision else { throw DesktopFileError.unsupportedFile }
        guard revision.size <= limit else { throw DesktopFileError.tooLarge }
        let local = try DesktopFilePreferences.directory("Staging").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: local) }
        let item = RemoteFileItem(path: path, name: (path as NSString).lastPathComponent, kind: .file, size: revision.size,
            permissions: "", owner: "", group: "", modifiedText: "")
        try await SFTPService.download(item: item, to: local, config: config, policy: .overwrite)
        let attributes = try FileManager.default.attributesOfItem(atPath: local.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= limit else { throw DesktopFileError.tooLarge }
        let data = try Data(contentsOf: local)
        let after = try await inspect(path: path, config: config, limit: limit)
        guard after.revision == revision, digest(data) == revision.sha256 else { throw DesktopFileError.conflict }
        return (data, revision)
    }
    static func save(data: Data, path: String, expected: RemoteFileRevision?, force: Bool = false,
                     config: ServerConnectionConfig) async throws -> RemoteFileRevision {
        try SFTPService.validatePath(path)
        let folder = RemotePath.parent(of: path)
        let stage = RemotePath.child(".serverdash-edit-\(UUID().uuidString)", of: folder)
        let local = try DesktopFilePreferences.directory("Staging").appendingPathComponent(UUID().uuidString)
        try DesktopFilePreferences.writePrivate(data, to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        do {
            _ = try await request(["action": "prepare", "path": path, "stage": stage], config: config)
            try await SFTPService.uploadFile(localURL: local, toExactRemotePath: stage, config: config)
            try Task.checkCancellation()
            let checkLimit=max(data.count,Int(expected?.size ?? 0),DesktopFilePreferences.editorByteLimit)
            var payload: [String: Any] = ["action": "commit", "path": path, "stage": stage, "force": force,
                "digest": digest(data), "limit": checkLimit]
            if let expected { payload["expected"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(expected)) }
            let response = try await request(payload, config: config)
            guard let revision = response.metadata?.revision else { throw DesktopFileError.operation("文件已提交，但无法确认保存后的版本，请刷新检查。") }
            return revision
        } catch {
            // A separate bounded cleanup task may run after the parent operation was cancelled.
            _ = await Task.detached { try? await request(["action": "cleanup", "stage": stage], config: config) }.value
            throw error
        }
    }
    static func request(_ payload: [String: Any], config: ServerConnectionConfig) async throws -> Response {
        let encoded = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let unavailable = "{\"ok\":false,\"error\":\"高级文件操作需要远程主机提供 Python 3；基础 SFTP 仍可使用。\"}"
        let command = "if command -v python3 >/dev/null 2>&1; then python3 -c \(shellQuote(remoteScript)) \(shellQuote(String(decoding: encoded, as: UTF8.self))); else printf '%s\\n' \(shellQuote(unavailable)); fi"
        let plan = try SystemOpenSSHConnectionProvider().launchPlan(for: config, purpose: .remoteCommand(command))
        let result: ProcessRunResult
        do {
            result = try await ConnectionProcessController.shared.run(ProcessRunRequest(executable: plan.executable,
                arguments: plan.arguments, environment: plan.environment, connectTimeout: config.connectTimeout,
                totalTimeout: 300, maxOutputBytes: 8_000_000, serverID: config.id, module: .sftp,
                host: config.host, port: config.port))
        } catch let error as ConnectionError {
            if error == .remoteCommandMissing { throw DesktopFileError.operation("高级文件操作需要远程主机提供 Python 3；基础 SFTP 仍可使用。") }
            throw error
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: Data(result.output.utf8)) else {
            throw DesktopFileError.operation("无法读取高级文件操作结果，请确认远程主机已安装 Python 3 且允许 SSH 命令。")
        }
        if !response.ok {
            if response.error == "conflict" { throw DesktopFileError.conflict }
            if response.error == "limit" { throw DesktopFileError.tooLarge }
            throw DesktopFileError.operation(response.error ?? "远程文件操作失败。")
        }
        return response
    }

    /// Fixed stdlib program; all user-controlled values travel as JSON, never executable source.
    static let remoteScript = #"""
import os, sys, json, stat, hashlib, shutil, tarfile, zipfile, uuid, signal
def interrupted(signum, frame): raise KeyboardInterrupt()
signal.signal(signal.SIGTERM, interrupted)
p = json.loads(sys.argv[1])
limit = int(p.get('limit', 10485760))
def safe(value):
    if not isinstance(value, str) or not value or any(ord(c)<32 or ord(c)==127 for c in value):
        raise ValueError('路径不能包含控制字符。')
    value=os.path.abspath(value)
    if sys.platform=='darwin':
        for alias in ('/var','/tmp','/etc'):
            if (value==alias or value.startswith(alias+'/')) and os.path.realpath(alias)=='/private'+alias:
                value='/private'+value
                break
    return value
def no_link_ancestors(path):
    current=os.path.abspath(path)
    while current != os.path.dirname(current):
        if os.path.islink(current): raise ValueError('不写入符号链接路径。')
        current=os.path.dirname(current)
def hashed(path, maximum):
    if os.stat(path, follow_symlinks=False).st_size > maximum: raise ValueError('limit')
    h=hashlib.sha256(); count=0
    with open(path,'rb') as f:
        while True:
            b=f.read(262144)
            if not b: break
            count+=len(b)
            if count>maximum: raise ValueError('limit')
            h.update(b)
    return h.hexdigest()
def metadata(path):
    s=os.lstat(path)
    kind='file' if stat.S_ISREG(s.st_mode) else 'directory' if stat.S_ISDIR(s.st_mode) else 'link' if stat.S_ISLNK(s.st_mode) else 'other'
    rev=None
    if kind=='file':
        rev={'size':s.st_size,'modifiedNS':s.st_mtime_ns,'inode':s.st_ino,'mode':stat.S_IMODE(s.st_mode),'uid':s.st_uid,'gid':s.st_gid,'sha256':hashed(path,limit)}
    return {'path':path,'kind':kind,'revision':rev}
def stagepath():
    stage=safe(p['stage'])
    if not os.path.basename(stage).startswith('.serverdash-edit-'): raise ValueError('无效的保存暂存路径。')
    return stage
def remove(path):
    if os.path.islink(path) or not os.path.isdir(path): os.unlink(path)
    else: shutil.rmtree(path)
def destination(path, policy):
    if not os.path.lexists(path): return path
    if policy=='skip': return None
    if policy=='overwrite': return path
    stem, ext=os.path.splitext(path); i=2
    while os.path.lexists(stem+' '+str(i)+ext): i+=1
    return stem+' '+str(i)+ext
try:
    action=p['action']; result={'ok':True}
    if action=='inspect': result['metadata']=metadata(safe(p['path']))
    elif action=='exists':
        path=safe(p['path']); no_link_ancestors(os.path.dirname(path))
        try: os.lstat(path); result['exists']=True
        except FileNotFoundError: result['exists']=False
    elif action=='manifest':
        root=safe(p['path']); entries=[]; total=0
        if not os.path.isdir(root) or os.path.islink(root): raise ValueError('同步根目录必须是普通目录。')
        for directory, dirs, files in os.walk(root,followlinks=False):
            dirs[:]=sorted(d for d in dirs if not d.startswith('.serverdash-edit-'))
            for name in sorted(dirs+files):
                if name.startswith('.serverdash-edit-'): continue
                full=os.path.join(directory,name); s=os.lstat(full)
                kind='directory' if stat.S_ISDIR(s.st_mode) else 'file' if stat.S_ISREG(s.st_mode) else 'link'
                total+=s.st_size if kind=='file' else 0
                if len(entries)>=10000 or total>536870912: raise ValueError('limit')
                entries.append({'path':os.path.relpath(full,root),'kind':kind,'size':s.st_size if kind=='file' else 0,
                    'sha256':hashed(full,536870912) if kind=='file' else '', 'modifiedNS':s.st_mtime_ns,'inode':s.st_ino})
        result['entries']=entries
    elif action=='delete':
        path=safe(p['path']); expected=p['expectedEntry']
        no_link_ancestors(path)
        if not os.path.lexists(path): raise ValueError('conflict')
        current=metadata(path); s=os.lstat(path)
        if expected.get('inode') is None or s.st_ino!=expected['inode'] or current['kind']!=expected['kind']:
            raise ValueError('conflict')
        if current['kind']=='file':
            rev=current['revision']
            if rev['sha256']!=expected['sha256'] or rev['size']!=expected['size'] or rev['modifiedNS']!=expected['modifiedNS']:
                raise ValueError('conflict')
            os.unlink(path)
        elif current['kind']=='directory':
            # Child removals change directory mtime. Keep its identity check and let
            # rmdir reject any unselected or newly appeared child; never recurse here.
            os.rmdir(path)
        else: raise ValueError('不删除符号链接或特殊文件。')
    elif action=='prepare':
        path=safe(p['path']); stage=stagepath()
        no_link_ancestors(os.path.dirname(path))
        if os.path.dirname(stage)!=os.path.dirname(path): raise ValueError('暂存文件必须与目标位于同一目录。')
        if os.path.lexists(path) and not stat.S_ISREG(os.lstat(path).st_mode): raise ValueError('只能保存普通文件。')
        fd=os.open(stage,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600); os.close(fd)
    elif action=='commit':
        path=safe(p['path']); stage=stagepath()
        no_link_ancestors(os.path.dirname(path))
        if os.path.dirname(stage)!=os.path.dirname(path): raise ValueError('无效的保存位置。')
        if not stat.S_ISREG(os.lstat(stage).st_mode): raise ValueError('无效的暂存文件。')
        current=metadata(path) if os.path.lexists(path) else None
        expected=p.get('expected')
        if current is not None and current['kind']!='file': raise ValueError('目标不是普通文件。')
        if not p.get('force') and (current['revision'] if current else None)!=expected: raise ValueError('conflict')
        if hashed(stage,limit)!=p['digest']: raise ValueError('上传内容校验失败，尚未替换远程文件。')
        if current:
            rev=current['revision']; st=os.stat(stage)
            if (st.st_uid,st.st_gid)!=(rev['uid'],rev['gid']): os.chown(stage,rev['uid'],rev['gid'])
            shutil.copystat(path,stage,follow_symlinks=False)
            os.chmod(stage,rev['mode']); os.utime(stage,None)
        with open(stage,'rb') as f: os.fsync(f.fileno())
        # POSIX rename provides atomic replacement, with optimistic version checking above.
        os.replace(stage,path)
        result['metadata']=metadata(path)
    elif action=='cleanup':
        stage=stagepath()
        if os.path.lexists(stage): os.unlink(stage)
    elif action=='mkdirs':
        target=safe(p['destination'])
        no_link_ancestors(target)
        if os.path.islink(target): raise ValueError('不能写入符号链接目录。')
        os.makedirs(target,exist_ok=True)
    elif action in ('copy','move'):
        target=safe(p['destination'])
        if not os.path.isdir(target): raise ValueError('目标目录不存在。')
        for source in p['paths']:
            source=safe(source); candidate=os.path.join(target,os.path.basename(source))
            if os.path.realpath(source)==os.path.realpath(candidate): raise ValueError('源与目标相同。')
            if os.path.isdir(source) and os.path.commonpath([os.path.realpath(source),os.path.realpath(target)])==os.path.realpath(source): raise ValueError('不能复制或移动到自身子目录。')
            candidate=destination(candidate,p.get('policy','skip'))
            if candidate is None: continue
            temporary=os.path.join(target,'.serverdash-edit-copy-'+uuid.uuid4().hex)
            backup=None
            try:
                if os.path.islink(source): os.symlink(os.readlink(source),temporary)
                elif os.path.isdir(source): shutil.copytree(source,temporary,symlinks=True)
                else: shutil.copy2(source,temporary,follow_symlinks=False)
                if os.path.lexists(candidate):
                    backup=os.path.join(target,'.serverdash-edit-backup-'+uuid.uuid4().hex)
                    os.rename(candidate,backup)
                try: os.rename(temporary,candidate)
                except BaseException:
                    if backup: os.rename(backup,candidate); backup=None
                    raise
                if backup: remove(backup); backup=None
                if action=='move': remove(source)
            finally:
                if os.path.lexists(temporary): remove(temporary)
    elif action=='chmod':
        mode=int(p['mode'])
        if mode<0 or mode>4095: raise ValueError('权限必须是 0000 到 7777 的八进制数。')
        for source in p['paths']:
            source=safe(source)
            if os.path.islink(source): raise ValueError('不修改符号链接目标的权限。')
            os.chmod(source,mode)
            if p.get('recursive') and os.path.isdir(source):
                for directory, dirs, files in os.walk(source,followlinks=False):
                    for name in dirs+files:
                        child=os.path.join(directory,name)
                        if not os.path.islink(child): os.chmod(child,mode)
    elif action=='archive':
        target=safe(p['destination']); sources=[safe(v) for v in p['paths']]
        if os.path.lexists(target): raise ValueError('压缩包已存在，请使用其他名称。')
        for source in sources:
            if source==target or (os.path.isdir(source) and os.path.commonpath([source,target])==source): raise ValueError('压缩包不能放在所选目录内。')
        temporary=os.path.join(os.path.dirname(target),'.serverdash-edit-archive-'+uuid.uuid4().hex)
        try:
            if p['format']=='tar.gz':
                with tarfile.open(temporary,'x:gz',dereference=False) as archive:
                    for source in sources: archive.add(source,arcname=os.path.basename(source))
            else:
                with zipfile.ZipFile(temporary,'x',compression=zipfile.ZIP_DEFLATED) as archive:
                    for source in sources:
                        paths=[source]
                        if os.path.isdir(source) and not os.path.islink(source):
                            paths += [os.path.join(d,n) for d,ds,fs in os.walk(source,followlinks=False) for n in ds+fs]
                        for path in paths:
                            name=os.path.relpath(path,os.path.dirname(source))
                            if os.path.islink(path):
                                info=zipfile.ZipInfo(name); info.create_system=3; info.external_attr=(stat.S_IFLNK|0o777)<<16
                                archive.writestr(info,os.readlink(path))
                            else: archive.write(path,name)
            os.link(temporary,target)
        finally:
            if os.path.exists(temporary): os.unlink(temporary)
    else: raise ValueError('未知文件操作。')
    print(json.dumps(result,ensure_ascii=True))
except Exception as error:
    print(json.dumps({'ok':False,'error':str(error)},ensure_ascii=True))
"""#
}
#endif
