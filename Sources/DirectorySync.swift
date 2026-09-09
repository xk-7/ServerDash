#if os(macOS)
import AppKit
import Darwin
import Foundation
import SwiftData
import SwiftUI

struct DirectorySyncBaseline: Codable, Equatable {
    var local: String
    var remote: String
}
struct DirectorySyncPair: Codable, Identifiable {
    var id = UUID()
    var serverID: UUID
    var serverName: String
    var localPath: String
    var remotePath: String
    var endpointIdentity: String?
    var automaticUpload = false
    var baseline: [String: DirectorySyncBaseline] = [:]
    var lastSyncedAt: Date?
}
struct DirectorySyncLocalBinding: Codable {
    var id: UUID
    var localPath: String
    var endpointIdentity: String?
    var automaticUpload: Bool
    var baseline: [String: DirectorySyncBaseline]
    var lastSyncedAt: Date?
    init(_ pair: DirectorySyncPair) {
        id=pair.id;localPath=pair.localPath;endpointIdentity=pair.endpointIdentity
        automaticUpload=pair.automaticUpload;baseline=pair.baseline;lastSyncedAt=pair.lastSyncedAt
    }
}
enum DirectorySyncAction: String, CaseIterable, Identifiable {
    case upload = "上传", download = "下载", conflict = "冲突", deletionConflict = "删除冲突"
    case deleteLocal = "删除本地", deleteRemote = "删除远端", unsupported = "跳过链接/特殊文件", skip = "跳过"
    var id: String { rawValue }
    var isDeletion:Bool {self == .deleteLocal || self == .deleteRemote}
}
struct DirectorySyncPlanEntry: Identifiable {
    var path: String
    var local: DirectoryManifestEntry?
    var remote: DirectoryManifestEntry?
    var action: DirectorySyncAction
    var resolution: DirectorySyncAction = .skip
    var included = true
    var id: String { path }
    var selectedAction: DirectorySyncAction { included ? (action == .conflict || action == .deletionConflict ? resolution : action) : .skip }
    var isDirectory: Bool { (local ?? remote)?.kind == "directory" }
}

enum DirectorySyncPlanner {
    static func fingerprint(_ item: DirectoryManifestEntry) -> String { item.kind + ":" + item.sha256 }
    static func automaticUploads(_ entries: [DirectorySyncPlanEntry], previousLocal: [DirectoryManifestEntry]) -> [DirectorySyncPlanEntry] {
        let previous = Dictionary(uniqueKeysWithValues: previousLocal.map { ($0.path, fingerprint($0)) })
        return entries.filter { entry in
            guard entry.action == .upload, let local = entry.local else { return false }
            return previous[entry.path] != fingerprint(local)
        }
    }
    static func plan(local: [DirectoryManifestEntry], remote: [DirectoryManifestEntry], baseline: [String: DirectorySyncBaseline]) -> [DirectorySyncPlanEntry] {
        let l = Dictionary(uniqueKeysWithValues: local.map { ($0.path,$0) })
        let r = Dictionary(uniqueKeysWithValues: remote.map { ($0.path,$0) })
        return Set(l.keys).union(r.keys).sorted().compactMap { path in
            let a=l[path], b=r[path]
            let action: DirectorySyncAction
            if [a,b].contains(where: { $0?.kind == "link" || $0?.kind == "other" }) { action = .unsupported }
            else if let a, let b {
                if fingerprint(a) == fingerprint(b) { return nil }
                if a.kind != b.kind { action = .unsupported }
                else if let old=baseline[path], old.local == fingerprint(a), old.remote != fingerprint(b) { action = .download }
                else if let old=baseline[path], old.remote == fingerprint(b), old.local != fingerprint(a) { action = .upload }
                else { action = .conflict }
            } else if baseline[path] != nil { action = .deletionConflict }
            else { action = a == nil ? .download : .upload }
            return DirectorySyncPlanEntry(path:path,local:a,remote:b,action:action,included:action != .deletionConflict)
        }
    }
    static func localURL(relative: String, root: URL) throws -> URL {
        guard !relative.hasPrefix("/"), !relative.split(separator:"/").contains(".."), !relative.isEmpty,
              !relative.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) else { throw SFTPError.invalidPath }
        var ancestor=URL(fileURLWithPath:normalizedSystemPath(root.path))
        while ancestor.path != "/" {
            if (try? FileManager.default.attributesOfItem(atPath:ancestor.path)[.type]) as? FileAttributeType == .typeSymbolicLink {
                throw DesktopFileError.operation("同步根目录经过符号链接，请重新核对本地目录。")
            }
            ancestor.deleteLastPathComponent()
        }
        var current=root
        for component in relative.split(separator:"/") {
            current.appendPathComponent(String(component))
            if (try? current.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw DesktopFileError.operation("同步不写入符号链接路径：\(relative)")
            }
        }
        return current
    }
    static func normalizedSystemPath(_ path: String) -> String {
        for alias in ["/var", "/tmp", "/etc"] where path == alias || path.hasPrefix(alias + "/") {
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: alias),
               target == "private" + alias || target == "/private" + alias { return "/private" + path }
        }
        return path
    }
    static func localManifest(root: URL) throws -> [DirectoryManifestEntry] {
        guard (try? root.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey]))?.isDirectory == true,
              (try? root.resourceValues(forKeys:[.isSymbolicLinkKey]))?.isSymbolicLink != true else {
            throw DesktopFileError.operation("本地同步目录不存在，或是符号链接。")
        }
        let keys:Set<URLResourceKey>=[.isDirectoryKey,.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey,.contentModificationDateKey]
        guard let enumerator=FileManager.default.enumerator(at:root,includingPropertiesForKeys:Array(keys),options:[],errorHandler:{_,_ in false}) else {
            throw DesktopFileError.operation("无法读取本地同步目录。")
        }
        var result:[DirectoryManifestEntry]=[]; var total:Int64=0
        while let url=enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let values=try url.resourceValues(forKeys:keys)
            if url.lastPathComponent.hasPrefix(".serverdash-edit-") { enumerator.skipDescendants();continue }
            let base=normalizedSystemPath(root.path).trimmingCharacters(in:CharacterSet(charactersIn:"/"))
            let full=normalizedSystemPath(url.path)
            let prefix=base.isEmpty ? "/" : "/"+base+"/"
            guard full.hasPrefix(prefix) else { throw DesktopFileError.operation("目录扫描返回了根目录之外的项目。") }
            let path=String(full.dropFirst(prefix.count))
            let kind=values.isSymbolicLink == true ? "link" : values.isDirectory == true ? "directory" : values.isRegularFile == true ? "file" : "other"
            let size=kind == "file" ? Int64(values.fileSize ?? 0) : 0
            total += size
            guard result.count<10_000, total<=536_870_912 else {throw DesktopFileError.tooLarge}
            let hash=kind == "file" ? DesktopFileOperations.digest(try Data(contentsOf:url,options:.mappedIfSafe)) : ""
            let inode=(try FileManager.default.attributesOfItem(atPath:url.path)[.systemFileNumber] as? NSNumber)?.uint64Value
            result.append(.init(path:path,kind:kind,size:size,sha256:hash,modifiedNS:Int64((values.contentModificationDate?.timeIntervalSince1970 ?? 0)*1_000_000_000),inode:inode))
        }
        return result.sorted{$0.path<$1.path}
    }
    static func deleteLocal(relative:String,root:URL,expected:DirectoryManifestEntry) throws {
        let url=try localURL(relative:relative,root:root)
        let attributes=try FileManager.default.attributesOfItem(atPath:url.path)
        let kind=attributes[.type] as? FileAttributeType
        let inode=(attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        guard let expectedInode=expected.inode,inode==expectedInode else{throw DesktopFileError.conflict}
        let result:Int32
        if expected.kind == "file",kind == .typeRegular {
            let size=(attributes[.size] as? NSNumber)?.int64Value
            let modifiedNS=Int64(((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)*1_000_000_000)
            guard size==expected.size,modifiedNS==expected.modifiedNS,
                  DesktopFileOperations.digest(try Data(contentsOf:url,options:.mappedIfSafe))==expected.sha256 else{throw DesktopFileError.conflict}
            result=Darwin.unlink(url.path)
        }else if expected.kind == "directory",kind == .typeDirectory {
            // Unlike removeItem, rmdir cannot recursively erase a newly appeared child.
            result=Darwin.rmdir(url.path)
        }else{throw DesktopFileError.conflict}
        guard result==0 else{throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
    }
    static func localIsAbsent(_ url:URL) throws -> Bool {
        var information=stat()
        if Darwin.lstat(url.path,&information)==0{return false}
        if errno==ENOENT{return true}
        throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)
    }
}

@MainActor final class DirectorySyncStore: ObservableObject {
    static let shared = DirectorySyncStore()
    @Published var pairs: [DirectorySyncPair] = []
    @Published var plan: [DirectorySyncPlanEntry] = []
    @Published var selectedPairID: UUID?
    @Published var busy = false
    @Published var error: String?
    @Published var message = "先预览差异，再选择同步。删除冲突需要明确选择并确认。"
    private var accesses:[UUID:DesktopFileAccess]=[:]
    private var operation:Task<Void,Never>?
    private var activeServerID:UUID?
    private var activePairID:UUID?
    private var automaticTask:Task<Void,Never>?
    private var lastLocal:[UUID:[DirectoryManifestEntry]]=[:]
    private let url:URL?
    private let bindingURL:URL?
    private let standalone:Bool
    private var context:ModelContext?
    private var persistenceReady:Bool
    init(url:URL?=nil) {
        standalone=url != nil
        persistenceReady=url != nil
        self.url=url ?? (try? DesktopFilePreferences.directory("DirectorySync").appendingPathComponent("pairs.json"))
        bindingURL=self.url?.deletingLastPathComponent().appendingPathComponent("machine-bindings.json")
        if let url=self.url,let data=try? Data(contentsOf:url),let values=try? JSONDecoder().decode([DirectorySyncPair].self,from:data) {pairs=values}
    }
    func configure(container:ModelContainer) {
        guard context == nil else{return}
        let context=ModelContext(container)
        context.autosaveEnabled=false
        do {
            var records=try context.fetch(FetchDescriptor<DirectorySyncTaskRecord>())
            let bindings:[DirectorySyncLocalBinding]
            if let bindingURL,FileManager.default.fileExists(atPath:bindingURL.path) {
                bindings=try JSONDecoder().decode([DirectorySyncLocalBinding].self,from:Data(contentsOf:bindingURL))
            } else {
                // One-way migration. Preserve the legacy file until both stores are durable.
                for pair in pairs where !records.contains(where:{$0.id==pair.id}) {
                    let record=DirectorySyncTaskRecord(id:pair.id,serverID:pair.serverID,serverName:pair.serverName,remotePath:pair.remotePath)
                    context.insert(record);records.append(record)
                }
                try context.save()
                bindings=pairs.map(DirectorySyncLocalBinding.init)
                if let bindingURL {try DesktopFilePreferences.writePrivate(JSONEncoder().encode(bindings),to:bindingURL)}
            }
            guard Set(bindings.map(\.id)).count == bindings.count else {throw DesktopFileError.operation("本机目录绑定包含重复任务，请检查状态文件。")}
            let local=Dictionary(uniqueKeysWithValues:bindings.map{($0.id,$0)})
            pairs=records.map { record in
                let binding=local[record.id]
                return DirectorySyncPair(id:record.id,serverID:record.serverID,serverName:record.serverName,
                    localPath:binding?.localPath ?? "",remotePath:record.remotePath,endpointIdentity:binding?.endpointIdentity,
                    automaticUpload:binding?.automaticUpload ?? false,baseline:binding?.baseline ?? [:],lastSyncedAt:binding?.lastSyncedAt)
            }.sorted{$0.serverName.localizedStandardCompare($1.serverName) == .orderedAscending}
            self.context=context;persistenceReady=true
        }catch{self.error="目录同步任务尚未载入，自动上传保持暂停：\(error.localizedDescription)";persistenceReady=false}
    }
    func register(_ access:DesktopFileAccess) {
        accesses[access.server.id]=access
        if automaticTask == nil {
            automaticTask=Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for:.seconds(10))
                    guard !Task.isCancelled,let self else {return}
                    await self.checkAutomatic()
                }
            }
        }
    }
    func unregister(serverID:UUID) {
        accesses[serverID]=nil
        if activeServerID==serverID { cancel() }
        for index in pairs.indices where pairs[index].serverID==serverID { pairs[index].automaticUpload=false };persist()
    }
    func shutdown(){operation?.cancel();automaticTask?.cancel();automaticTask=nil;persist()}
    func add(local:URL,remote:String,access:DesktopFileAccess) {
        guard persistenceReady else{error="目录同步数据库尚未就绪。";return}
        register(access)
        guard !pairs.contains(where:{$0.serverID==access.server.id && $0.localPath==local.path && $0.remotePath==remote}) else {return}
        let pair=DirectorySyncPair(serverID:access.server.id,serverName:access.server.displayName,localPath:local.path,remotePath:remote,endpointIdentity:access.endpointIdentity)
        pairs.append(pair);selectedPairID=pair.id;persist();preview(pair.id)
    }
    func remove(_ id:UUID){guard !busy else{return};pairs.removeAll{$0.id==id};lastLocal[id]=nil;if selectedPairID==id {selectedPairID=nil;plan=[]};persist()}
    func setAutomatic(_ enabled:Bool,id:UUID){guard let i=pairs.firstIndex(where:{$0.id==id}),!pairs[i].localPath.isEmpty else{return};pairs[i].automaticUpload=enabled;lastLocal[id]=nil;if !enabled && activePairID==id {cancel()};persist()}
    func preview(_ id:UUID) {
        guard !busy,let pair=pairs.first(where:{$0.id==id}),let access=accesses[pair.serverID] else{return}
        guard validEndpoint(pair,access:access) else{return}
        selectedPairID=id;busy=true;error=nil;plan=[];activeServerID=pair.serverID;activePairID=pair.id
        operation=Task {
            defer{busy=false;operation=nil;activeServerID=nil;activePairID=nil}
            do{
                let local=try await Task.detached {try DirectorySyncPlanner.localManifest(root:URL(fileURLWithPath:pair.localPath))}.value
                try Task.checkCancellation()
                let remote=try await access.perform(matching:pair.endpointIdentity){try await DesktopFileOperations.manifest(path:pair.remotePath,config:$0)}
                plan=DirectorySyncPlanner.plan(local:local,remote:remote,baseline:pair.baseline)
                lastLocal[id]=local
                if plan.isEmpty, let index=pairs.firstIndex(where:{$0.id==id}) {
                    let remoteMap=Dictionary(uniqueKeysWithValues:remote.map{($0.path,$0)})
                    let surviving=Set(local.map(\.path)).union(remote.map(\.path))
                    pairs[index].baseline=pairs[index].baseline.filter{surviving.contains($0.key)}
                    for item in local { if let other=remoteMap[item.path] { pairs[index].baseline[item.path] = .init(local:DirectorySyncPlanner.fingerprint(item),remote:DirectorySyncPlanner.fingerprint(other)) } }
                    pairs[index].lastSyncedAt=Date();persist()
                }
                message=plan.isEmpty ? "两个目录内容一致。" : "\(plan.count) 项差异；删除与双边修改默认跳过。"
            }catch{self.error=error.localizedDescription}
        }
    }
    func synchronize(confirmDeletions:Bool = false) {
        guard !busy,let id=selectedPairID,let pair=pairs.first(where:{$0.id==id}),let access=accesses[pair.serverID] else{return}
        guard validEndpoint(pair,access:access) else{return}
        guard confirmDeletions || !plan.contains(where:{$0.selectedAction.isDeletion}) else{error="所选操作包含删除，请核对删除项目并确认。";return}
        let selected=plan;busy=true;error=nil;activeServerID=pair.serverID;activePairID=pair.id
        operation=Task {
            defer{busy=false;operation=nil;activeServerID=nil;activePairID=nil}
            do {try await apply(selected,pair:pair,access:access);plan=[];message="同步完成。未选择的冲突与链接保持原状。"}
            catch is CancellationError{message="同步已取消，已完成项目保留。请重新预览。";plan=[]}
            catch{self.error=error.localizedDescription;plan=[]}
        }
    }
    func cancel(){operation?.cancel()}
    private func apply(_ entries:[DirectorySyncPlanEntry],pair:DirectorySyncPair,access:DesktopFileAccess) async throws {
        let root=URL(fileURLWithPath:pair.localPath,isDirectory:true)
        let ordered=entries.sorted {a,b in
            if a.selectedAction.isDeletion != b.selectedAction.isDeletion{return !a.selectedAction.isDeletion}
            let lhs=a.path.split(separator:"/").count,rhs=b.path.split(separator:"/").count
            if lhs==rhs{return a.path<b.path}
            return a.selectedAction.isDeletion ? lhs>rhs : lhs<rhs
        }
        for item in ordered {
            try Task.checkCancellation()
            let action=item.selectedAction
            guard action == .upload || action == .download || action.isDeletion else{continue}
            let local=try DirectorySyncPlanner.localURL(relative:item.path,root:root)
            let remote=RemotePath.child(item.path,of:pair.remotePath)
            message="\(action.rawValue) \(item.path)"
            if action == .deleteRemote {
                guard let expected=item.remote,try DirectorySyncPlanner.localIsAbsent(local) else{throw DesktopFileError.conflict}
                try await access.perform(matching:pair.endpointIdentity){try await DesktopFileOperations.delete(path:remote,expected:expected,config:$0)}
                continue
            }
            if action == .deleteLocal {
                guard let expected=item.local else{throw DesktopFileError.conflict}
                let absent=try await access.perform(matching:pair.endpointIdentity){try await DesktopFileOperations.isAbsent(path:remote,config:$0)}
                guard absent else{throw DesktopFileError.conflict}
                try Task.checkCancellation()
                try DirectorySyncPlanner.deleteLocal(relative:item.path,root:root,expected:expected)
                continue
            }
            if item.isDirectory {
                if action == .upload {try await access.perform(matching:pair.endpointIdentity){try await DesktopFileOperations.mutate(action:"mkdirs",paths:[],destination:remote,config:$0)}}
                else{try FileManager.default.createDirectory(at:local,withIntermediateDirectories:true)}
                continue
            }
            if action == .upload {
                let data=try Data(contentsOf:local)
                guard DesktopFileOperations.digest(data)==item.local?.sha256 else{throw DesktopFileError.conflict}
                try await access.perform(matching:pair.endpointIdentity){config in
                    var expected:RemoteFileRevision?
                    if let previous=item.remote {
                        let info=try await DesktopFileOperations.inspect(path:remote,config:config,limit:536_870_912)
                        guard info.revision?.sha256==previous.sha256 else{throw DesktopFileError.conflict};expected=info.revision
                    }
                    _ = try await DesktopFileOperations.save(data:data,path:remote,expected:expected,config:config)
                }
            }else{
                let (data,revision)=try await access.perform(matching:pair.endpointIdentity){try await DesktopFileOperations.read(path:remote,config:$0,limit:536_870_912)}
                guard revision.sha256==item.remote?.sha256 else{throw DesktopFileError.conflict}
                if let previous=item.local {
                    guard FileManager.default.fileExists(atPath:local.path),DesktopFileOperations.digest(try Data(contentsOf:local))==previous.sha256 else{throw DesktopFileError.conflict}
                }else if FileManager.default.fileExists(atPath:local.path){throw DesktopFileError.conflict}
                try FileManager.default.createDirectory(at:local.deletingLastPathComponent(),withIntermediateDirectories:true)
                let mode=(try? FileManager.default.attributesOfItem(atPath:local.path)[.posixPermissions]) ?? NSNumber(value:0o600)
                try data.write(to:local,options:.atomic)
                try FileManager.default.setAttributes([.posixPermissions:mode],ofItemAtPath:local.path)
            }
        }
        let local=try await Task.detached {try DirectorySyncPlanner.localManifest(root:root)}.value
        try Task.checkCancellation()
        let remote=try await access.perform(matching:pair.endpointIdentity){try await DesktopFileOperations.manifest(path:pair.remotePath,config:$0)}
        let remoteMap=Dictionary(uniqueKeysWithValues:remote.map{($0.path,$0)})
        if let index=pairs.firstIndex(where:{$0.id==pair.id}){
            let surviving=Set(local.map(\.path)).union(remote.map(\.path))
            pairs[index].baseline=pairs[index].baseline.filter{surviving.contains($0.key)}
            for item in local {
                if let other=remoteMap[item.path],DirectorySyncPlanner.fingerprint(item)==DirectorySyncPlanner.fingerprint(other){
                    pairs[index].baseline[item.path] = .init(local:DirectorySyncPlanner.fingerprint(item),remote:DirectorySyncPlanner.fingerprint(other))
                }
            }
            pairs[index].lastSyncedAt=Date();lastLocal[pair.id]=local;persist()
        }
    }
    private func checkAutomatic() async {
        guard persistenceReady,!busy,NSApplication.shared.isActive else{return}
        busy=true
        let task=Task { await performAutomatic() }
        operation=task
        await task.value
        operation=nil;busy=false;activeServerID=nil;activePairID=nil
    }
    private func performAutomatic() async {
        for pair in pairs where pair.automaticUpload {
            guard !Task.isCancelled else{return}
            guard let access=accesses[pair.serverID],validEndpoint(pair,access:access) else{continue}
            activeServerID=pair.serverID;activePairID=pair.id
            do{
                let local=try await Task.detached{try DirectorySyncPlanner.localManifest(root:URL(fileURLWithPath:pair.localPath))}.value
                try Task.checkCancellation()
                guard let previousLocal=lastLocal[pair.id] else {lastLocal[pair.id]=local;continue}
                guard previousLocal != local else{continue}
                lastLocal[pair.id]=local
                // Never upload an existing unbaselined pair automatically: first manual preview establishes trust in direction.
                guard pair.lastSyncedAt != nil else{continue}
                let remote=try await access.perform(matching:pair.endpointIdentity){try await DesktopFileOperations.manifest(path:pair.remotePath,config:$0)}
                let changes=DirectorySyncPlanner.plan(local:local,remote:remote,baseline:pair.baseline)
                let uploads=DirectorySyncPlanner.automaticUploads(changes,previousLocal:previousLocal)
                if !uploads.isEmpty{try await apply(uploads,pair:pair,access:access)}
                try Task.checkCancellation()
                if changes.contains(where:{$0.action == .conflict || $0.action == .deletionConflict}) {message="\(pair.serverName)：自动上传遇到冲突，请手动预览处理。"}
            }catch is CancellationError{message="自动上传已取消，已完成项目保留。";return}
            catch{self.error="自动上传已暂停本次操作：\(error.localizedDescription)"}
        }
    }
    private func validEndpoint(_ pair:DirectorySyncPair,access:DesktopFileAccess)->Bool {
        guard persistenceReady,!pair.localPath.isEmpty else {error="此任务尚未绑定本机目录。请移除后重新选择本地目录配对。";return false}
        guard pair.endpointIdentity == nil || pair.endpointIdentity == access.endpointIdentity else {
            if let index=pairs.firstIndex(where:{$0.id==pair.id}) {pairs[index].automaticUpload=false;persist()}
            error="主机地址或用户已变化，目录配对已暂停。请移除旧配对并重新核对目录。";return false
        }
        return true
    }
    private func persist(){
        guard persistenceReady else{return}
        do{
            if let context {
                let records=try context.fetch(FetchDescriptor<DirectorySyncTaskRecord>())
                let ids=Set(pairs.map(\.id))
                for record in records where !ids.contains(record.id){context.delete(record)}
                for pair in pairs {
                    if let record=records.first(where:{$0.id==pair.id}) {
                        if record.serverID != pair.serverID || record.serverName != pair.serverName || record.remotePath != pair.remotePath {
                            record.serverID=pair.serverID;record.serverName=pair.serverName;record.remotePath=pair.remotePath;record.updatedAt = .now
                        }
                    }else{context.insert(DirectorySyncTaskRecord(id:pair.id,serverID:pair.serverID,serverName:pair.serverName,remotePath:pair.remotePath))}
                }
                // A task deleted from the database never revives from leftover machine bindings.
                try context.save()
                if let bindingURL {try DesktopFilePreferences.writePrivate(JSONEncoder().encode(pairs.map(DirectorySyncLocalBinding.init)),to:bindingURL)}
            }else if standalone,let url{try DesktopFilePreferences.writePrivate(JSONEncoder().encode(pairs),to:url)}
        }catch{self.error="无法保存目录同步任务：\(error.localizedDescription)"}
    }
}

struct DirectorySyncView:View {
    let access:DesktopFileAccess
    let remotePath:String
    @ObservedObject private var store:DirectorySyncStore
    @MainActor init(access:DesktopFileAccess,remotePath:String){self.access=access;self.remotePath=remotePath;store = .shared}
    init(access:DesktopFileAccess,remotePath:String,store:DirectorySyncStore){self.access=access;self.remotePath=remotePath;self.store=store}
    @Environment(\.dismiss) private var dismiss
    @State private var localPath=""
    @State private var destination=""
    @State private var removeID:UUID?
    @State private var confirmingDeletions=false
    private var pairs:[DirectorySyncPair]{store.pairs.filter{$0.serverID==access.server.id}}
    private var deletions:[DirectorySyncPlanEntry]{store.plan.filter{$0.selectedAction.isDeletion}}
    var body:some View {
        VStack(alignment:.leading,spacing:14){
            HStack{Label("目录同步",systemImage:"arrow.triangle.2.circlepath").font(.title2.bold());Spacer();Button("完成"){dismiss()}}
            Text("手动预览并双向同步，删除冲突需选择恢复或明确删除另一侧。自动模式仅上传本地更改，绝不删除。")
                .font(.callout).foregroundStyle(.secondary)
            HStack{
                TextField("本地目录",text:$localPath).textFieldStyle(.roundedBorder)
                Button("选择…"){
                    let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false
                    if panel.runModal() == .OK,let url=panel.url{localPath=url.path}
                }
            }
            HStack{
                TextField("远程目录",text:$destination).textFieldStyle(.roundedBorder)
                Button("添加配对"){store.add(local:URL(fileURLWithPath:localPath),remote:destination,access:access)}
                    .disabled(localPath.isEmpty || destination.isEmpty || store.busy)
            }
            Divider()
            if pairs.isEmpty{Text("尚未配置同步目录。").foregroundStyle(.secondary)}
            ScrollView{
                VStack(spacing:8){ForEach(pairs){pair in
                    HStack(alignment:.top){
                        VStack(alignment:.leading,spacing:4){Text(pair.localPath.isEmpty ? "尚未绑定本机目录，请重新配对" : pair.localPath).font(.callout.monospaced());Text("↔ \(pair.remotePath)").font(.caption.monospaced()).foregroundStyle(.secondary)}
                        Spacer()
                        Toggle("自动上传本地更改",isOn:Binding(get:{pair.automaticUpload},set:{store.setAutomatic($0,id:pair.id)})).toggleStyle(.switch).controlSize(.small).disabled(pair.localPath.isEmpty)
                        Button("预览"){store.preview(pair.id)}.disabled(store.busy)
                        Button(role:.destructive){removeID=pair.id}label:{Image(systemName:"trash")}.disabled(store.busy)
                    }.padding(10).background(store.selectedPairID==pair.id ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.04),in:RoundedRectangle(cornerRadius:8))
                }}
            }.frame(maxHeight:160)
            if store.busy{ProgressView(store.message).frame(maxWidth:.infinity)}
            Table($store.plan){
                TableColumn("执行"){item in Toggle("包含此项",isOn:item.included).labelsHidden().disabled(item.wrappedValue.action == .unsupported)}.width(42)
                TableColumn("相对路径"){item in Text(item.wrappedValue.path).font(.callout.monospaced()).lineLimit(1)}
                TableColumn("方向"){item in
                    if item.wrappedValue.action == .deletionConflict {
                        Picker("删除冲突处理",selection:item.resolution){
                            Text("跳过删除冲突").tag(DirectorySyncAction.skip)
                            if item.wrappedValue.local == nil {
                                Text("恢复本地 ←").tag(DirectorySyncAction.download)
                                Text("删除远端文件").tag(DirectorySyncAction.deleteRemote)
                            }else{
                                Text("恢复远端 →").tag(DirectorySyncAction.upload)
                                Text("删除本地文件").tag(DirectorySyncAction.deleteLocal)
                            }
                        }
                    }else if item.wrappedValue.action == .conflict {
                        Picker("冲突处理",selection:item.resolution){Text("跳过冲突").tag(DirectorySyncAction.skip);Text("以本地为准 →").tag(DirectorySyncAction.upload);Text("← 以远端为准").tag(DirectorySyncAction.download)}
                    }else{Text(item.wrappedValue.action.rawValue).foregroundStyle(item.wrappedValue.action == .unsupported ? Color.secondary : Color.primary)}
                }.width(210)
                TableColumn("大小"){item in Text(DesktopFileOperations.displaySize((item.wrappedValue.local ?? item.wrappedValue.remote)?.size ?? 0)).monospacedDigit()}.width(90)
            }.frame(minHeight:200)
            HStack{Text(store.message).font(.caption).foregroundStyle(.secondary);Spacer();if store.busy{Button("取消"){store.cancel()}}else{Button("执行所选同步"){if deletions.isEmpty{store.synchronize()}else{confirmingDeletions=true}}.buttonStyle(.borderedProminent).disabled(store.plan.isEmpty)}}
        }.padding(20).frame(width:900,height:690).background(Color.appGround)
        .onAppear{destination=remotePath;store.register(access)}
        .alert("目录同步失败",isPresented:Binding(get:{store.error != nil},set:{if !$0{store.error=nil}})){Button("好"){store.error=nil}}message:{Text(store.error ?? "")}
        .confirmationDialog("移除此目录配对？",isPresented:Binding(get:{removeID != nil},set:{if !$0{removeID=nil}})){
            Button("移除配对",role:.destructive){if let id=removeID{store.remove(id)};removeID=nil}
        }message:{Text("本地与远程文件均会保留。")}
        .confirmationDialog("确认执行 \(deletions.count) 项删除？",isPresented:$confirmingDeletions){
            Button("删除所选项目并同步",role:.destructive){store.synchronize(confirmDeletions:true)}
            Button("返回预览",role:.cancel){}
        }message:{Text(deletions.prefix(8).map{"\($0.selectedAction.rawValue)：\($0.path)"}.joined(separator:"\n") + (deletions.count>8 ? "\n还有 \(deletions.count-8) 项" : "") + "\n删除前将重新核对版本；已完成的删除不能撤回。")}
    }
}
#endif
