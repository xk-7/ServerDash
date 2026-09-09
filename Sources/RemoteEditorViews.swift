#if os(macOS)
import AppKit
import CoreFoundation
import SwiftUI

enum RemoteTextEncoding: String, Codable, CaseIterable, Identifiable {
    case utf8 = "UTF-8", utf16LE = "UTF-16 LE", utf16BE = "UTF-16 BE", gb18030 = "GB18030"
    var id: String { rawValue }
    var foundation: String.Encoding {
        switch self {
        case .utf8: .utf8
        case .utf16LE: .utf16LittleEndian
        case .utf16BE: .utf16BigEndian
        case .gb18030: .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        }
    }
    var bom: Data {
        switch self { case .utf8: Data([0xEF,0xBB,0xBF]); case .utf16LE: Data([0xFF,0xFE]); case .utf16BE: Data([0xFE,0xFF]); case .gb18030: Data() }
    }
    static func decode(_ data: Data, preferred: Self? = nil) throws -> (String, Self, Bool) {
        let encoding: Self
        if let preferred { encoding = preferred }
        else if data.starts(with: utf16LE.bom) { encoding = .utf16LE }
        else if data.starts(with: utf16BE.bom) { encoding = .utf16BE }
        else { encoding = .utf8 }
        let hasBOM = !encoding.bom.isEmpty && data.starts(with: encoding.bom)
        let body = hasBOM ? data.dropFirst(encoding.bom.count) : data[...]
        guard let text = String(data: body, encoding: encoding.foundation),
              !text.unicodeScalars.contains(where: { $0.value == 0 || ($0.value < 32 && ![9,10,13].contains($0.value)) }) else {
            throw DesktopFileError.invalidEncoding
        }
        return (text, encoding, hasBOM)
    }
    func encode(_ text: String, bom: Bool) throws -> Data {
        guard let body = text.data(using: foundation, allowLossyConversion: false),
              String(data: body, encoding: foundation) == text else { throw DesktopFileError.invalidEncoding }
        return (bom ? self.bom : Data()) + body
    }
}

struct RemoteEditorDraft: Codable, Identifiable {
    var id: UUID = UUID()
    var serverID: UUID
    var serverName: String
    var path: String
    var text: String
    var encoding: RemoteTextEncoding
    var hasBOM: Bool
    var original: Data
    var revision: RemoteFileRevision
    var endpointIdentity: String?
    var isDirty: Bool { (try? encoding.encode(text, bom: hasBOM)) != original }
    var title: String { (path as NSString).lastPathComponent }
}

struct RemoteLocalCopy: Codable, Identifiable, Sendable {
    static let maximumBytes = 536_870_912
    var id = UUID()
    var serverID: UUID
    var serverName: String
    var remotePath: String
    var localPath: String
    var endpointIdentity: String
    var revision: RemoteFileRevision
    var lastUploadedAt: Date?
    var title:String {(remotePath as NSString).lastPathComponent}
    func modifiedContents(includeUnchanged:Bool = false) throws -> Data? {
        let url=URL(fileURLWithPath:localPath)
        let attributes=try FileManager.default.attributesOfItem(atPath:localPath)
        guard attributes[.type] as? FileAttributeType == .typeRegular else{throw DesktopFileError.unsupportedFile}
        guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= Self.maximumBytes else{throw DesktopFileError.tooLarge}
        let data=try Data(contentsOf:url)
        guard data.count<=Self.maximumBytes else{throw DesktopFileError.tooLarge}
        return !includeUnchanged && DesktopFileOperations.digest(data)==revision.sha256 ? nil : data
    }
}

@MainActor final class RemoteEditorStore: ObservableObject {
    static let shared = RemoteEditorStore()
    @Published var documents: [RemoteEditorDraft] = []
    @Published var selectedID: UUID?
    @Published var busy = false
    @Published var error: String?
    @Published var conflictID: UUID?
    @Published var conflictDestination: String?
    @Published var message = ""
    @Published var localCopies:[RemoteLocalCopy]=[]
    @Published var localCopyConflictID:UUID?
    @Published var localCopyConflictDestination:String?
    private var accesses: [UUID: DesktopFileAccess] = [:]
    private var operation: Task<Void, Never>?
    private var activeServerID: UUID?
    private var persistTask: Task<Void, Never>?
    private let persistURL: URL?
    private let copiesURL:URL?
    init(persistURL: URL? = nil, restore: Bool = true) {
        self.persistURL = persistURL ?? (try? DesktopFilePreferences.directory("Drafts").appendingPathComponent("documents.json"))
        copiesURL=self.persistURL?.deletingLastPathComponent().appendingPathComponent("local-copies.json")
        if restore, let url = self.persistURL, let data = try? Data(contentsOf: url),
           let restored = try? JSONDecoder().decode([RemoteEditorDraft].self, from: data) {
            documents = restored; selectedID = restored.first?.id
        }
        if restore,let copiesURL,let data=try? Data(contentsOf:copiesURL),let saved=try? JSONDecoder().decode([RemoteLocalCopy].self,from:data){localCopies=saved}
    }
    var selected: RemoteEditorDraft? { documents.first { $0.id == selectedID } }
    func register(_ access: DesktopFileAccess) { accesses[access.server.id] = access }
    func unregister(serverID: UUID) {
        accesses[serverID] = nil
        if activeServerID == serverID { operation?.cancel() }
    }
    func shutdown() { operation?.cancel(); persistTask?.cancel(); persist() }
    func canSave(_ id: UUID) -> Bool {
        guard let doc = documents.first(where: { $0.id == id }) else { return false }
        return accesses[doc.serverID] != nil && !busy
    }
    func canUploadLocalCopy(_ copy:RemoteLocalCopy)->Bool {
        accesses[copy.serverID]?.endpointIdentity==copy.endpointIdentity && !busy
    }
    func openLocalCopy(_ item:RemoteFileItem,access:DesktopFileAccess) {
        guard !busy,item.kind == .file else{return}
        register(access);busy=true;error=nil;activeServerID=access.server.id
        let endpointIdentity=access.endpointIdentity
        message="正在下载本地副本"
        operation=Task {
            defer{busy=false;operation=nil;activeServerID=nil}
            do{
                let (data,revision)=try await access.perform(matching:endpointIdentity){try await DesktopFileOperations.read(path:item.path,config:$0,limit:RemoteLocalCopy.maximumBytes)}
                try Task.checkCancellation()
                let directory=try DesktopFilePreferences.directory("LocalCopies/"+UUID().uuidString)
                let local=directory.appendingPathComponent(item.name)
                try DesktopFilePreferences.writePrivate(data,to:local)
                let copy=RemoteLocalCopy(serverID:access.server.id,serverName:access.server.displayName,remotePath:item.path,
                    localPath:local.path,endpointIdentity:endpointIdentity,revision:revision)
                localCopies.append(copy);persist()
                guard NSWorkspace.shared.open(local) else{throw DesktopFileError.operation("没有可打开此文件的应用。副本已保留，可在列表中用访达显示。")}
                message="已打开本地副本；修改后在此选择“上传修改”。"
            }catch is CancellationError{message="已取消打开副本"}
            catch{self.error=error.localizedDescription}
        }
    }
    func uploadLocalCopy(_ id:UUID,force:Bool=false,as destination:String?=nil) {
        guard !busy,let copy=localCopies.first(where:{$0.id==id}),let access=accesses[copy.serverID] else{return}
        guard access.endpointIdentity==copy.endpointIdentity else{error="主机地址或用户已变化，请保留本地副本并重新核对目标。";return}
        busy=true;error=nil;localCopyConflictID=nil;activeServerID=copy.serverID
        message="正在检查本地修改"
        operation=Task {
            defer{busy=false;operation=nil;activeServerID=nil}
            do{
                let modified=try await Task.detached{try copy.modifiedContents(includeUnchanged:force || destination != nil)}.value
                try Task.checkCancellation()
                guard let data=modified else{message="本地副本内容没有变化，无需上传。";return}
                let path=destination ?? copy.remotePath
                let revision=try await access.perform(matching:copy.endpointIdentity){
                    try await DesktopFileOperations.save(data:data,path:path,expected:path==copy.remotePath ? copy.revision : nil,force:force,config:$0)
                }
                try Task.checkCancellation()
                guard let index=localCopies.firstIndex(where:{$0.id==id}) else{return}
                localCopies[index].revision=revision;localCopies[index].remotePath=path;localCopies[index].lastUploadedAt = .now
                persist();message="已上传本次修改；后续本地修改仍需明确上传。"
            }catch DesktopFileError.conflict{localCopyConflictID=id;localCopyConflictDestination=destination}
            catch is CancellationError{message="上传已取消，本地副本保留。"}
            catch{self.error=error.localizedDescription;message="上传失败，本地副本保留。"}
        }
    }
    func forgetLocalCopy(_ id:UUID) {
        guard !busy else{return};localCopies.removeAll{$0.id==id};persist()
    }
    func open(_ items: [RemoteFileItem], access: DesktopFileAccess, encoding: RemoteTextEncoding? = nil) {
        guard !busy else { return }
        register(access); busy = true; error = nil; activeServerID = access.server.id
        let endpointIdentity = access.endpointIdentity
        operation = Task {
            defer { busy = false; operation = nil; activeServerID = nil }
            do {
                for item in items {
                    try Task.checkCancellation()
                    if let existing = documents.first(where: { $0.serverID == access.server.id && $0.path == item.path }) {
                        selectedID = existing.id; continue
                    }
                    guard item.kind == .file else { throw DesktopFileError.unsupportedFile }
                    guard documents.count < DesktopFilePreferences.editorFileLimit else {
                        throw DesktopFileError.operation("同时打开文件数达到限制（\(DesktopFilePreferences.editorFileLimit)）。可在 SFTP 设置调整。")
                    }
                    let remaining = DesktopFilePreferences.editorByteLimit - documents.reduce(0) { $0 + $1.original.count }
                    guard remaining > 0 else { throw DesktopFileError.tooLarge }
                    let (data, revision) = try await access.perform(matching: endpointIdentity) { try await DesktopFileOperations.read(path: item.path, config: $0, limit: remaining) }
                    try Task.checkCancellation()
                    let decoded = try RemoteTextEncoding.decode(data, preferred: encoding)
                    let doc = RemoteEditorDraft(serverID: access.server.id, serverName: access.server.displayName,
                        path: item.path, text: decoded.0, encoding: decoded.1, hasBOM: decoded.2, original: data, revision: revision, endpointIdentity: endpointIdentity)
                    documents.append(doc); selectedID = doc.id
                }
                persist()
            } catch is CancellationError { message = "已取消读取" }
            catch { self.error = error.localizedDescription }
        }
    }
    func updateText(_ value: String, id: UUID) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[index].text = value
        schedulePersist()
    }
    func changeEncoding(_ value: RemoteTextEncoding, id: UUID) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        do {
            _ = try value.encode(documents[index].text, bom: documents[index].hasBOM)
            documents[index].encoding = value; persist()
        } catch { self.error = error.localizedDescription }
    }
    func save(_ id: UUID, force: Bool = false, as destination: String? = nil) {
        guard !busy, let doc = documents.first(where: { $0.id == id }), let access = accesses[doc.serverID] else { return }
        guard doc.endpointIdentity == nil || doc.endpointIdentity == access.endpointIdentity else { error = "主机地址或用户已变化，请下载本地草稿后重新打开远程文件。"; return }
        busy = true; error = nil; conflictID = nil; activeServerID = doc.serverID
        operation = Task {
            defer { busy = false; operation = nil; activeServerID = nil }
            do {
                let data = try doc.encoding.encode(doc.text, bom: doc.hasBOM)
                guard data.count <= DesktopFilePreferences.editorByteLimit else { throw DesktopFileError.tooLarge }
                let path = destination ?? doc.path
                let revision = try await access.perform(matching: doc.endpointIdentity) {
                    try await DesktopFileOperations.save(data: data, path: path, expected: path == doc.path ? doc.revision : nil, force: force, config: $0)
                }
                try Task.checkCancellation()
                guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
                documents[index].original = data; documents[index].revision = revision; documents[index].path = path
                message = "已保存 \((path as NSString).lastPathComponent)"; persist()
            } catch DesktopFileError.conflict { conflictID = id; conflictDestination = destination }
            catch is CancellationError { message = "保存已取消，本地草稿仍保留" }
            catch { self.error = error.localizedDescription; persist() }
        }
    }
    func reload(_ id: UUID) {
        guard !busy, let doc = documents.first(where: { $0.id == id }), let access = accesses[doc.serverID] else { return }
        guard doc.endpointIdentity == nil || doc.endpointIdentity == access.endpointIdentity else { error = "主机地址或用户已变化，请保留草稿并重新打开远程文件。"; return }
        busy = true; conflictID = nil; error = nil; activeServerID = doc.serverID
        operation = Task {
            defer { busy = false; operation = nil; activeServerID = nil }
            do {
                let (data, revision) = try await access.perform(matching: doc.endpointIdentity) { try await DesktopFileOperations.read(path: doc.path, config: $0, limit: DesktopFilePreferences.editorByteLimit) }
                let decoded = try RemoteTextEncoding.decode(data, preferred: doc.encoding)
                try Task.checkCancellation()
                guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
                documents[index].text = decoded.0; documents[index].hasBOM = decoded.2
                documents[index].original = data; documents[index].revision = revision; persist()
            } catch { self.error = error.localizedDescription }
        }
    }
    func close(_ id: UUID) {
        guard !busy else { return }
        documents.removeAll { $0.id == id }
        if selectedID == id { selectedID = documents.last?.id }
        persist()
    }
    func cancel() { operation?.cancel() }
    func persist() {
        persistTask?.cancel()
        guard let url = persistURL else { return }
        do {
            try DesktopFilePreferences.writePrivate(JSONEncoder().encode(documents), to: url)
            if let copiesURL{try DesktopFilePreferences.writePrivate(JSONEncoder().encode(localCopies),to:copiesURL)}
        }
        catch { self.error = "无法保存本地恢复草稿：\(error.localizedDescription)" }
    }
    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { try? await Task.sleep(for: .milliseconds(350)); if !Task.isCancelled { persist() } }
    }
}

struct RemoteEditorView: View {
    @ObservedObject private var store: RemoteEditorStore
    init(store: RemoteEditorStore) { self.store = store }
    @MainActor init() { self.store = .shared }
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var searchStep = 0
    @FocusState private var searchFocused: Bool
    @State private var pendingClose: UUID?
    @State private var pendingReload: UUID?
    @State private var saveAsID: UUID?
    @State private var saveAsPath = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("远程文件编辑器", systemImage: "doc.text").font(.headline)
                Spacer()
                Button("关闭标签") {
                    if let doc=store.selected { if doc.isDirty {pendingClose=doc.id} else {store.close(doc.id)} }
                }.keyboardShortcut("w").disabled(store.selectedID == nil || store.busy)
                if store.busy { ProgressView().controlSize(.small); Button("取消操作") { store.cancel() } }
                Button("完成") { store.persist(); dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(14)
            Divider()
            ScrollView(.horizontal) {
                HStack(spacing: 3) {
                    ForEach(store.documents) { doc in
                        HStack(spacing: 6) {
                            Button { store.selectedID = doc.id } label: { Text((doc.isDirty ? "● " : "") + doc.title).lineLimit(1) }
                            Button { if doc.isDirty { pendingClose = doc.id } else { store.close(doc.id) } } label: { Image(systemName: "xmark").font(.caption2) }
                                .disabled(store.busy).accessibilityLabel("关闭 \(doc.title)")
                        }.buttonStyle(.plain).padding(.horizontal,12).padding(.vertical,10)
                            .background(store.selectedID == doc.id ? Color.accentColor.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                    }
                }.padding(5)
            }.background(.bar)
            if let doc = store.selected {
                HStack(spacing: 12) {
                    VStack(alignment: .leading) { Text(doc.title).font(.headline); Text("\(doc.serverName) · \(doc.path)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer(minLength: 10)
                    Button { searchFocused = true } label: { Image(systemName:"magnifyingglass") }.keyboardShortcut("f").help("搜索文件")
                    TextField("搜索", text: $search).textFieldStyle(.roundedBorder).frame(width:140).focused($searchFocused).onSubmit { searchStep += 1 }
                    Button { searchStep -= 1 } label: { Image(systemName:"chevron.up") }.help("上一个匹配").disabled(search.isEmpty)
                    Button { searchStep += 1 } label: { Image(systemName:"chevron.down") }.help("下一个匹配").disabled(search.isEmpty)
                    Picker("编码", selection: Binding(get: { doc.encoding }, set: { store.changeEncoding($0,id:doc.id) })) {
                        ForEach(RemoteTextEncoding.allCases) { Text($0.rawValue).tag($0) }
                    }.frame(width:160)
                    Button { if doc.isDirty { pendingReload = doc.id } else { store.reload(doc.id) } } label: { Image(systemName:"arrow.clockwise") }.help("重新读取远程文件").disabled(!store.canSave(doc.id))
                    Button { exportLocal(doc) } label: { Image(systemName:"square.and.arrow.down") }.help("下载当前文档与本地更改")
                    Button("另存为…") { saveAsID=doc.id; saveAsPath=doc.path }.disabled(!store.canSave(doc.id))
                    Button("保存") { store.save(doc.id) }.buttonStyle(.borderedProminent).keyboardShortcut("s").disabled(!store.canSave(doc.id) || !doc.isDirty)
                }.padding(12)
                Divider()
                NativeRemoteCodeEditor(text: Binding(get: { store.documents.first(where:{$0.id==doc.id})?.text ?? "" }, set: { store.updateText($0,id:doc.id) }), search: search, searchStep: searchStep)
                    .id(doc.id).frame(maxWidth:.infinity,maxHeight:.infinity).clipped()
                Divider()
                HStack {
                    Text(store.message.isEmpty ? "更改保留在本机草稿；保存会检查远端版本。" : store.message).lineLimit(1)
                    Spacer()
                    Text("\(doc.text.components(separatedBy:"\n").count) 行 · \(doc.text.count) 字符 · \(doc.encoding.rawValue)")
                    Text(doc.text.contains("\r\n") ? "CRLF" : "LF")
                }.font(.caption).foregroundStyle(.secondary).padding(10)
                if !store.canSave(doc.id), !store.busy {
                    Text("此恢复草稿尚未连接主机。请在该主机的文件面板中重新打开文件，以核验连接并保存。")
                        .font(.caption).foregroundStyle(.secondary).padding(8)
                }
            } else { ContentUnavailableView("未打开文件", systemImage:"doc.text", description:Text("在 SFTP 文件面板中选择“编辑”。")).frame(maxHeight:.infinity) }
        }
        .frame(minWidth: 860, idealWidth:1100, minHeight:600, idealHeight:740)
        .background(Color.appGround)
        .alert("文件操作失败",isPresented:Binding(get:{store.error != nil},set:{if !$0 {store.error=nil}})) { Button("好") {store.error=nil} } message:{Text(store.error ?? "")}
        .confirmationDialog("关闭并丢弃这个文件的本地草稿？",isPresented:Binding(get:{pendingClose != nil},set:{if !$0 {pendingClose=nil}})) {
            Button("丢弃并关闭",role:.destructive) {if let id=pendingClose {store.close(id)}; pendingClose=nil}
            Button("继续编辑",role:.cancel) {pendingClose=nil}
        }
        .confirmationDialog("重新载入会丢弃本地更改",isPresented:Binding(get:{pendingReload != nil},set:{if !$0 {pendingReload=nil}})) {
            Button("重新载入",role:.destructive) {if let id=pendingReload {store.reload(id)}; pendingReload=nil}
        }
        .confirmationDialog("远程文件已经变化",isPresented:Binding(get:{store.conflictID != nil},set:{if !$0 {store.conflictID=nil}})) {
            Button("重新载入远程版本",role:.destructive) { if let id=store.conflictID {store.reload(id)} }
            Button("另存为…") {saveAsID=store.conflictID; saveAsPath=store.selected?.path ?? ""; store.conflictID=nil}
            Button("覆盖远程版本",role:.destructive) {if let id=store.conflictID {store.save(id,force:true,as:store.conflictDestination)}}
            Button("继续编辑",role:.cancel) {store.conflictID=nil}
        } message:{Text("远程文件被其他操作修改或删除。本地草稿仍然保留。")}
        .alert("另存为远程文件",isPresented:Binding(get:{saveAsID != nil},set:{if !$0 {saveAsID=nil}})) {
            TextField("完整远程路径",text:$saveAsPath)
            Button("取消",role:.cancel) {saveAsID=nil}
            Button("保存") {if let id=saveAsID {store.save(id,as:saveAsPath)};saveAsID=nil}
        }
        .onDisappear {store.persist()}
    }
    private func exportLocal(_ doc: RemoteEditorDraft) {
        let panel=NSSavePanel();panel.nameFieldStringValue=doc.title
        guard panel.runModal() == .OK,let url=panel.url else{return}
        do {try doc.encoding.encode(doc.text,bom:doc.hasBOM).write(to:url,options:.atomic)}
        catch{store.error=error.localizedDescription}
    }

}

struct LocalFileCopiesView:View {
    @ObservedObject private var store:RemoteEditorStore
    private let serverID:UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var saveAsID:UUID?
    @State private var saveAsPath=""
    @MainActor init(serverID:UUID?=nil){store = .shared;self.serverID=serverID}
    init(store:RemoteEditorStore,serverID:UUID?=nil){self.store=store;self.serverID=serverID}
    private var copies:[RemoteLocalCopy]{store.localCopies.filter{serverID == nil || $0.serverID==serverID}}
    var body:some View {
        VStack(alignment:.leading,spacing:14){
            HStack{Label("本地副本与上传修改",systemImage:"arrow.up.doc").font(.title2.bold());Spacer();Button("完成"){dismiss()}}
            Text("在本地应用中编辑副本后，选择“上传修改”明确写回远端。上传前会核对远端版本，失败时保留副本。")
                .font(.callout).foregroundStyle(.secondary)
            if copies.isEmpty {
                ContentUnavailableView("尚无本地副本",systemImage:"doc.on.doc",description:Text("在文件面板右键选择“用本地程序打开”。"))
                    .frame(maxWidth:.infinity,maxHeight:.infinity)
            }else{
                List(copies){copy in
                    VStack(alignment:.leading,spacing:8){
                        HStack(alignment:.top){
                            VStack(alignment:.leading,spacing:4){
                                Text(copy.title).font(.headline)
                                Text("\(copy.serverName) · \(copy.remotePath)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button("打开副本"){if !NSWorkspace.shared.open(URL(fileURLWithPath:copy.localPath)){store.error="无法打开本地副本，请用访达检查文件是否存在。"}}
                            Button("上传修改"){store.uploadLocalCopy(copy.id)}.buttonStyle(.borderedProminent).disabled(!store.canUploadLocalCopy(copy))
                        }
                        HStack{
                            Text(copy.localPath).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("访达"){NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:copy.localPath)])}
                            Button("移除记录"){store.forgetLocalCopy(copy.id)}.disabled(store.busy)
                        }
                        if !store.canUploadLocalCopy(copy),!store.busy{Text("主机未载入或端点已变化；副本仍保留在本机。").font(.caption).foregroundStyle(.secondary)}
                    }.padding(.vertical,8)
                }.listStyle(.inset)
            }
            HStack{
                if store.busy{ProgressView().controlSize(.small)}
                Text(store.message.isEmpty ? "移除记录会保留本地文件。副本不参与配置同步。" : store.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if store.busy{Button("取消操作"){store.cancel()}}
            }
        }.padding(20).frame(width:900,height:520).background(Color.appGround)
        .alert("本地副本操作失败",isPresented:Binding(get:{store.error != nil},set:{if !$0{store.error=nil}})){
            Button("好"){store.error=nil}
        }message:{Text(store.error ?? "")}
        .confirmationDialog("远端文件已经变化",isPresented:Binding(get:{store.localCopyConflictID != nil},set:{if !$0{store.localCopyConflictID=nil}})){
            Button("保留副本，暂不上传",role:.cancel){store.localCopyConflictID=nil}
            Button("另存为远端文件…"){
                saveAsID=store.localCopyConflictID
                saveAsPath=store.localCopies.first(where:{$0.id==saveAsID})?.remotePath ?? ""
                store.localCopyConflictID=nil
            }
            Button("覆盖远端版本",role:.destructive){if let id=store.localCopyConflictID{store.uploadLocalCopy(id,force:true,as:store.localCopyConflictDestination)}}
        }message:{Text("本地副本保留。可另存为其他路径，或明确覆盖远端的新版本。")}
        .alert("另存为远端文件",isPresented:Binding(get:{saveAsID != nil},set:{if !$0{saveAsID=nil}})){
            TextField("完整远端路径",text:$saveAsPath)
            Button("取消",role:.cancel){saveAsID=nil}
            Button("上传修改"){if let id=saveAsID{store.uploadLocalCopy(id,as:saveAsPath)};saveAsID=nil}
        }
    }
}

private struct NativeRemoteCodeEditor: NSViewRepresentable {
    @Binding var text: String
    var search: String
    var searchStep: Int
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller=true; scroll.hasHorizontalScroller=true
        let editor=NSTextView(frame:NSRect(x:0,y:0,width:800,height:500))
        editor.isRichText=false; editor.isAutomaticQuoteSubstitutionEnabled=false; editor.isAutomaticDashSubstitutionEnabled=false
        editor.isAutomaticTextReplacementEnabled=false; editor.isAutomaticSpellingCorrectionEnabled=false; editor.isContinuousSpellCheckingEnabled=false
        editor.allowsUndo=true; editor.font = .monospacedSystemFont(ofSize:13,weight:.regular)
        editor.textColor = .textColor; editor.backgroundColor = .textBackgroundColor
        editor.isVerticallyResizable=true; editor.isHorizontallyResizable=true
        editor.autoresizingMask=[.width]; editor.textContainer?.widthTracksTextView=false
        editor.textContainer?.containerSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        editor.minSize=NSSize(width:0,height:0);editor.maxSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        editor.delegate=context.coordinator;editor.string=text
        scroll.documentView=editor
        scroll.hasVerticalRuler=true;scroll.rulersVisible=true;scroll.verticalRulerView=EditorLineRuler(textView:editor,scrollView:scroll)
        context.coordinator.editor=editor;context.coordinator.highlight()
        return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) {
        context.coordinator.parent=self
        guard let editor=context.coordinator.editor else{return}
        if editor.string != text { editor.string=text;context.coordinator.highlight();scroll.verticalRulerView?.needsDisplay=true }
        if context.coordinator.lastSearch != search || context.coordinator.lastStep != searchStep {
            let queryChanged = context.coordinator.lastSearch != search
            let backwards = searchStep < context.coordinator.lastStep
            context.coordinator.lastSearch=search; context.coordinator.lastStep=searchStep
            if !search.isEmpty {
                let value=editor.string as NSString
                let selection=editor.selectedRange()
                let start=queryChanged ? 0 : min(value.length,backwards ? selection.location : NSMaxRange(selection))
                let scope=backwards && !queryChanged ? NSRange(location:0,length:start) : NSRange(location:start,length:value.length-start)
                var options:NSString.CompareOptions = [.caseInsensitive]
                if backwards {options.insert(.backwards)}
                var match=value.range(of:search,options:options,range:scope)
                if match.location == NSNotFound {match=value.range(of:search,options:options)}
                if match.location != NSNotFound {editor.setSelectedRange(match);editor.scrollRangeToVisible(match)}
            }
        }
    }
    final class Coordinator:NSObject,NSTextViewDelegate {
        var parent:NativeRemoteCodeEditor
        weak var editor:NSTextView?
        var lastSearch=""
        var lastStep=0
        var pending:DispatchWorkItem?
        init(_ parent:NativeRemoteCodeEditor){self.parent=parent}
        func textDidChange(_ notification:Notification) {
            guard let editor else{return};parent.text=editor.string;editor.enclosingScrollView?.verticalRulerView?.needsDisplay=true
            pending?.cancel();let work=DispatchWorkItem{[weak self] in self?.highlight()};pending=work
            DispatchQueue.main.asyncAfter(deadline:.now()+0.2,execute:work)
        }
        func highlight() {
            guard let editor,let storage=editor.textStorage else{return}
            let range=NSRange(location:0,length:storage.length)
            storage.beginEditing();storage.addAttribute(.foregroundColor,value:NSColor.textColor,range:range)
            if storage.length<200_000 {
                let patterns:[(String,NSColor)] = [
                    (#"</?[A-Za-z][A-Za-z0-9:-]*"#,.systemOrange),
                    (#"\b[A-Za-z_][\w-]*(?=\s*[:=])"#,.systemTeal),
                    (#"\b(?:if|else|for|while|return|func|function|class|struct|import|from|let|var|const|true|false|null|nil|def|try|catch|throw|async|await|public|private)\b"#,.systemPurple),
                    (#"\b[0-9]+(?:\.[0-9]+)?\b"#,.systemOrange),
                    (#"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'"#,.systemGreen),
                    (#"(?m)(?://[^\n]*|#[^\n]*|<!--[^\n]*-->)"#,.secondaryLabelColor)]
                for (pattern,color) in patterns {
                    guard let regex=try? NSRegularExpression(pattern:pattern) else{continue}
                    regex.enumerateMatches(in:storage.string,range:range){match,_,_ in if let match {storage.addAttribute(.foregroundColor,value:color,range:match.range)}}
                }
            }
            storage.endEditing()
        }
    }
}

private final class EditorLineRuler:NSRulerView {
    weak var editor:NSTextView?
    init(textView:NSTextView,scrollView:NSScrollView){editor=textView;super.init(scrollView:scrollView,orientation:.verticalRuler);clientView=textView;ruleThickness=48}
    required init(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
    override func drawHashMarksAndLabels(in rect:NSRect) {
        guard let editor,let manager=editor.layoutManager,let container=editor.textContainer else{return}
        let visible=editor.visibleRect;let glyphs=manager.glyphRange(forBoundingRect:visible,in:container)
        let string=editor.string as NSString
        guard manager.numberOfGlyphs > 0 else { return }
        let firstCharacter=manager.characterIndexForGlyph(at:min(glyphs.location,manager.numberOfGlyphs-1))
        var line=string.substring(to:min(firstCharacter,string.length)).components(separatedBy:"\n").count
        let attributes:[NSAttributedString.Key:Any]=[.font:NSFont.monospacedDigitSystemFont(ofSize:11,weight:.regular),.foregroundColor:NSColor.secondaryLabelColor]
        manager.enumerateLineFragments(forGlyphRange:glyphs){fragment,_,_,_,_ in
            let label="\(line)" as NSString
            label.draw(at:NSPoint(x:40-label.size(withAttributes:attributes).width,y:fragment.minY-visible.minY+editor.textContainerInset.height),withAttributes:attributes)
            line+=1
        }
    }
}
#endif
