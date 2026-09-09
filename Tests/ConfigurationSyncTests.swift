import CryptoKit
import SwiftData
import XCTest
@testable import ServerDash

@MainActor final class ConfigurationSyncTests: XCTestCase {
    func testCatalogReconciliationDoesNotSaveUnrelatedDraftChanges() throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let context = ModelContext(container); context.autosaveEnabled = false
        let server = ServerRecord(name: "Original", host: "192.0.2.10", username: "test", enableDashboardMonitor: false)
        context.insert(server); try context.save()
        server.name = "Unsaved draft"
        try MachineOrganization.reconcile(names: ["Production"], tags: ["active"], context: context)
        let reader = ModelContext(container)
        XCTAssertEqual(try reader.fetch(FetchDescriptor<ServerRecord>()).first?.name, "Original")
        XCTAssertEqual(try reader.fetchCount(FetchDescriptor<MachineGroupRecord>()), 1)
        XCTAssertEqual(server.name, "Unsaved draft")
    }
    private func ssh(_ id: UUID = UUID(), name: String = "Host", deleted: Bool = false) -> SyncConfigurationObject {
        .init(id: id, kind: "ssh", fields: ["name": name, "host": "192.0.2.11", "port": "22", "username": "operator", "authentication": "privateKey", "group": "默认分组", "tags": "", "notes": "", "sftpPath": "."], deleted: deleted)
    }

    func testEncryptedPackageRoundTripRejectsWrongKeyTamperAndHeader() throws {
        let package = ConfigurationSyncPackage(spaceID: UUID(), objects: [ssh()])
        let key = ConfigurationSyncCrypto.newKey()
        let encrypted = try ConfigurationSyncCrypto.encrypt(package, key: key)
        XCTAssertEqual(try ConfigurationSyncCrypto.decrypt(encrypted, key: key), package)
        XCTAssertThrowsError(try ConfigurationSyncCrypto.decrypt(encrypted, key: ConfigurationSyncCrypto.newKey()))
        var altered = encrypted; altered[altered.index(before: altered.endIndex)] ^= 1
        XCTAssertThrowsError(try ConfigurationSyncCrypto.decrypt(altered, key: key))
        altered = encrypted; altered[0] ^= 1
        XCTAssertThrowsError(try ConfigurationSyncCrypto.decrypt(altered, key: key))
        XCTAssertThrowsError(try ConfigurationSyncCrypto.encrypt(package, key: Data(repeating: 0, count: 16)))
        XCTAssertFalse(String(decoding: encrypted, as: UTF8.self).contains("192.0.2.11"))
    }

    func testPackageRejectsCredentialFieldsUnknownKindsAndDuplicateRemoteIDs() throws {
        var object = ssh()
        object.fields["privateKeyPath"] = "/private/secret.pem"
        XCTAssertThrowsError(try object.validate())
        object = ssh(); object.fields["credentialReference"] = UUID().uuidString
        XCTAssertThrowsError(try object.validate())
        object = ssh(); object.kind = "trustedHost"
        XCTAssertThrowsError(try object.validate())
        object = ssh()
        XCTAssertThrowsError(try ConfigurationSyncPackage(spaceID: UUID(), objects: [object, object]).validate())
    }

    func testOneSidedUpdatesAndDeletionsResolveAgainstBaseline() throws {
        let base = ssh(), changed = ssh(name: "Other")
        var local = base; local.fields["name"] = "Local edit"
        let changes = ConfigurationSyncMerge.changes(local: [local], remote: [base, changed], baseline: [base.id: base])
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes.first { $0.id == base.id }?.choice, .local)
        XCTAssertEqual(changes.first { $0.id == changed.id }?.choice, .remote)
        XCTAssertFalse(changes.contains(where: \.conflict))
        let merged = try ConfigurationSyncMerge.resolve(local: [local], remote: [base, changed], changes: changes)
        XCTAssertEqual(Set(merged.map(\.id)), [base.id, changed.id])
        let deletion = ConfigurationSyncMerge.changes(local: [], remote: [base], baseline: [base.id: base])
        XCTAssertEqual(deletion.first?.choice, .local)
        XCTAssertEqual(deletion.first?.local?.deleted, true)
        let removed = try ConfigurationSyncMerge.resolve(local: [], remote: [base], changes: deletion)
        XCTAssertEqual(removed.first?.deleted, true)
        let secondPreview = ConfigurationSyncMerge.changes(local: [], remote: removed, baseline: [base.id: removed[0]])
        XCTAssertTrue(secondPreview.isEmpty)
        let remoteDeleted = ConfigurationSyncMerge.changes(local: [base], remote: [], baseline: [base.id: base])
        XCTAssertEqual(remoteDeleted.first?.choice, .remote)
        XCTAssertEqual(remoteDeleted.first?.remote?.deleted, true)
        XCTAssertTrue(ConfigurationSyncMerge.changes(local: [], remote: [], baseline: [base.id: base]).isEmpty)
    }

    func testConcurrentEditAndDeleteRequireExplicitChoice() throws {
        let base = ssh()
        var remote = base; remote.fields["notes"] = "remote edit"
        var conflicts = ConfigurationSyncMerge.changes(local: [], remote: [remote], baseline: [base.id: base])
        XCTAssertEqual(conflicts.count, 1); XCTAssertTrue(conflicts[0].conflict)
        XCTAssertEqual(conflicts[0].choice, .unresolved)
        XCTAssertThrowsError(try ConfigurationSyncMerge.resolve(local: [], remote: [remote], changes: conflicts))
        conflicts[0].choice = .remote
        XCTAssertEqual(try ConfigurationSyncMerge.resolve(local: [], remote: [remote], changes: conflicts), [remote])
        conflicts[0].choice = .local
        XCTAssertEqual(try ConfigurationSyncMerge.resolve(local: [], remote: [remote], changes: conflicts).first?.deleted, true)
    }

    func testKeepBothStandaloneHostsUsesNewRemoteIdentity() throws {
        let base = ssh()
        var local = base; local.fields["name"] = "Local"
        var remote = base; remote.fields["name"] = "Remote"
        var changes = ConfigurationSyncMerge.changes(local: [local], remote: [remote], baseline: [base.id: base])
        changes[0].choice = .both
        let merged = try ConfigurationSyncMerge.resolve(local: [local], remote: [remote], changes: changes)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(Set(merged.map(\.id)).count, 2)
        XCTAssertEqual(merged.first { $0.id == base.id }, remote)
        XCTAssertEqual(merged.first { $0.id != base.id }?.fields["name"], "Local（本机副本）")
    }

    func testRelatedConfigurationCannotKeepBothAndDeletedParentsNormalizeChildren() throws {
        let host = ssh()
        for kind in ["advanced", "route", "tunnel", "group", "tag"] {
            let object = SyncConfigurationObject(id: UUID(), kind: kind, fields: ["name": "Base", "server": host.id.uuidString])
            var local = object; local.fields["name"] = "Local"
            var remote = object; remote.fields["name"] = "Remote"
            var changes = ConfigurationSyncMerge.changes(local: [local], remote: [remote], baseline: [object.id: object])
            changes[0].choice = .both
            XCTAssertThrowsError(try ConfigurationSyncMerge.resolve(local: [local], remote: [remote], changes: changes), kind)
        }
        var deletedHost = host; deletedHost.deleted = true
        let child = SyncConfigurationObject(id: UUID(), kind: "advanced", fields: ["server": host.id.uuidString])
        let changes = ConfigurationSyncMerge.changes(local: [deletedHost], remote: [host, child], baseline: [host.id: host])
        let merged = try ConfigurationSyncMerge.resolve(local: [deletedHost], remote: [host, child], changes: changes)
        XCTAssertEqual(merged.first { $0.id == child.id }?.deleted, true)
        let parent = SyncConfigurationObject(id: UUID(), kind: "group", fields: ["name": "Parent"])
        let deletedGroup = SyncConfigurationObject(id: UUID(), kind: "group", fields: ["name": "Deleted", "parent": parent.id.uuidString], deleted: true)
        let sub = SyncConfigurationObject(id: UUID(), kind: "group", fields: ["name": "Child", "parent": deletedGroup.id.uuidString])
        let normalized = ConfigurationSyncMerge.normalize([parent, deletedGroup, sub])
        XCTAssertEqual(normalized.first { $0.id == sub.id }?.fields["parent"], parent.id.uuidString)
    }

    func testCatalogRoundTripHasStableRouteMetadataAndNoCredentialOrDeviceReferences() throws {
        let source = try PersistenceController.makeInMemoryContainer()
        let sourceContext = source.mainContext
        let identity = UUID(), credential = UUID()
        let host = ServerRecord(name: "Linux", host: "192.0.2.10", username: "operator", privateKeyPath: "/private/fixture-secret.pem", identityID: identity)
        let rdp = try RDPConnectionRecord(name: "Windows", host: "192.0.2.20", username: "operator")
        rdp.credentialReference = credential
        let serial = SerialConnectionRecord(name: "Console", devicePath: "/dev/cu.fixture-local")
        let route = ConnectionRoute(name: "Jump", hops: [.init(name: "Bastion", endpoint: .init(host: "192.0.2.30", port: 22, username: "jump"), credential: .password(accountID: credential))], proxy: .init(kind: .socks5, host: "proxy.example.com", port: 1080, username: "private-proxy-user", secretAccount: "fixture-proxy-secret"), importedProxyCommand: "secret-command", importedProxyCommandConfirmed: true)
        let routeRecord = try ConnectionRouteRecord(route: route, serverID: host.id)
        var advanced = SSHAdvancedSettingsDraft.default
        advanced.commandsEnabled = true; advanced.beforeConnectCommand = "echo ready"
        sourceContext.insert(host); sourceContext.insert(rdp); sourceContext.insert(serial)
        sourceContext.insert(routeRecord); sourceContext.insert(SSHAdvancedSettingsRecord(serverID: host.id, settings: advanced))
        try sourceContext.save()
        let spaceID = UUID()
        let capture = try ConfigurationSyncCatalog(container: source, spaceID: spaceID)
        let objects = try capture.capture(); try capture.save()
        let data = try JSONEncoder().encode(objects), text = String(decoding: data, as: UTF8.self)
        for secret in [identity.uuidString, credential.uuidString, "fixture-secret.pem", "fixture-local", "private-proxy-user", "fixture-proxy-secret", "secret-command"] {
            XCTAssertFalse(text.contains(secret), secret)
        }
        let destination = try PersistenceController.makeInMemoryContainer()
        let imported = try ConfigurationSyncCatalog(container: destination, spaceID: spaceID)
        try imported.stage(objects); try imported.save()
        XCTAssertEqual(try imported.capture(), objects, "Mapping IDs must not rewrite the portable route JSON on the next preview")
        let reopened = try ConfigurationSyncCatalog(container: destination, spaceID: spaceID)
        XCTAssertEqual(try reopened.capture(), objects)
        XCTAssertEqual(Set(reopened.baseline.keys), Set(objects.map(\.id)))
        try reopened.stage(objects); try reopened.save()
        XCTAssertEqual(try destination.mainContext.fetchCount(FetchDescriptor<ServerRecord>()), 1)
        XCTAssertEqual(try destination.mainContext.fetchCount(FetchDescriptor<RDPConnectionRecord>()), 1)
        XCTAssertEqual(try destination.mainContext.fetchCount(FetchDescriptor<ConnectionRouteRecord>()), 1)
        let importedHost = try XCTUnwrap(destination.mainContext.fetch(FetchDescriptor<ServerRecord>()).first)
        XCTAssertNotEqual(importedHost.id, host.id)
        XCTAssertNil(importedHost.identityID); XCTAssertEqual(importedHost.privateKeyPath, "")
        XCTAssertNil(try destination.mainContext.fetch(FetchDescriptor<RDPConnectionRecord>()).first?.credentialReference)
        XCTAssertEqual(try destination.mainContext.fetch(FetchDescriptor<SerialConnectionRecord>()).first?.devicePath, "")
        XCTAssertEqual(try destination.mainContext.fetch(FetchDescriptor<SSHAdvancedSettingsRecord>()).first?.settings.commandsEnabled, false)
    }

    func testLocalUploadPreservesExplicitlyEnabledLocalCommands() throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let host = ServerRecord(name: "Host", host: "192.0.2.1", username: "operator")
        var settings = SSHAdvancedSettingsDraft.default
        settings.commandsEnabled = true; settings.beforeConnectCommand = "echo local"
        container.mainContext.insert(host)
        container.mainContext.insert(SSHAdvancedSettingsRecord(serverID: host.id, settings: settings))
        let route = ConnectionRoute(name: "Local proxy", importedProxyCommand: "nc proxy.example.com 22", importedProxyCommandConfirmed: true)
        container.mainContext.insert(try ConnectionRouteRecord(route: route, serverID: host.id))
        try container.mainContext.save()
        let catalog = try ConfigurationSyncCatalog(container: container, spaceID: UUID())
        let captured = try catalog.capture()
        try catalog.stage(captured); try catalog.save()
        let read = ModelContext(container)
        XCTAssertEqual(try read.fetch(FetchDescriptor<SSHAdvancedSettingsRecord>()).first?.settings.commandsEnabled, true)
        XCTAssertEqual(try read.fetch(FetchDescriptor<ConnectionRouteRecord>()).first?.route?.importedProxyCommand, route.importedProxyCommand)
        XCTAssertEqual(try read.fetch(FetchDescriptor<ConnectionRouteRecord>()).first?.route?.importedProxyCommandConfirmed, true)
    }

    func testFreshCaptureDetectsConcurrentSavedEditsWithoutPublishingStagedChanges() throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let host = ServerRecord(name: "Original", host: "192.0.2.1", username: "operator")
        container.mainContext.insert(host); try container.mainContext.save()
        let catalog = try ConfigurationSyncCatalog(container: container, spaceID: UUID())
        let baseline = try catalog.capture(); try catalog.save()
        var incoming = baseline; incoming[0].fields["name"] = "Staged remote"
        try catalog.stage(incoming)
        XCTAssertEqual(try catalog.freshCapture(), baseline, "Uncommitted remote changes must not appear in a fresh durable capture")
        let concurrent = ModelContext(container)
        let changed = try XCTUnwrap(concurrent.fetch(FetchDescriptor<ServerRecord>()).first)
        changed.notes = "Saved while WebDAV PUT was in flight"
        try concurrent.save()
        XCTAssertNotEqual(try catalog.freshCapture(), baseline)
        catalog.context.rollback()
        let saved = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<ServerRecord>()).first)
        XCTAssertEqual(saved.name, "Original")
        XCTAssertEqual(saved.notes, "Saved while WebDAV PUT was in flight")
    }

    func testLocalAuthorizationAndProxyReferenceChangesInvalidateStagedSync() throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let host = ServerRecord(name: "Host", host: "192.0.2.1", username: "operator")
        container.mainContext.insert(host)
        container.mainContext.insert(SSHAdvancedSettingsRecord(serverID: host.id))
        let route = ConnectionRoute(name: "Proxy", proxy: .init(kind: .socks5, host: "proxy.example.com", port: 1080))
        container.mainContext.insert(try ConnectionRouteRecord(route: route, serverID: host.id))
        try container.mainContext.save()
        let catalog = try ConfigurationSyncCatalog(container: container, spaceID: UUID())
        let baseline = try catalog.capture(); try catalog.save()
        let localState = try catalog.freshLocalStateFingerprint()
        var incoming = baseline
        let index = try XCTUnwrap(incoming.firstIndex { $0.kind == "advanced" })
        var remoteSettings = SSHAdvancedSettingsDraft.default; remoteSettings.keepAliveInterval = 45
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        incoming[index].fields["settings"] = String(decoding: try encoder.encode(remoteSettings), as: UTF8.self)
        try catalog.stage(incoming)
        XCTAssertEqual(try catalog.freshLocalStateFingerprint(), localState, "Staged settings must not enter the durable fingerprint")
        let concurrent = ModelContext(container)
        let advanced = try XCTUnwrap(concurrent.fetch(FetchDescriptor<SSHAdvancedSettingsRecord>()).first)
        var settings = advanced.settings; settings.commandsEnabled = true; advanced.settings = settings
        let proxyRecord = try XCTUnwrap(concurrent.fetch(FetchDescriptor<ConnectionRouteRecord>()).first)
        var proxy = try XCTUnwrap(proxyRecord.route)
        proxy.proxy?.username = "new-local-user"; proxy.proxy?.secretAccount = "new-local-reference"
        proxyRecord.routeJSON = String(decoding: try JSONEncoder().encode(proxy), as: UTF8.self)
        try concurrent.save()
        XCTAssertEqual(try catalog.freshCapture(), baseline, "Portable configuration intentionally excludes these local values")
        XCTAssertNotEqual(try catalog.freshLocalStateFingerprint(), localState)
        catalog.context.rollback()
        let read = ModelContext(container)
        XCTAssertEqual(try read.fetch(FetchDescriptor<SSHAdvancedSettingsRecord>()).first?.settings.commandsEnabled, true)
        XCTAssertEqual(try read.fetch(FetchDescriptor<ConnectionRouteRecord>()).first?.route?.proxy?.secretAccount, "new-local-reference")
    }

    func testRemoteKindCannotChangeForPreviouslyMappedIdentity() throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let catalog = try ConfigurationSyncCatalog(container: container, spaceID: UUID())
        let object = ssh()
        try catalog.stage([object]); try catalog.save()
        let reused = SyncConfigurationObject(id: object.id, kind: "tag", fields: ["name": "Invalid replacement", "color": "blue"])
        XCTAssertThrowsError(try catalog.stage([reused]))
        catalog.context.rollback()
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<ServerRecord>()), 1)
    }

    func testGroupAndTagDeletionRehomesHostsWithoutDeletingHosts() throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let host = ServerRecord(name: "Host", host: "192.0.2.1", username: "operator", groupName: "Production", tagsText: "urgent,keep")
        container.mainContext.insert(host)
        container.mainContext.insert(MachineGroupRecord(name: "Production"))
        container.mainContext.insert(MachineTagRecord(name: "urgent"))
        try container.mainContext.save()
        let catalog = try ConfigurationSyncCatalog(container: container, spaceID: UUID())
        var objects = try catalog.capture()
        for index in objects.indices where objects[index].kind == "group" || objects[index].kind == "tag" { objects[index].deleted = true }
        try catalog.stage(objects); try catalog.save()
        let read = ModelContext(container)
        let existing = try XCTUnwrap(read.fetch(FetchDescriptor<ServerRecord>()).first)
        XCTAssertEqual(existing.id, host.id)
        XCTAssertTrue(existing.groupName.isEmpty || existing.groupName == "默认分组")
        XCTAssertFalse(existing.tags.contains("urgent")); XCTAssertTrue(existing.tags.contains("keep"))
    }

    func testRecreatedGroupAndTagNamesSurviveOldDeletionTombstones() throws {
        var host = ssh(); host.fields["group"] = "Production"; host.fields["tags"] = "urgent,keep"
        let oldGroup = SyncConfigurationObject(id: UUID(), kind: "group", fields: ["name": "Production"], deleted: true)
        let newGroup = SyncConfigurationObject(id: UUID(), kind: "group", fields: ["name": "Production"])
        let oldTag = SyncConfigurationObject(id: UUID(), kind: "tag", fields: ["name": "urgent", "color": "red"], deleted: true)
        let newTag = SyncConfigurationObject(id: UUID(), kind: "tag", fields: ["name": "urgent", "color": "blue"])
        let result = ConfigurationSyncMerge.normalize([host, oldGroup, newGroup, oldTag, newTag])
        XCTAssertEqual(result.first { $0.id == host.id }?.fields["group"], "Production")
        XCTAssertEqual(result.first { $0.id == host.id }?.fields["tags"], "urgent,keep")
    }

    func testConnectionChildrenCanMoveToAnotherSyncedHostWithoutDiverging() throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let first = ServerRecord(name: "First", host: "192.0.2.1", username: "operator")
        let second = ServerRecord(name: "Second", host: "192.0.2.2", username: "operator")
        container.mainContext.insert(first); container.mainContext.insert(second)
        container.mainContext.insert(SSHAdvancedSettingsRecord(serverID: first.id))
        container.mainContext.insert(try ConnectionRouteRecord(route: ConnectionRoute(name: "Direct"), serverID: first.id))
        container.mainContext.insert(PortForwardRuleRecord(rule: .init(name: "DB", serverID: first.id, direction: .local, listenPort: 8181, targetHost: "localhost", targetPort: 3306)))
        try container.mainContext.save()
        let catalog = try ConfigurationSyncCatalog(container: container, spaceID: UUID())
        var objects = try catalog.capture(); try catalog.save()
        let target = try XCTUnwrap(objects.first { $0.kind == "ssh" && $0.fields["name"] == "Second" })
        for index in objects.indices where ["advanced", "route", "tunnel"].contains(objects[index].kind) {
            objects[index].fields["server"] = target.id.uuidString
        }
        try catalog.stage(objects); try catalog.save()
        XCTAssertEqual(try catalog.capture(), objects)
        let read = ModelContext(container)
        XCTAssertEqual(try read.fetch(FetchDescriptor<SSHAdvancedSettingsRecord>()).first?.serverID, second.id)
        XCTAssertEqual(try read.fetch(FetchDescriptor<ConnectionRouteRecord>()).first?.serverID, second.id)
        XCTAssertEqual(try read.fetch(FetchDescriptor<PortForwardRuleRecord>()).first?.serverID, second.id)
    }

    func testConcurrentFirstAdvancedEditsShareRemoteIdentityAndRequireResolution() throws {
        let space = UUID(), host = ssh()
        let first = try PersistenceController.makeInMemoryContainer()
        let second = try PersistenceController.makeInMemoryContainer()
        func createLocalEdit(_ container: ModelContainer, command: String) throws -> [SyncConfigurationObject] {
            let imported = try ConfigurationSyncCatalog(container: container, spaceID: space)
            try imported.stage([host]); try imported.save()
            let context = ModelContext(container)
            let localHost = try XCTUnwrap(context.fetch(FetchDescriptor<ServerRecord>()).first)
            var settings = SSHAdvancedSettingsDraft.default; settings.beforeConnectCommand = command
            context.insert(SSHAdvancedSettingsRecord(serverID: localHost.id, settings: settings)); try context.save()
            let edited = try ConfigurationSyncCatalog(container: container, spaceID: space)
            return try edited.capture()
        }
        let local = try createLocalEdit(first, command: "echo first")
        let remote = try createLocalEdit(second, command: "echo second")
        XCTAssertEqual(local.first { $0.kind == "advanced" }?.id, remote.first { $0.kind == "advanced" }?.id)
        let changes = ConfigurationSyncMerge.changes(local: local, remote: remote, baseline: [host.id: host])
        XCTAssertEqual(changes.count, 1); XCTAssertTrue(changes[0].conflict)
        XCTAssertEqual(changes[0].choice, .unresolved)
    }

    func testDuplicateAdvancedSettingsForOneHostAreRejectedBeforeStaging() throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let catalog = try ConfigurationSyncCatalog(container: container, spaceID: UUID())
        let host = ssh()
        let settings = String(decoding: try JSONEncoder().encode(SSHAdvancedSettingsDraft.default), as: UTF8.self)
        let first = SyncConfigurationObject(id: UUID(), kind: "advanced", fields: ["server": host.id.uuidString, "settings": settings])
        var duplicate = first; duplicate.id = UUID()
        XCTAssertThrowsError(try catalog.stage([host, first, duplicate]))
        XCTAssertFalse(catalog.context.hasChanges)
    }

    func testRecreatedAdvancedRecordReusesRemoteSlotWithItsNewLocalID() throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let context = container.mainContext
        let host = ServerRecord(name: "Host", host: "192.0.2.1", username: "operator")
        context.insert(host)
        let original = SSHAdvancedSettingsRecord(serverID: host.id)
        context.insert(original); try context.save()
        let space = UUID()
        let first = try ConfigurationSyncCatalog(container: container, spaceID: space)
        let originalObjects = try first.capture(); try first.stage(originalObjects); try first.save()
        let oldRemoteID = try XCTUnwrap(originalObjects.first { $0.kind == "advanced" }?.id)
        context.delete(original); try context.save()
        let recreated = SSHAdvancedSettingsRecord(serverID: host.id)
        context.insert(recreated); try context.save()
        let catalog = try ConfigurationSyncCatalog(container: container, spaceID: space)
        var objects = try catalog.capture(); try catalog.save()
        XCTAssertEqual(objects.first { $0.kind == "advanced" }?.id, oldRemoteID)
        XCTAssertEqual(catalog.localID(kind: "advanced", remoteID: oldRemoteID), recreated.id)
        let index = try XCTUnwrap(objects.firstIndex { $0.kind == "advanced" })
        var changed = SSHAdvancedSettingsDraft.default; changed.keepAliveInterval = 45
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        objects[index].fields["settings"] = String(decoding: try encoder.encode(changed), as: UTF8.self)
        try catalog.stage(objects); try catalog.save()
        let read = ModelContext(container)
        XCTAssertEqual(try read.fetchCount(FetchDescriptor<SSHAdvancedSettingsRecord>()), 1)
        let record = try XCTUnwrap(read.fetch(FetchDescriptor<SSHAdvancedSettingsRecord>()).first)
        XCTAssertEqual(record.id, recreated.id)
        XCTAssertEqual(record.settings.keepAliveInterval, 45)
    }

    func testDeletingHostDoesNotLeaveUnresolvableConnectionChildren() throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let host = ServerRecord(name: "Host", host: "192.0.2.1", username: "operator")
        container.mainContext.insert(host)
        container.mainContext.insert(SSHAdvancedSettingsRecord(serverID: host.id))
        container.mainContext.insert(try ConnectionRouteRecord(route: ConnectionRoute(name: "Direct"), serverID: host.id))
        container.mainContext.insert(PortForwardRuleRecord(rule: .init(name: "DB", serverID: host.id, direction: .local, listenPort: 8181, targetHost: "localhost", targetPort: 3306)))
        try container.mainContext.save()
        let catalog = try ConfigurationSyncCatalog(container: container, spaceID: UUID())
        let before = try catalog.capture(); try catalog.stage(before); try catalog.save()
        let read = ModelContext(container)
        read.delete(try XCTUnwrap(read.fetch(FetchDescriptor<ServerRecord>()).first)); try read.save()
        let updated = try ConfigurationSyncCatalog(container: container, spaceID: catalog.spaceID)
        let local = try updated.capture()
        let changes = ConfigurationSyncMerge.changes(local: local, remote: before, baseline: updated.baseline)
        let merged = try ConfigurationSyncMerge.resolve(local: local, remote: before, changes: changes)
        XCTAssertNoThrow(try updated.stage(merged))
        try updated.save()
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<ServerRecord>()), 0)
        let after = try updated.capture()
        XCTAssertFalse(after.contains { ["advanced", "route", "tunnel"].contains($0.kind) && !$0.deleted })
    }

    func testV4DiskMigrationPreservesSSHAndRDPUUIDsAndCredentialReferences() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("configuration-v5-migration-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("v4.store")
        let sshID = UUID(), rdpID = UUID(), identityID = UUID(), keyID = UUID(), rdpCredential = UUID()
        try autoreleasepool {
            let schema = Schema(versionedSchema: PersistenceSchemaV4.self)
            let configuration = ModelConfiguration("ServerDash", schema: schema, url: store, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: configuration)
            container.mainContext.insert(ServerRecord(id: sshID, name: "Existing SSH", host: "192.0.2.10", port: 5022, username: "operator", privateKeyPath: "/fixture/private.pem", identityID: identityID))
            container.mainContext.insert(IdentityRecord(id: identityID, name: "Existing identity", username: "operator", authentication: .privateKey, sshKeyID: keyID))
            container.mainContext.insert(SSHKeyRecord(id: keyID, name: "Key", filePath: "/fixture/private.pem", algorithm: "ed25519", fingerprint: "SHA256:fixture"))
            let rdp = try RDPConnectionRecord(id: rdpID, name: "Existing RDP", host: "192.0.2.20", username: "administrator")
            rdp.credentialReference = rdpCredential; container.mainContext.insert(rdp)
            try container.mainContext.save()
        }
        XCTAssertTrue(PersistenceController.needsV5Backup(storeURL: store))
        let configuration = ModelConfiguration("ServerDash", schema: PersistenceController.schema, url: store, cloudKitDatabase: .none)
        let migrated = try ModelContainer(for: PersistenceController.schema, migrationPlan: ServerDashMigrationPlan.self, configurations: configuration)
        let context = migrated.mainContext
        let host = try XCTUnwrap(context.fetch(FetchDescriptor<ServerRecord>()).first)
        XCTAssertEqual(host.id, sshID); XCTAssertEqual(host.identityID, identityID); XCTAssertEqual(host.port, 5022)
        XCTAssertEqual(host.privateKeyPath, "/fixture/private.pem")
        XCTAssertEqual(try context.fetch(FetchDescriptor<IdentityRecord>()).first?.sshKeyID, keyID)
        XCTAssertEqual(try context.fetch(FetchDescriptor<RDPConnectionRecord>()).first?.id, rdpID)
        XCTAssertEqual(try context.fetch(FetchDescriptor<RDPConnectionRecord>()).first?.credentialReference, rdpCredential)
        context.insert(MachineGroupRecord(name: "New group"))
        context.insert(VNCConnectionRecord(name: "New VNC", host: "192.0.2.30"))
        context.insert(SerialConnectionRecord(name: "New serial"))
        try context.save()
        XCTAssertFalse(PersistenceController.needsV5Backup(storeURL: store))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MachineGroupRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SerialConnectionRecord>()), 1)
    }
    func testWebDAVRejectsUnsafeEndpointsAndUsesConditionalWrites() async throws {
        for value in ["http://example.com/dav", "https://user:secret@example.com/dav", "https://example.com/dav?token=secret", "https://example.com/dav#fragment"] {
            XCTAssertThrowsError(try WebDAVSyncEndpoint(address: value, username: "test", password: "fixture"))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConfigurationSyncURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); ConfigurationSyncURLProtocol.install(nil) }
        let transport = WebDAVSyncTransport(session: session)
        let endpoint = try WebDAVSyncEndpoint(address: "https://fixture.invalid/dav", username: "test", password: "fixture")
        ConfigurationSyncURLProtocol.install { request in
            XCTAssertEqual(request.httpMethod, "GET")
            return (200, ["ETag": "\"generation-1\""], Data("fixture-encrypted-data".utf8))
        }
        let fetched = try await transport.fetch(endpoint)
        XCTAssertEqual(fetched.0, Data("fixture-encrypted-data".utf8)); XCTAssertEqual(fetched.1, "\"generation-1\"")
        let probe = ConfigurationSyncConditionalProbe()
        ConfigurationSyncURLProtocol.install { request in
            if let reply = probe.reply(to: request) { return reply }
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "\"generation-1\"")
            return (204, [:], Data())
        }
        try await transport.put(Data("updated".utf8), endpoint: endpoint, etag: fetched.1)
        for invalidETag in ["W/\"weak\"", "\"unterminated", "\"one\", \"two\""] {
            ConfigurationSyncURLProtocol.install { _ in (200, ["ETag": invalidETag], Data()) }
            do { _ = try await transport.fetch(endpoint); XCTFail("Malformed or weak ETags must not be accepted") }
            catch ConfigurationSyncError.unsupportedConditionalWrites {} catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    func testWebDAVPreconditionFailuresNeverOverwriteResource() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConfigurationSyncURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); ConfigurationSyncURLProtocol.install(nil) }
        let transport = WebDAVSyncTransport(session: session)
        let endpoint = try WebDAVSyncEndpoint(address: "https://fixture.invalid/dav", username: "test", password: "fixture")
        let probe = ConfigurationSyncConditionalProbe()
        ConfigurationSyncURLProtocol.install { request in probe.reply(to: request) ?? (412, [:], Data()) }
        do { try await transport.put(Data(), endpoint: endpoint, etag: "\"stale\""); XCTFail("Stale writes must fail") }
        catch ConfigurationSyncError.remoteChanged {} catch { XCTFail("Unexpected error: \(error)") }
        ConfigurationSyncURLProtocol.install { request in
            XCTAssertNotEqual(request.url, endpoint.resource, "The real resource must never be touched after a failed conditional-write probe")
            return (request.httpMethod == "DELETE" ? 204 : 201, [:], Data())
        }
        do { try await transport.put(Data(), endpoint: endpoint, etag: nil); XCTFail("Servers ignoring preconditions must fail") }
        catch ConfigurationSyncError.unsupportedConditionalWrites {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testPartiallySupportedPreconditionsCannotOverwriteExistingOrFirstUpload() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConfigurationSyncURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); ConfigurationSyncURLProtocol.install(nil) }
        let transport = WebDAVSyncTransport(session: session)
        let endpoint = try WebDAVSyncEndpoint(address: "https://fixture.invalid/dav", username: "test", password: "fixture")
        for ignoredHeader in ["If-None-Match", "If-Match"] {
            for etag: String? in [nil, "\"existing\""] {
                let probe = ConfigurationSyncConditionalProbe(ignoredExistingHeader: ignoredHeader)
                ConfigurationSyncURLProtocol.install { request in
                    XCTAssertNotEqual(request.url, endpoint.resource, "No real upload may follow an unsafe probe")
                    return probe.reply(to: request) ?? (500, [:], Data())
                }
                do { try await transport.put(Data(), endpoint: endpoint, etag: etag); XCTFail("Partial precondition support must fail") }
                catch ConfigurationSyncError.unsupportedConditionalWrites {} catch { XCTFail("Unexpected error: \(error)") }
            }
        }
    }

}

private final class ConfigurationSyncConditionalProbe {
    private var exists = false
    private let ignoredExistingHeader: String?
    init(ignoredExistingHeader: String? = nil) { self.ignoredExistingHeader = ignoredExistingHeader }
    func reply(to request: URLRequest) -> (Int, [String: String], Data)? {
        guard request.url?.lastPathComponent.hasPrefix(".serverdash-condition-") == true else { return nil }
        if request.httpMethod == "DELETE" { exists = false; return (204, [:], Data()) }
        if request.value(forHTTPHeaderField: "If-Match") != nil {
            return (exists && ignoredExistingHeader == "If-Match" ? 204 : 412, [:], Data())
        }
        if exists { return (ignoredExistingHeader == "If-None-Match" ? 204 : 412, [:], Data()) }
        exists = true
        return (201, [:], Data())
    }
}

private final class ConfigurationSyncURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (Int, [String: String], Data)
    private static let lock = NSLock()
    private static var handler: Handler?
    static func install(_ value: Handler?) { lock.lock(); defer { lock.unlock() }; handler = value }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let handler = Self.handler; Self.lock.unlock()
        do {
            guard let handler, let url = request.url else { throw URLError(.badURL) }
            let (status, headers, body) = try handler(request)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
