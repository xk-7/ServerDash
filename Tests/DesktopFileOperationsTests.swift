import XCTest
import Foundation
import AppKit
import SwiftUI
import SwiftData
@testable import ServerDash

final class DesktopFileOperationsTests: XCTestCase {
    private func fixture() throws -> URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("serverdash-file-tests-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        addTeardownBlock {try? FileManager.default.removeItem(at:root)}
        return root.resolvingSymlinksInPath()
    }
    private func run(_ payload:[String:Any]) throws -> DesktopFileOperations.Response {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath:"/usr/bin/python3"),"Python fixture runtime is unavailable")
        let process=Process(),output=Pipe(),error=Pipe()
        process.executableURL=URL(fileURLWithPath:"/usr/bin/python3")
        process.arguments=["-c",DesktopFileOperations.remoteScript,String(decoding:try JSONSerialization.data(withJSONObject:payload),as:UTF8.self)]
        process.standardOutput=output;process.standardError=error
        try process.run();let data=output.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus,0,String(decoding:error.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self))
        return try JSONDecoder().decode(DesktopFileOperations.Response.self,from:data)
    }
    func testLiteralPathsAndShellQuotingNeverBecomeInstructions() throws {
        let root=try fixture(),path=root.appendingPathComponent("中文 * ? [x] ' \" $(`echo`) file.txt")
        try Data("hello".utf8).write(to:path)
        let response=try run(["action":"inspect","path":path.path])
        XCTAssertTrue(response.ok);XCTAssertEqual(response.metadata?.revision?.sha256,DesktopFileOperations.digest(Data("hello".utf8)))
        XCTAssertEqual(DesktopFileOperations.shellQuote("a'b"),"'a'\\''b'")
        XCTAssertEqual(SFTPService.quote("[a]*?.txt"), "\"[a]*?.txt\"")
        XCTAssertThrowsError(try SFTPService.validatePath("/tmp/file\nrm other"))
        XCTAssertThrowsError(try SFTPService.validatePath("/tmp/file\u{0}"))
        XCTAssertTrue(DesktopFilePreferences.root.lastPathComponent.hasPrefix("serverdash-remote-files-tests-"))
    }
    func testSystemSFTPPreservesLiteralNamesWithoutNetworkOrCredentials() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath:"/usr/libexec/sftp-server"))
        let root=try fixture()
        for (index,name) in ["glob[*]?.txt", "quote\"x.txt", "back\\slash.txt", "中文 空格.txt"].enumerated() {
            let source=root.appendingPathComponent(name), target=root.appendingPathComponent("download-\(index)")
            let data=Data("literal-\(index)".utf8);try data.write(to:source)
            let process=Process(), input=Pipe(), output=Pipe()
            process.executableURL=URL(fileURLWithPath:"/usr/bin/sftp")
            process.arguments=["-D","/usr/libexec/sftp-server"]
            process.standardInput=input;process.standardOutput=output;process.standardError=output
            try process.run()
            try input.fileHandleForWriting.write(contentsOf:Data("get \(SFTPService.quote(source.path)) \(SFTPService.quote(target.path))\nbye\n".utf8))
            try input.fileHandleForWriting.close()
            _ = output.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus,0);XCTAssertEqual(try Data(contentsOf:target),data)
        }
    }
    func testAtomicEditorCommitDetectsConcurrentChangesAndPreservesMode() throws {
        let root=try fixture(),file=root.appendingPathComponent("config.json"),stage=root.appendingPathComponent(".serverdash-edit-test")
        try Data("before".utf8).write(to:file)
        try FileManager.default.setAttributes([.posixPermissions:0o640],ofItemAtPath:file.path)
        let original=try XCTUnwrap(run(["action":"inspect","path":file.path]).metadata?.revision)
        XCTAssertTrue(try run(["action":"prepare","path":file.path,"stage":stage.path]).ok)
        let newData=Data("after".utf8);try newData.write(to:stage)
        let expected=try JSONSerialization.jsonObject(with:JSONEncoder().encode(original))
        let payload:[String:Any]=["action":"commit","path":file.path,"stage":stage.path,"expected":expected,"digest":DesktopFileOperations.digest(newData)]
        try Data("external".utf8).write(to:file)
        let conflict=try run(payload)
        XCTAssertFalse(conflict.ok);XCTAssertEqual(conflict.error,"conflict")
        XCTAssertEqual(try String(contentsOf:file,encoding:.utf8),"external")
        var forced=payload;forced["force"]=true
        let saved=try run(forced)
        XCTAssertTrue(saved.ok);XCTAssertEqual(saved.metadata?.revision?.mode,0o640)
        XCTAssertEqual(try Data(contentsOf:file),newData);XCTAssertFalse(FileManager.default.fileExists(atPath:stage.path))
    }
    func testNewFileSaveRejectsAppearingDestinationAndSymlinks() throws {
        let root=try fixture(),file=root.appendingPathComponent("new.txt"),stage=root.appendingPathComponent(".serverdash-edit-test")
        XCTAssertTrue(try run(["action":"prepare","path":file.path,"stage":stage.path]).ok)
        let data=Data("draft".utf8);try data.write(to:stage);try Data("other".utf8).write(to:file)
        let result=try run(["action":"commit","path":file.path,"stage":stage.path,"digest":DesktopFileOperations.digest(data)])
        XCTAssertEqual(result.error,"conflict");XCTAssertEqual(try String(contentsOf:file,encoding:.utf8),"other")
        let link=root.appendingPathComponent("link");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:file)
        XCTAssertFalse(try run(["action":"prepare","path":link.path,"stage":root.appendingPathComponent(".serverdash-edit-link").path]).ok)
    }
    func testCopyMoveArchiveAndPermissionsUseLiteralPaths() throws {
        let root=try fixture(),source=root.appendingPathComponent("source folder"),target=root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
        try Data("payload".utf8).write(to:source.appendingPathComponent("file[*].txt"))
        let link=source.appendingPathComponent("linked");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:root)
        XCTAssertTrue(try run(["action":"copy","paths":[source.path],"destination":target.path,"policy":"skip"]).ok)
        XCTAssertEqual(try Data(contentsOf:target.appendingPathComponent("source folder/file[*].txt")),Data("payload".utf8))
        XCTAssertTrue((try target.appendingPathComponent("source folder/linked").resourceValues(forKeys:[.isSymbolicLinkKey])).isSymbolicLink == true)
        XCTAssertFalse(try run(["action":"copy","paths":[source.path],"destination":source.path]).ok)
        for format in ["zip","tar.gz"] {
            let archive=root.appendingPathComponent("archive."+format)
            XCTAssertTrue(try run(["action":"archive","paths":[source.path],"destination":archive.path,"format":format]).ok)
            XCTAssertTrue(FileManager.default.fileExists(atPath:archive.path))
            XCTAssertFalse(try run(["action":"archive","paths":[source.path],"destination":archive.path,"format":format]).ok)
        }
        XCTAssertTrue(try run(["action":"chmod","paths":[source.appendingPathComponent("file[*].txt").path],"mode":0o600]).ok)
        XCTAssertFalse(try run(["action":"chmod","paths":[link.path],"mode":0o600]).ok)
        XCTAssertTrue(try run(["action":"move","paths":[source.appendingPathComponent("file[*].txt").path],"destination":target.path,"policy":"skip"]).ok)
        XCTAssertFalse(FileManager.default.fileExists(atPath:source.appendingPathComponent("file[*].txt").path))
    }
    func testEncodingRoundTripAndBinaryRejection() throws {
        let text="中文 café\r\n第二行\r\n"
        for encoding in RemoteTextEncoding.allCases {
            let data=try encoding.encode(text,bom:encoding != .gb18030)
            let decoded=try RemoteTextEncoding.decode(data,preferred:encoding)
            XCTAssertEqual(decoded.0,text);XCTAssertEqual(try decoded.1.encode(decoded.0,bom:decoded.2),data)
        }
        XCTAssertThrowsError(try RemoteTextEncoding.decode(Data([0,1,2,3])))
        XCTAssertThrowsError(try RemoteTextEncoding.decode(Data([0xFF,0xA2])))
    }
    @MainActor func testLocalCopyTracksOriginalVersionAndForgettingPreservesFile() throws {
        let root=try fixture(),file=root.appendingPathComponent("document.txt"),originalData=Data("original".utf8)
        try originalData.write(to:file)
        let revision=RemoteFileRevision(size:Int64(originalData.count),modifiedNS:1,inode:42,mode:0o644,uid:1,gid:1,sha256:DesktopFileOperations.digest(originalData))
        let copy=RemoteLocalCopy(serverID:UUID(),serverName:"fixture",remotePath:"/remote/document.txt",localPath:file.path,endpointIdentity:"fixture.invalid|22|test",revision:revision)
        XCTAssertNil(try copy.modifiedContents())
        XCTAssertEqual(try copy.modifiedContents(includeUnchanged:true),originalData)
        let changed=Data("edited in a local application".utf8);try changed.write(to:file)
        XCTAssertEqual(try copy.modifiedContents(),changed);XCTAssertEqual(copy.revision,revision)
        let drafts=root.appendingPathComponent("drafts.json"),store=RemoteEditorStore(persistURL:drafts,restore:false)
        store.localCopies=[copy];store.persist()
        let restored=RemoteEditorStore(persistURL:drafts)
        XCTAssertEqual(restored.localCopies.first?.revision,revision)
        XCTAssertEqual(restored.localCopies.first?.endpointIdentity,copy.endpointIdentity)
        restored.forgetLocalCopy(copy.id)
        XCTAssertEqual(try Data(contentsOf:file),changed);XCTAssertTrue(restored.localCopies.isEmpty)
        let link=root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:file)
        var linked=copy;linked.localPath=link.path
        XCTAssertThrowsError(try linked.modifiedContents())
        store.shutdown();restored.shutdown()
    }
    func testThreeWaySyncRequiresExplicitDeletionResolutionAndFlagsConflicts() {
        let a=DirectoryManifestEntry(path:"file",kind:"file",size:1,sha256:"a",modifiedNS:1)
        let b=DirectoryManifestEntry(path:"file",kind:"file",size:1,sha256:"b",modifiedNS:2)
        let baseline=["file":DirectorySyncBaseline(local:"file:a",remote:"file:a")]
        XCTAssertEqual(DirectorySyncPlanner.plan(local:[a],remote:[b],baseline:baseline).first?.action,.download)
        XCTAssertEqual(DirectorySyncPlanner.plan(local:[b],remote:[a],baseline:baseline).first?.action,.upload)
        XCTAssertEqual(DirectorySyncPlanner.plan(local:[a],remote:[b],baseline:[:]).first?.action,.conflict)
        var deletedLocal=DirectorySyncPlanner.plan(local:[],remote:[b],baseline:baseline)[0]
        XCTAssertEqual(deletedLocal.action,.deletionConflict);XCTAssertFalse(deletedLocal.included)
        XCTAssertEqual(deletedLocal.selectedAction,.skip)
        deletedLocal.resolution = .deleteRemote;deletedLocal.included=true
        XCTAssertEqual(deletedLocal.selectedAction,.deleteRemote)
        XCTAssertTrue(DirectorySyncPlanner.automaticUploads([deletedLocal],previousLocal:[]).isEmpty)
        let deletedRemote=DirectorySyncPlanner.plan(local:[b],remote:[],baseline:baseline)[0]
        XCTAssertEqual(deletedRemote.action,.deletionConflict);XCTAssertEqual(deletedRemote.selectedAction,.skip)
        XCTAssertEqual(DirectorySyncPlanner.plan(local:[a],remote:[],baseline:[:]).first?.action,.upload)
        XCTAssertTrue(DirectorySyncPlanner.plan(local:[a],remote:[a],baseline:[:]).isEmpty)
    }
    func testRemoteSyncDeletionChecksVersionsAndOnlyRemovesEmptyDirectories() throws {
        let root=try fixture(),directory=root.appendingPathComponent("folder"),file=directory.appendingPathComponent("data.txt")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try Data("before".utf8).write(to:file)
        let entries=try XCTUnwrap(run(["action":"manifest","path":root.path]).entries)
        let expectedFile=try XCTUnwrap(entries.first(where:{$0.path=="folder/data.txt"}))
        let expectedDirectory=try XCTUnwrap(entries.first(where:{$0.path=="folder"}))
        func delete(_ path:URL,_ expected:DirectoryManifestEntry)throws->DesktopFileOperations.Response {
            try run(["action":"delete","path":path.path,"expectedEntry":JSONSerialization.jsonObject(with:JSONEncoder().encode(expected))])
        }
        XCTAssertFalse(try delete(directory,expectedDirectory).ok)
        XCTAssertEqual(try String(contentsOf:file,encoding:.utf8),"before")
        try Data("changed after preview".utf8).write(to:file)
        XCTAssertEqual(try delete(file,expectedFile).error,"conflict")
        let refreshed=try XCTUnwrap(run(["action":"manifest","path":root.path]).entries?.first(where:{$0.path=="folder/data.txt"}))
        XCTAssertTrue(try delete(file,refreshed).ok)
        XCTAssertTrue(try delete(directory,expectedDirectory).ok)
        XCTAssertFalse(FileManager.default.fileExists(atPath:directory.path))
        XCTAssertEqual(try run(["action":"exists","path":file.path]).exists,false)
        let outside=root.appendingPathComponent("outside.txt"),link=root.appendingPathComponent("link")
        try Data("preserve".utf8).write(to:outside)
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:outside)
        XCTAssertFalse(try delete(link,refreshed).ok)
        XCTAssertEqual(try String(contentsOf:outside,encoding:.utf8),"preserve")
    }
    func testLocalSyncDeletionChecksVersionsAndCannotRecursivelyDeleteNewChildren() throws {
        let root=try fixture(),directory=root.appendingPathComponent("folder"),file=directory.appendingPathComponent("data.txt")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try Data("before".utf8).write(to:file)
        let entries=try DirectorySyncPlanner.localManifest(root:root)
        let expectedFile=try XCTUnwrap(entries.first(where:{$0.path=="folder/data.txt"}))
        let expectedDirectory=try XCTUnwrap(entries.first(where:{$0.path=="folder"}))
        XCTAssertThrowsError(try DirectorySyncPlanner.deleteLocal(relative:"folder",root:root,expected:expectedDirectory))
        try Data("external change".utf8).write(to:file)
        XCTAssertThrowsError(try DirectorySyncPlanner.deleteLocal(relative:"folder/data.txt",root:root,expected:expectedFile))
        let refreshed=try XCTUnwrap(DirectorySyncPlanner.localManifest(root:root).first(where:{$0.path=="folder/data.txt"}))
        try DirectorySyncPlanner.deleteLocal(relative:"folder/data.txt",root:root,expected:refreshed)
        XCTAssertTrue(try DirectorySyncPlanner.localIsAbsent(file))
        try DirectorySyncPlanner.deleteLocal(relative:"folder",root:root,expected:expectedDirectory)
        XCTAssertTrue(try DirectorySyncPlanner.localIsAbsent(directory))
        let target=root.appendingPathComponent("target"),link=root.appendingPathComponent("link")
        try Data("preserve".utf8).write(to:target)
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:target)
        XCTAssertFalse(try DirectorySyncPlanner.localIsAbsent(link))
        XCTAssertThrowsError(try DirectorySyncPlanner.deleteLocal(relative:"link",root:root,expected:refreshed))
        XCTAssertEqual(try String(contentsOf:target,encoding:.utf8),"preserve")
    }
    func testAutomaticUploadOnlyIncludesNewOrChangedLocalFiles() {
        let old=DirectoryManifestEntry(path:"unchanged-but-deleted-remotely",kind:"file",size:1,sha256:"old",modifiedNS:1)
        let before=DirectoryManifestEntry(path:"edited",kind:"file",size:1,sha256:"old",modifiedNS:1)
        let after=DirectoryManifestEntry(path:"edited",kind:"file",size:1,sha256:"new",modifiedNS:2)
        let new=DirectoryManifestEntry(path:"new",kind:"file",size:1,sha256:"new",modifiedNS:2)
        let baseline=["edited":DirectorySyncBaseline(local:"file:old",remote:"file:old")]
        let plan=DirectorySyncPlanner.plan(local:[old,after,new],remote:[before],baseline:baseline)
        let automatic=DirectorySyncPlanner.automaticUploads(plan,previousLocal:[old,before])
        XCTAssertEqual(Set(automatic.map(\.path)),Set(["edited","new"]))
        XCTAssertFalse(automatic.contains(where:{$0.path==old.path}))
        XCTAssertTrue(DirectorySyncPlanner.automaticUploads(plan,previousLocal:[old,after,new]).isEmpty)
    }
    @MainActor func testDirectoryTasksMigrateOnceAndDeletedTasksDoNotReturnFromLegacyJSON() throws {
        let root=try fixture(),legacy=root.appendingPathComponent("pairs.json")
        let pair=DirectorySyncPair(serverID:UUID(),serverName:"fixture",localPath:root.path,remotePath:"/fixture/remote",endpointIdentity:"fixture.invalid|22|test",automaticUpload:true)
        try JSONEncoder().encode([pair]).write(to:legacy)
        let container=try ModelContainer(for:DirectorySyncTaskRecord.self,configurations:ModelConfiguration(isStoredInMemoryOnly:true))
        let store=DirectorySyncStore(url:legacy)
        store.configure(container:container)
        XCTAssertNil(store.error);XCTAssertEqual(store.pairs.count,1)
        let records=try container.mainContext.fetch(FetchDescriptor<DirectorySyncTaskRecord>())
        XCTAssertEqual(records.first?.id,pair.id);XCTAssertEqual(records.first?.remotePath,pair.remotePath)
        let binding=root.appendingPathComponent("machine-bindings.json")
        let json=try String(contentsOf:binding,encoding:.utf8)
        XCTAssertTrue(json.contains("localPath"));XCTAssertFalse(json.contains("remotePath"));XCTAssertFalse(json.contains("serverName"))
        store.remove(pair.id)
        let restored=DirectorySyncStore(url:legacy);restored.configure(container:container)
        XCTAssertTrue(restored.pairs.isEmpty)
        XCTAssertEqual(try JSONDecoder().decode([DirectorySyncPair].self,from:Data(contentsOf:legacy)).count,1)
        store.shutdown();restored.shutdown()
    }
    @MainActor func testRemovingServerDisablesAutomaticUploadAndRetainsLocalFiles() throws {
        let root=try fixture(),file=root.appendingPathComponent("preserved.txt"),legacy=root.appendingPathComponent("pairs.json")
        try Data("preserve".utf8).write(to:file)
        let server=ServerRecord(name:"fixture",host:"fixture.invalid",username:"test")
        let pair=DirectorySyncPair(serverID:server.id,serverName:"fixture",localPath:root.path,remotePath:"/fixture",automaticUpload:true)
        try JSONEncoder().encode([pair]).write(to:legacy)
        let store=DirectorySyncStore(url:legacy),app=AppState()
        store.register(DesktopFileAccess(server:server,appState:app));store.unregister(serverID:server.id)
        XCTAssertFalse(try XCTUnwrap(store.pairs.first).automaticUpload)
        XCTAssertEqual(try String(contentsOf:file,encoding:.utf8),"preserve")
        store.shutdown()
    }
    func testManifestSkipsLinkTraversalAndRejectsEscapingLocalPaths() throws {
        let root=try fixture(),directory=root.appendingPathComponent("local")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try Data("file".utf8).write(to:directory.appendingPathComponent("visible"))
        try FileManager.default.createSymbolicLink(at:directory.appendingPathComponent("link"),withDestinationURL:root)
        let manifest=try DirectorySyncPlanner.localManifest(root:directory)
        XCTAssertEqual(manifest.count,2);XCTAssertEqual(manifest.first(where:{$0.path=="link"})?.kind,"link")
        XCTAssertThrowsError(try DirectorySyncPlanner.localURL(relative:"../outside",root:directory))
        XCTAssertThrowsError(try DirectorySyncPlanner.localURL(relative:"link/outside",root:directory))
        let remote=try run(["action":"manifest","path":directory.path])
        XCTAssertEqual(remote.entries?.count,2)
    }
}

@MainActor final class DesktopFileUIFixtureTests: XCTestCase {
    func testNativeFilesAndEditorLightDarkFixtures() async throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("serverdash-file-ui-qa",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let app=AppState()
        let server=ServerRecord(name:"开发服务器 · 演示",host:"file-fixture.invalid",username:"operator")
        let controller=MacSFTPController(server:server,appState:app,automaticallyConnect:false)
        controller.currentPath="/home/operator/project";controller.pathText=controller.currentPath;controller.hasLoadedDirectory=true
        controller.items=[
            .init(path:"/home/operator/project/assets",name:"assets",kind:.directory,size:0,permissions:"drwxr-xr-x",owner:"operator",group:"staff",modifiedText:"Sep 8 18:20"),
            .init(path:"/home/operator/project/index.html",name:"index.html",kind:.file,size:1352,permissions:"-rw-r--r--",owner:"operator",group:"staff",modifiedText:"Sep 8 18:25"),
            .init(path:"/home/operator/project/config.json",name:"config.json",kind:.file,size:482,permissions:"-rw-r-----",owner:"operator",group:"staff",modifiedText:"Sep 8 18:22")]
        controller.statusMessage="已读取目录"
        let editor=RemoteEditorStore(persistURL:folder.appendingPathComponent("fixture-drafts.json"),restore:false)
        let content="<!DOCTYPE html>\n<html lang=\"zh-CN\">\n<head>\n  <meta charset=\"utf-8\">\n  <title>ServerDash</title>\n</head>\n<body>\n  <h1>你好，ServerDash</h1>\n</body>\n</html>\n"
        let data=Data(content.utf8)
        let revision=RemoteFileRevision(size:Int64(data.count),modifiedNS:1,inode:1,mode:0o644,uid:1,gid:1,sha256:DesktopFileOperations.digest(data))
        let doc=RemoteEditorDraft(serverID:server.id,serverName:server.name,path:"/home/operator/project/index.html",text:content,encoding:.utf8,hasBOM:false,original:data,revision:revision,endpointIdentity:nil)
        editor.documents=[doc];editor.selectedID=doc.id;editor.register(DesktopFileAccess(server:server,appState:app))
        editor.localCopies=[RemoteLocalCopy(serverID:server.id,serverName:server.name,remotePath:doc.path,
            localPath:"/Users/demo/Library/Application Support/ServerDash/RemoteFiles/LocalCopies/demo/index.html",endpointIdentity:server.connectionConfig.host.lowercased()+"|22|operator",revision:revision)]
        let sync=DirectorySyncStore(url:folder.appendingPathComponent("fixture-sync-pairs.json"))
        let pair=DirectorySyncPair(serverID:server.id,serverName:server.name,localPath:"/Users/demo/Projects/example",remotePath:"/home/operator/project")
        sync.pairs=[pair];sync.selectedPairID=pair.id
        let remote=DirectoryManifestEntry(path:"removed-locally.conf",kind:"file",size:482,sha256:"old",modifiedNS:1,inode:1)
        sync.plan=[DirectorySyncPlanEntry(path:remote.path,local:nil,remote:remote,action:.deletionConflict,included:false),
            DirectorySyncPlanEntry(path:"both-edited.json",local:remote,remote:remote,action:.conflict),
            DirectorySyncPlanEntry(path:"new.txt",local:remote,remote:nil,action:.upload)]
        sync.message="3 项差异；删除与双边修改默认跳过。"
        for dark in [false,true] {
            let scheme:ColorScheme=dark ? .dark : .light
            try await render(SFTPBrowserView(controller:controller,compact:true).environment(\.colorScheme,scheme),size:NSSize(width:390,height:700),name:"files-compact-\(dark ? "dark" : "light")",folder:folder,dark:dark)
            try await render(SFTPBrowserView(controller:controller).environment(\.colorScheme,scheme),size:NSSize(width:1100,height:700),name:"files-full-\(dark ? "dark" : "light")",folder:folder,dark:dark)
            try await render(RemoteEditorView(store:editor).environment(\.colorScheme,scheme),size:NSSize(width:1100,height:740),name:"editor-\(dark ? "dark" : "light")",folder:folder,dark:dark)
            try await render(LocalFileCopiesView(store:editor,serverID:server.id).environment(\.colorScheme,scheme),size:NSSize(width:900,height:520),name:"local-copies-\(dark ? "dark" : "light")",folder:folder,dark:dark)
            try await render(DirectorySyncView(access:DesktopFileAccess(server:server,appState:app),remotePath:pair.remotePath,store:sync).environment(\.colorScheme,scheme),size:NSSize(width:900,height:690),name:"directory-sync-\(dark ? "dark" : "light")",folder:folder,dark:dark)
        }
        controller.close();sync.shutdown()
        print("File UI fixtures: \(folder.path)")
    }
    private func render<Content:View>(_ content:Content,size:NSSize,name:String,folder:URL,dark:Bool) async throws {
        let root=NSHostingView(rootView:content);root.frame=NSRect(origin:.zero,size:size)
        let window=NSWindow(contentRect:root.frame,styleMask:[.borderless],backing:.buffered,defer:false)
        window.contentView=root;window.appearance=NSAppearance(named:dark ? .darkAqua : .aqua)
        window.orderFront(nil);root.layoutSubtreeIfNeeded();try await Task.sleep(for:.milliseconds(250))
        let rep=try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in:root.bounds));root.cacheDisplay(in:root.bounds,to:rep)
        try XCTUnwrap(rep.representation(using:.png,properties:[:])).write(to:folder.appendingPathComponent(name+".png"))
        window.orderOut(nil);window.contentView=nil
    }
}
