import SwiftData
import XCTest
@testable import ServerDash

@MainActor final class LocalConfigurationTransferTests: XCTestCase {
    private struct Fixture {
        let container: ModelContainer
        let ssh: ServerRecord
        let rdp: RDPConnectionRecord
        let vnc: VNCConnectionRecord
        let serial: SerialConnectionRecord
    }

    private func fixture() throws -> Fixture {
        let container = try PersistenceController.makeInMemoryContainer()
        let context = container.mainContext
        let ssh = ServerRecord(name: "SSH fixture", host: "192.0.2.10", username: "operator", privateKeyPath: "/private/fixture-identity.pem", groupName: "Child", tagsText: "production", identityID: UUID(), enableDashboardMonitor: false)
        let rdp = try RDPConnectionRecord(name: "RDP fixture", host: "192.0.2.11", username: "administrator")
        rdp.credentialReference = UUID()
        let vnc = VNCConnectionRecord(name: "VNC fixture", host: "192.0.2.12")
        let serial = SerialConnectionRecord(name: "Serial fixture", devicePath: "/dev/cu.fixture-private-binding")
        let root = MachineGroupRecord(name: "Parent")
        let child = MachineGroupRecord(name: "Child", parentID: root.id)
        context.insert(ssh); context.insert(rdp); context.insert(vnc); context.insert(serial)
        context.insert(root); context.insert(child); context.insert(MachineTagRecord(name: "production", colorName: "green"))
        var settings = SSHAdvancedSettingsDraft.default
        settings.commandsEnabled = true; settings.beforeConnectCommand = "echo configured"
        context.insert(SSHAdvancedSettingsRecord(serverID: ssh.id, settings: settings))
        let route = ConnectionRoute(name: "Proxy", proxy: .init(kind: .socks5, host: "proxy.example.com", port: 1080, username: "fixture-private-proxy-user", secretAccount: "fixture-private-proxy-account"), importedProxyCommand: "fixture-private-proxy-command", importedProxyCommandConfirmed: true)
        context.insert(try ConnectionRouteRecord(route: route, serverID: ssh.id))
        context.insert(PortForwardRuleRecord(rule: .init(name: "DB", serverID: ssh.id, direction: .local, listenPort: 8181, targetHost: "localhost", targetPort: 3306)))
        context.insert(CommandSnippetRecord(title: "Excluded content", command: "fixture-private-snippet-body"))
        try context.save()
        return Fixture(container: container, ssh: ssh, rdp: rdp, vnc: vnc, serial: serial)
    }

    func testMixedExportExcludesCredentialsBindingsAndContentButIncludesRelations() throws {
        let source = try fixture(), sourceID = UUID()
        let selected = Set(["SSH/\(source.ssh.id)", "RDP/\(source.rdp.id)", "VNC/\(source.vnc.id)", "SERIAL/\(source.serial.id)"])
        let package = try LocalConfigurationExport.prepare(container: source.container, selected: selected, sourceID: sourceID)
        let bytes = try package.encoded(), text = String(decoding: bytes, as: UTF8.self)
        XCTAssertEqual(Set(package.objects.map(\.kind)), ["ssh", "rdp", "vnc", "serial", "advanced", "route", "tunnel", "group", "tag"])
        XCTAssertEqual(package.objects.filter { $0.kind == "group" }.count, 2)
        for excluded in [source.ssh.identityID!.uuidString, source.rdp.credentialReference!.uuidString, "fixture-identity.pem", "fixture-private-binding", "fixture-private-proxy-user", "fixture-private-proxy-account", "fixture-private-proxy-command", "fixture-private-snippet-body"] {
            XCTAssertFalse(text.contains(excluded), excluded)
        }
        let advanced = try XCTUnwrap(package.objects.first { $0.kind == "advanced" }?.fields["settings"])
        XCTAssertFalse(try JSONDecoder().decode(SSHAdvancedSettingsDraft.self, from: Data(advanced.utf8)).commandsEnabled)
        XCTAssertNotEqual(package.mappingSpaceID, sourceID)
        XCTAssertEqual(try LocalConfigurationPackage.decode(bytes).objects, package.objects)
        XCTAssertEqual(try LocalConfigurationExport.prepare(container: source.container, selected: selected, sourceID: sourceID).objects, package.objects)
    }

    func testRepeatedMixedImportKeepsStableLocalIdentityWithoutDuplicates() throws {
        let source = try fixture()
        let package = try LocalConfigurationExport.prepare(container: source.container, selected: nil, sourceID: UUID())
        let destination = try PersistenceController.makeInMemoryContainer()
        let first = try LocalConfigurationImportPlan(package: package, container: destination)
        try first.apply(changes: first.initialChanges)
        let firstRead = ModelContext(destination)
        let sshID = try XCTUnwrap(firstRead.fetch(FetchDescriptor<ServerRecord>()).first?.id)
        let second = try LocalConfigurationImportPlan(package: package, container: destination)
        XCTAssertTrue(second.initialChanges.isEmpty)
        try second.apply(changes: second.initialChanges)
        let read = ModelContext(destination)
        XCTAssertEqual(try read.fetchCount(FetchDescriptor<ServerRecord>()), 1)
        XCTAssertEqual(try read.fetchCount(FetchDescriptor<RDPConnectionRecord>()), 1)
        XCTAssertEqual(try read.fetchCount(FetchDescriptor<VNCConnectionRecord>()), 1)
        XCTAssertEqual(try read.fetchCount(FetchDescriptor<SerialConnectionRecord>()), 1)
        XCTAssertEqual(try read.fetch(FetchDescriptor<ServerRecord>()).first?.id, sshID)
        XCTAssertNotEqual(sshID, source.ssh.id)
        XCTAssertEqual(try read.fetch(FetchDescriptor<SerialConnectionRecord>()).first?.devicePath, "")
        XCTAssertEqual(try read.fetch(FetchDescriptor<SSHAdvancedSettingsRecord>()).first?.settings.commandsEnabled, false)
    }

    func testSubsetImportAndDeletionRecordsNeverDeleteUnlistedLocalHosts() throws {
        let source = try fixture(), sourceID = UUID()
        let initial = try LocalConfigurationExport.prepare(container: source.container, selected: nil, sourceID: sourceID)
        let destination = try PersistenceController.makeInMemoryContainer()
        let first = try LocalConfigurationImportPlan(package: initial, container: destination)
        try first.apply(changes: first.initialChanges)
        let edit = ModelContext(destination)
        let localRDP = try XCTUnwrap(edit.fetch(FetchDescriptor<RDPConnectionRecord>()).first)
        localRDP.notes = "Locally edited and absent from selected export"
        edit.insert(VNCConnectionRecord(name: "Unrelated local", host: "192.0.2.99"))
        try edit.save()
        var subset = try LocalConfigurationExport.prepare(container: source.container, selected: ["VNC/\(source.vnc.id)"], sourceID: sourceID)
        var deletion = try XCTUnwrap(initial.objects.first { $0.kind == "rdp" }); deletion.deleted = true
        subset.objects.append(deletion)
        let plan = try LocalConfigurationImportPlan(package: subset, container: destination)
        XCTAssertEqual(plan.ignoredDeletions, 1)
        XCTAssertFalse(plan.initialChanges.contains { $0.id == deletion.id })
        try plan.apply(changes: plan.initialChanges)
        let read = ModelContext(destination)
        XCTAssertEqual(try read.fetchCount(FetchDescriptor<ServerRecord>()), 1)
        XCTAssertEqual(try read.fetchCount(FetchDescriptor<RDPConnectionRecord>()), 1)
        XCTAssertEqual(try read.fetchCount(FetchDescriptor<SerialConnectionRecord>()), 1)
        XCTAssertEqual(try read.fetchCount(FetchDescriptor<VNCConnectionRecord>()), 2)
        XCTAssertEqual(try read.fetch(FetchDescriptor<RDPConnectionRecord>()).first?.notes, "Locally edited and absent from selected export")
    }

    func testConcurrentLocalAuthorizationChangeRejectsImportAndPreservesGrant() throws {
        let source = try fixture()
        let package = try LocalConfigurationExport.prepare(container: source.container, selected: nil, sourceID: UUID())
        let destination = try PersistenceController.makeInMemoryContainer()
        let first = try LocalConfigurationImportPlan(package: package, container: destination)
        try first.apply(changes: first.initialChanges)
        let preview = try LocalConfigurationImportPlan(package: package, container: destination)
        let concurrent = ModelContext(destination)
        let record = try XCTUnwrap(concurrent.fetch(FetchDescriptor<SSHAdvancedSettingsRecord>()).first)
        var settings = record.settings; settings.commandsEnabled = true; record.settings = settings
        try concurrent.save()
        XCTAssertThrowsError(try preview.apply(changes: preview.initialChanges)) { error in
            guard case ConfigurationSyncError.localChanged = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try ModelContext(destination).fetch(FetchDescriptor<SSHAdvancedSettingsRecord>()).first?.settings.commandsEnabled, true)
    }

    func testRuntimeReloadUpdatesFutureConfigurationsWithoutReplacingActiveOwners() throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let context = container.mainContext
        let server = ServerRecord(name: "Host", host: "192.0.2.1", username: "operator", enableDashboardMonitor: false)
        context.insert(server); try context.save()
        let registry = TerminalSessionRegistry(attachProcess: false)
        let app = AppState(trustCoordinator: HostTrustCoordinator(), terminalRegistry: registry, fileServicesEnabled: false)
        defer { registry.terminateAll() }
        app.initializeRuntime(for: server, synchronizeMonitoring: false)
        let active = registry.open(for: server, forceNew: true, config: server.connectionConfig, startImmediately: false)
        let existingTabs = registry.workspace.tabs.map(\.id)
        let imported = ModelContext(container)
        let changed = try XCTUnwrap(imported.fetch(FetchDescriptor<ServerRecord>()).first)
        changed.host = "192.0.2.2"; changed.port = 2202
        var advanced = SSHAdvancedSettingsDraft.default; advanced.connectTimeout = 75; advanced.keepAliveInterval = 47
        try SSHAdvancedSettingsRecord.upsert(serverID: server.id, settings: advanced, in: imported)
        try imported.save()
        try app.reloadConnectionConfigurations(from: container)
        XCTAssertEqual(app.configs[server.id]?.host, "192.0.2.2")
        XCTAssertEqual(app.configs[server.id]?.port, 2202)
        XCTAssertEqual(app.configs[server.id]?.advancedSettings, advanced)
        XCTAssertEqual(app.configs[server.id]?.connectTimeout, 75)
        XCTAssertEqual(registry.workspace.tabs.map(\.id), existingTabs)
        XCTAssertTrue(registry.controller(for: active.id) === active)
    }
}
