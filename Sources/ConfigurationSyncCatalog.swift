import CryptoKit
import Foundation
import SwiftData

/// The sync schema is an explicit allowlist, never a serialization of SwiftData or Keychain.
@MainActor final class ConfigurationSyncCatalog {
    let context: ModelContext
    let spaceID: UUID
    private(set) var links: [ConfigurationSyncLink]
    init(container: ModelContainer, spaceID: UUID) throws {
        context = ModelContext(container); context.autosaveEnabled = false
        self.spaceID = spaceID
        links = try context.fetch(FetchDescriptor<ConfigurationSyncLink>()).filter { $0.spaceID == spaceID }
    }
    func remoteID(kind: String, localID: UUID, preferredID: UUID? = nil) -> UUID {
        if let link = links.first(where: { $0.entityKind == kind && $0.localID == localID }) { return link.remoteID }
        if let preferredID, let link = links.first(where: { $0.entityKind == kind && $0.remoteID == preferredID }) {
            // Recreating a singleton setting reuses its remote slot, not its removed local UUID.
            link.localID = localID
            return preferredID
        }
        let link = ConfigurationSyncLink(spaceID: spaceID, remoteID: preferredID ?? UUID(), entityKind: kind, localID: localID, baseline: Data())
        links.append(link); context.insert(link)
        return link.remoteID
    }
    func localID(kind: String, remoteID: UUID) -> UUID {
        if let link = links.first(where: { $0.entityKind == kind && $0.remoteID == remoteID }) { return link.localID }
        let link = ConfigurationSyncLink(spaceID: spaceID, remoteID: remoteID, entityKind: kind, localID: UUID(), baseline: Data())
        links.append(link); context.insert(link)
        return link.localID
    }
    var baseline: [UUID: SyncConfigurationObject] {
        Dictionary(links.compactMap { link in
            (try? JSONDecoder().decode(SyncConfigurationObject.self, from: link.baseline)).map { (link.remoteID, $0) }
        }, uniquingKeysWith: { first, _ in first })
    }
    private func object(_ kind: String, _ id: UUID, _ fields: [String: String]) -> SyncConfigurationObject {
        SyncConfigurationObject(id: remoteID(kind: kind, localID: id), kind: kind, fields: fields)
    }
    func capture() throws -> [SyncConfigurationObject] {
        var result: [SyncConfigurationObject] = []
        let servers = try context.fetch(FetchDescriptor<ServerRecord>())
        let serverIDs = Set(servers.map(\.id))
        for r in servers {
            result.append(object("ssh", r.id, ["name":r.name,"host":r.host,"port":String(r.port),"username":r.username,
                "authentication":r.authenticationRawValue,"group":r.groupName,"tags":r.tagsText,"notes":r.notes,"sftpPath":r.defaultSFTPPath]))
        }
        for r in try context.fetch(FetchDescriptor<RDPConnectionRecord>()) {
            var settings = try r.settings(); settings.shares = []; settings.screenIDs = []
            result.append(object("rdp", r.id, ["name":r.name,"host":r.host,"port":String(r.port),"username":r.username,
                "domain":r.domain,"group":r.groupName,"tags":r.tagsText,"notes":r.notes,"settings":try encode(settings)]))
        }
        for r in try context.fetch(FetchDescriptor<VNCConnectionRecord>()) {
            result.append(object("vnc",r.id,["name":r.name,"host":r.host,"port":String(r.port),"group":r.groupName,"tags":r.tagsText,"notes":r.notes]))
        }
        for r in try context.fetch(FetchDescriptor<SerialConnectionRecord>()) {
            result.append(object("serial",r.id,["name":r.name,"baud":String(r.baudRate),"bits":String(r.dataBits),
                "parity":r.parityRawValue,"stop":String(r.stopBits),"flow":r.flowControlRawValue,"group":r.groupName,"tags":r.tagsText,"notes":r.notes]))
        }
        for r in try context.fetch(FetchDescriptor<MachineGroupRecord>()) {
            var fields = ["name":r.name]
            if let parent = r.parentID { fields["parent"] = remoteID(kind: "group", localID: parent).uuidString }
            result.append(object("group", r.id, fields))
        }
        for r in try context.fetch(FetchDescriptor<MachineTagRecord>()) { result.append(object("tag",r.id,["name":r.name,"color":r.colorName])) }
        for r in try context.fetch(FetchDescriptor<CommandSnippetRecord>()) {
            result.append(object("snippet",r.id,["title":r.title,"command":r.command,"category":r.category,"notes":r.notes,"favorite":String(r.isFavorite)]))
        }
        for r in try context.fetch(FetchDescriptor<SSHAdvancedSettingsRecord>()) where serverIDs.contains(r.serverID) {
            var settings = r.settings; settings.commandsEnabled = false
            let server = remoteID(kind: "ssh", localID: r.serverID)
            // A host has one advanced-settings slot. Concurrent first edits on two Macs
            // must refer to that same slot, even though their local record IDs differ.
            let id = remoteID(kind: "advanced", localID: r.id, preferredID: Self.advancedRemoteID(server: server))
            result.append(SyncConfigurationObject(id: id, kind: "advanced", fields: ["server":server.uuidString,"settings":try encode(settings)]))
        }
        for r in try context.fetch(FetchDescriptor<ConnectionRouteRecord>()) {
            guard let serverID = r.serverID, serverIDs.contains(serverID), var route = r.route else { continue }
            route.importedProxyCommand = nil; route.importedProxyCommandConfirmed = false
            route.proxy?.secretAccount = nil; route.proxy?.username = nil
            for index in route.hops.indices { route.hops[index].credential = .sshAgent }
            route.id = remoteID(kind: "route", localID: r.id)
            // Stable transport IDs are local implementation details, not credentials.
            result.append(object("route",r.id,["server":remoteID(kind:"ssh",localID:serverID).uuidString,"route":try encode(route)]))
        }
        for r in try context.fetch(FetchDescriptor<PortForwardRuleRecord>()) where serverIDs.contains(r.serverID) {
            result.append(object("tunnel",r.id,["server":remoteID(kind:"ssh",localID:r.serverID).uuidString,"name":r.name,
                "direction":r.directionRawValue,"bind":r.bindAddress,"port":String(r.listenPort),"target":r.targetHost,"targetPort":String(r.targetPort)]))
        }
        return result.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// Import validation precedes writes. A remote ID never becomes a Keychain account.
    func stage(_ objects: [SyncConfigurationObject]) throws {
        try ConfigurationSyncPackage(spaceID: spaceID, objects: objects).validate()
        let objects = ConfigurationSyncMerge.normalize(objects)
        var advancedServers = Set<UUID>()
        for object in objects {
            if links.contains(where: { $0.remoteID == object.id && $0.entityKind != object.kind }) {
                throw ConfigurationSyncError.invalidPackage
            }
            if object.kind == "advanced", !object.deleted {
                guard let server = object.fields["server"].flatMap(UUID.init(uuidString:)), advancedServers.insert(server).inserted else {
                    throw ConfigurationSyncError.message("同一主机存在多份高级设置。请在来源设备保留一份设置后重新同步。")
                }
            }
        }
        let current = Dictionary(uniqueKeysWithValues: try capture().map { ($0.id, $0) })
        for object in objects { try object.validate(); _ = localID(kind: object.kind, remoteID: object.id) }
        let priority = ["group", "tag", "ssh", "rdp", "vnc", "serial", "snippet", "advanced", "route", "tunnel"]
        for object in objects.sorted(by: { priority.firstIndex(of: $0.kind)! < priority.firstIndex(of: $1.kind)! }) {
            if current[object.id] == object { continue }
            let id = localID(kind: object.kind, remoteID: object.id)
            if object.deleted { try remove(kind: object.kind, id: id); continue }
            let f = object.fields
            func s(_ key: String) -> String { f[key] ?? "" }
            func integer(_ key: String, _ fallback: Int) -> Int { Int(s(key)) ?? fallback }
            func relatedServer() throws -> UUID {
                guard let remote = UUID(uuidString:s("server")), objects.contains(where: { $0.id == remote && $0.kind == "ssh" && !$0.deleted }) else { throw ConfigurationSyncError.invalidPackage }
                return localID(kind:"ssh",remoteID:remote)
            }
            switch object.kind {
            case "ssh":
                _ = try ConnectionEndpoint(host:s("host"),port:integer("port",22),username:s("username")).validated(label:"同步主机")
                let existing = try fetch(ServerRecord.self,id:id) { $0.id }
                let r = existing ?? ServerRecord(id:id,name:s("name"),host:s("host"),username:s("username"),enableDashboardMonitor:false)
                if existing == nil { context.insert(r) }
                r.name=s("name"); r.host=s("host"); r.port=integer("port",22); r.username=s("username")
                guard AuthenticationMethod(rawValue: s("authentication")) != nil else { throw ConfigurationSyncError.invalidPackage }
                r.authenticationRawValue=s("authentication")
                r.groupName=s("group"); r.tagsText=s("tags"); r.notes=s("notes"); r.defaultSFTPPath=s("sftpPath")
            case "rdp":
                var settings: RDPSettings = try decode(s("settings"))
                guard settings.shares.isEmpty, settings.screenIDs.isEmpty else { throw ConfigurationSyncError.invalidPackage }
                try settings.validate()
                let existing = try fetch(RDPConnectionRecord.self,id:id) { $0.id }
                if let existing { settings.shares = (try existing.settings()).shares; settings.screenIDs = (try existing.settings()).screenIDs }
                let r = try existing ?? RDPConnectionRecord(id:id,name:s("name"),host:s("host"),port:integer("port",3389),username:s("username"),domain:s("domain"),settings:settings)
                if existing == nil { context.insert(r) }
                r.name=s("name"); r.host=s("host"); r.port=integer("port",3389); r.username=s("username"); r.domain=s("domain")
                r.groupName=s("group"); r.tagsText=s("tags"); r.notes=s("notes"); r.settingsData=try JSONEncoder().encode(settings)
                _ = try r.configuration()
            case "vnc":
                _ = try VNCAddress.url(host:s("host"),port:integer("port",5900))
                let existing = try fetch(VNCConnectionRecord.self,id:id) { $0.id }
                let r = existing ?? VNCConnectionRecord(id:id,name:s("name"),host:s("host"))
                if existing == nil { context.insert(r) }
                r.name=s("name"); r.host=s("host"); r.port=integer("port",5900); r.groupName=s("group"); r.tagsText=s("tags"); r.notes=s("notes")
            case "serial":
                let existing = try fetch(SerialConnectionRecord.self,id:id) { $0.id }
                let r = existing ?? SerialConnectionRecord(id:id,name:s("name"))
                if existing == nil { context.insert(r) }
                guard SerialPortConfiguration.baudRates.contains(integer("baud",115200)), (5...8).contains(integer("bits",8)), (1...2).contains(integer("stop",1)),
                      SerialParity(rawValue:s("parity")) != nil, SerialFlowControl(rawValue:s("flow")) != nil else { throw ConfigurationSyncError.invalidPackage }
                r.name=s("name"); r.baudRate=integer("baud",115200); r.dataBits=integer("bits",8); r.parityRawValue=s("parity")
                r.stopBits=integer("stop",1); r.flowControlRawValue=s("flow"); r.groupName=s("group"); r.tagsText=s("tags"); r.notes=s("notes")
            case "group":
                let existing = try fetch(MachineGroupRecord.self,id:id) { $0.id }
                let r = existing ?? MachineGroupRecord(id:id,name:s("name"))
                if existing == nil { context.insert(r) }
                r.name=s("name")
                if let remote = UUID(uuidString:s("parent")) {
                    guard objects.contains(where: { $0.id == remote && $0.kind == "group" && !$0.deleted }) else { throw ConfigurationSyncError.invalidPackage }
                    r.parentID = localID(kind:"group",remoteID:remote)
                } else { r.parentID=nil }
            case "tag":
                let existing = try fetch(MachineTagRecord.self,id:id) { $0.id }
                let r = existing ?? MachineTagRecord(id:id,name:s("name"))
                if existing == nil { context.insert(r) }; r.name=s("name"); r.colorName=s("color")
            case "snippet":
                let existing = try fetch(CommandSnippetRecord.self,id:id) { $0.id }
                let r = existing ?? CommandSnippetRecord(id:id,title:s("title"),command:s("command"))
                if existing == nil { context.insert(r) }
                r.title=s("title"); r.command=s("command"); r.category=s("category"); r.notes=s("notes"); r.isFavorite=s("favorite")=="true"
            case "advanced":
                var value: SSHAdvancedSettingsDraft = try decode(s("settings"))
                value.commandsEnabled=false; try value.validate()
                let serverID = try relatedServer()
                let existing = try fetch(SSHAdvancedSettingsRecord.self,id:id) { $0.id }
                if let existing { existing.serverID=serverID; existing.settings=value }
                else { let r=SSHAdvancedSettingsRecord(serverID:serverID,settings:value); r.id=id; context.insert(r) }
            case "route":
                let serverID = try relatedServer()
                var value: ConnectionRoute = try decode(s("route"))
                guard value.hops.count <= 8, value.proxy?.secretAccount == nil, value.proxy?.username == nil,
                      value.importedProxyCommand == nil, !value.importedProxyCommandConfirmed,
                      value.hops.allSatisfy({ if case .sshAgent = $0.credential { return true }; return false }) else { throw ConfigurationSyncError.invalidPackage }
                let existing = try fetch(ConnectionRouteRecord.self,id:id) { $0.id }
                if let old = existing?.route {
                    for index in value.hops.indices {
                        if let hop = old.hops.first(where: { $0.id == value.hops[index].id && $0.endpoint == value.hops[index].endpoint }) { value.hops[index].credential=hop.credential }
                    }
                    if value.proxy?.kind == old.proxy?.kind, value.proxy?.host == old.proxy?.host, value.proxy?.port == old.proxy?.port {
                        value.proxy?.username=old.proxy?.username; value.proxy?.secretAccount=old.proxy?.secretAccount
                    }
                }
                value.id=id
                guard let server = try fetch(ServerRecord.self, id: serverID, idOf: { $0.id }) else { throw ConfigurationSyncError.invalidPackage }
                _ = try value.validated(finalEndpoint: ConnectionEndpoint(host: server.host, port: server.port, username: server.username))
                let json=try encode(value)
                if let existing { existing.serverID=serverID; existing.name=value.name; existing.routeJSON=json; existing.revision=value.revision }
                else { context.insert(ConnectionRouteRecord(id:id,serverID:serverID,name:value.name,revision:value.revision,routeJSON:json)) }
            case "tunnel":
                let serverID=try relatedServer()
                guard let direction=PortForwardDirection(rawValue:s("direction")) else { throw ConfigurationSyncError.invalidPackage }
                let rule=PortForwardRule(id:id,name:s("name"),serverID:serverID,direction:direction,bindAddress:s("bind"),listenPort:integer("port",0),targetHost:s("target"),targetPort:integer("targetPort",0))
                try rule.validate(exposureConfirmed:true,remoteForwardConfirmed:true)
                if let r=try fetch(PortForwardRuleRecord.self,id:id, idOf: { $0.id }) {
                    r.serverID=serverID; r.name=rule.name; r.directionRawValue=direction.rawValue; r.bindAddress=rule.bindAddress
                    r.listenPort=rule.listenPort; r.targetHost=rule.targetHost; r.targetPort=rule.targetPort
                } else { context.insert(PortForwardRuleRecord(rule:rule)) }
            default: throw ConfigurationSyncError.invalidPackage
            }
        }
        let groups=try context.fetch(FetchDescriptor<MachineGroupRecord>())
        for group in groups {
            guard MachineOrganization.canMove(group,under:group.parentID,groups:groups) else { throw ConfigurationSyncError.invalidPackage }
        }
        for object in objects {
            if let link=links.first(where: { $0.remoteID == object.id }) { link.baseline=try object.encoded() }
        }
    }
    func save() throws { try context.save() }
    func freshCapture() throws -> [SyncConfigurationObject] {
        let fresh = try ConfigurationSyncCatalog(container: context.container, spaceID: spaceID)
        for link in links where !fresh.links.contains(where: { $0.remoteID == link.remoteID }) {
            let copy = ConfigurationSyncLink(spaceID: spaceID, remoteID: link.remoteID, entityKind: link.entityKind, localID: link.localID, baseline: link.baseline)
            fresh.links.append(copy); fresh.context.insert(copy)
        }
        return try fresh.capture()
    }
    /// These opaque rows contain local grants and credential references that are deliberately
    /// absent from the portable capture. Guard them too before replacing a staged JSON field.
    /// The digest remains in memory; neither it nor the underlying values enter a sync package.
    func freshLocalStateFingerprint() throws -> Data {
        let fresh = ModelContext(context.container)
        var rows: [String] = []
        for record in try fresh.fetch(FetchDescriptor<ConnectionRouteRecord>()) {
            rows.append("route:\(record.id.uuidString):\(record.routeJSON)")
        }
        for record in try fresh.fetch(FetchDescriptor<SSHAdvancedSettingsRecord>()) {
            rows.append("advanced:\(record.id.uuidString):\(record.settingsData.base64EncodedString())")
        }
        for record in try fresh.fetch(FetchDescriptor<RDPConnectionRecord>()) {
            rows.append("rdp:\(record.id.uuidString):\(record.settingsData.base64EncodedString())")
        }
        return Data(SHA256.hash(data: try JSONEncoder().encode(rows.sorted())))
    }
    private func fetch<T: PersistentModel>(_ type:T.Type,id:UUID,idOf:(T)->UUID) throws -> T? {
        try context.fetch(FetchDescriptor<T>()).first { idOf($0)==id }
    }
    private func remove(kind:String,id:UUID) throws {
        switch kind {
        case "ssh":
            for r in try context.fetch(FetchDescriptor<SSHAdvancedSettingsRecord>()) where r.serverID == id { context.delete(r) }
            for r in try context.fetch(FetchDescriptor<ConnectionRouteRecord>()) where r.serverID == id { context.delete(r) }
            for r in try context.fetch(FetchDescriptor<PortForwardRuleRecord>()) where r.serverID == id { context.delete(r) }
            if let r=try fetch(ServerRecord.self,id:id,idOf:{$0.id}) { context.delete(r) }
        case "rdp": if let r=try fetch(RDPConnectionRecord.self,id:id,idOf:{$0.id}) { context.delete(r) }
        case "vnc": if let r=try fetch(VNCConnectionRecord.self,id:id,idOf:{$0.id}) { context.delete(r) }
        case "serial": if let r=try fetch(SerialConnectionRecord.self,id:id,idOf:{$0.id}) { context.delete(r) }
        case "group": if let r=try fetch(MachineGroupRecord.self,id:id,idOf:{$0.id}) { context.delete(r) }
        case "tag": if let r=try fetch(MachineTagRecord.self,id:id,idOf:{$0.id}) { context.delete(r) }
        case "snippet": if let r=try fetch(CommandSnippetRecord.self,id:id,idOf:{$0.id}) { context.delete(r) }
        case "advanced": if let r=try fetch(SSHAdvancedSettingsRecord.self,id:id,idOf:{$0.id}) { context.delete(r) }
        case "route": if let r=try fetch(ConnectionRouteRecord.self,id:id,idOf:{$0.id}) { context.delete(r) }
        case "tunnel": if let r=try fetch(PortForwardRuleRecord.self,id:id,idOf:{$0.id}) { context.delete(r) }
        default: throw ConfigurationSyncError.invalidPackage
        }
    }
    private func encode<T:Encodable>(_ value:T) throws -> String {
        let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys]
        return String(decoding:try encoder.encode(value),as:UTF8.self)
    }
    private static func advancedRemoteID(server: UUID) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("ServerDash.ConfigSync.advanced.v1:\(server.uuidString)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
    private func decode<T:Decodable>(_ value:String) throws -> T { try JSONDecoder().decode(T.self,from:Data(value.utf8)) }
}
