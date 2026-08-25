import Foundation
import SwiftData
import SwiftUI

enum PersistenceSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static let models: [any PersistentModel.Type] = [
        ServerRecord.self,
        IdentityRecord.self,
        SSHKeyRecord.self,
        CommandSnippetRecord.self,
        TrustedHostKey.self,
        TerminalSessionHistory.self
    ]
}

enum PersistenceSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static let models: [any PersistentModel.Type] = [
        ServerRecord.self,
        IdentityRecord.self,
        SSHKeyRecord.self,
        CommandSnippetRecord.self,
        TrustedHostKey.self,
        TerminalSessionHistory.self,
        MonitoringSampleRecord.self,
        MonitoringAggregateRecord.self,
        MonitoringGapRecord.self
    ]
}

enum PersistenceSchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)
    static let models: [any PersistentModel.Type] = [
        ServerRecord.self,
        IdentityRecord.self,
        SSHKeyRecord.self,
        CommandSnippetRecord.self,
        TrustedHostKey.self,
        TerminalSessionHistory.self,
        MonitoringSampleRecord.self,
        MonitoringAggregateRecord.self,
        MonitoringGapRecord.self,
        ConnectionRouteRecord.self,
        PortForwardRuleRecord.self
    ]
}

enum ServerDashMigrationPlan: SchemaMigrationPlan {
    static let schemas: [any VersionedSchema.Type] = [
        PersistenceSchemaV1.self,
        PersistenceSchemaV2.self,
        PersistenceSchemaV3.self
    ]
    static let stages: [MigrationStage] = [
        .lightweight(fromVersion: PersistenceSchemaV1.self, toVersion: PersistenceSchemaV2.self),
        .lightweight(fromVersion: PersistenceSchemaV2.self, toVersion: PersistenceSchemaV3.self)
    ]
}

enum PersistenceController {
    static let schemaVersionKey = "serverDashSchemaVersion"
    static let currentSchemaVersion = 3

    static var schema: Schema {
        Schema(versionedSchema: PersistenceSchemaV3.self)
    }

    static func makeContainer(migrateLegacyStore: Bool = true) throws -> ModelContainer {
        let root = applicationSupportDirectory()
        let dataDirectory = dataDirectory(applicationSupportRoot: root)
        try FileManager.default.createDirectory(
            at: dataDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let storeURL = activeStoreURL(applicationSupportRoot: root)
        if migrateLegacyStore {
            try copyLegacyStoreIfNeeded(applicationSupportRoot: root, destination: storeURL)
        }
        let configuration = ModelConfiguration(
            "ServerDash",
            schema: schema,
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: schema,
            migrationPlan: ServerDashMigrationPlan.self,
            configurations: [configuration]
        )
        UserDefaults.standard.set(currentSchemaVersion, forKey: schemaVersionKey)
        return container
    }

    static func makeInMemoryContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: schema,
            migrationPlan: ServerDashMigrationPlan.self,
            configurations: [configuration]
        )
    }

    static func backupExistingStore() throws -> URL? {
        let root = applicationSupportDirectory()
        guard let source = existingStoreURL(applicationSupportRoot: root) else { return nil }
        let backup = root
            .appendingPathComponent("ServerDash/Backups", isDirectory: true)
            .appendingPathComponent(String(Int(Date().timeIntervalSince1970)), isDirectory: true)
        try FileManager.default.createDirectory(
            at: backup,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try copyStoreFamily(
            source: source,
            destination: backup.appendingPathComponent("default.store")
        )
        return backup
    }

    static func destroyStore() throws {
        let store = activeStoreURL(applicationSupportRoot: applicationSupportDirectory())
        for url in storeFamilyURLs(base: store) where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    static func applicationSupportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    static func dataDirectory(applicationSupportRoot: URL) -> URL {
        applicationSupportRoot.appendingPathComponent("ServerDash/Data", isDirectory: true)
    }

    static func activeStoreURL(applicationSupportRoot: URL) -> URL {
        dataDirectory(applicationSupportRoot: applicationSupportRoot)
            .appendingPathComponent("default.store")
    }

    static func legacyStoreURLs(applicationSupportRoot: URL) -> [URL] {
        [
            applicationSupportRoot.appendingPathComponent("default.store"),
            applicationSupportRoot.appendingPathComponent("ServerDash.store"),
            applicationSupportRoot.appendingPathComponent("ServerDash/default.store")
        ]
    }

    static func scopedStoreFileURLs(applicationSupportRoot: URL) -> [URL] {
        storeFamilyURLs(base: activeStoreURL(applicationSupportRoot: applicationSupportRoot))
    }

    private static func existingStoreURL(applicationSupportRoot: URL) -> URL? {
        let active = activeStoreURL(applicationSupportRoot: applicationSupportRoot)
        if FileManager.default.fileExists(atPath: active.path) {
            return active
        }
        return legacyStoreURLs(applicationSupportRoot: applicationSupportRoot).first {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    private static func copyLegacyStoreIfNeeded(
        applicationSupportRoot: URL,
        destination: URL
    ) throws {
        guard !FileManager.default.fileExists(atPath: destination.path),
              let source = legacyStoreURLs(applicationSupportRoot: applicationSupportRoot).first(where: {
                  FileManager.default.fileExists(atPath: $0.path)
              }) else { return }
        do {
            try copyStoreFamily(source: source, destination: destination)
        } catch {
            // Only the newly created destination family is removed. The legacy source is untouched.
            for url in storeFamilyURLs(base: destination) {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }
    }

    private static func copyStoreFamily(source: URL, destination: URL) throws {
        let sources = storeFamilyURLs(base: source)
        let destinations = storeFamilyURLs(base: destination)
        for (sourceURL, destinationURL) in zip(sources, destinations)
        where FileManager.default.fileExists(atPath: sourceURL.path) {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        }
    }

    private static func storeFamilyURLs(base: URL) -> [URL] {
        [
            base,
            URL(fileURLWithPath: base.path + "-wal"),
            URL(fileURLWithPath: base.path + "-shm")
        ]
    }
}

@MainActor
final class PersistenceSession: ObservableObject {
    @Published var container: ModelContainer?
    @Published var openError: Error?
    @Published var lastBackupURL: URL?

    init() {
        open()
    }

    func open() {
        let interval = PerformanceTrace.begin(.databaseOpen)
        defer { PerformanceTrace.end(interval) }
        do {
            container = try PersistenceController.makeContainer()
            openError = nil
        } catch {
            container = nil
            openError = error
            DiagnosticLog.logger(for: .data).error("打开数据库失败")
        }
    }

    func rebuild() {
        do {
            lastBackupURL = try PersistenceController.backupExistingStore()
            try PersistenceController.destroyStore()
            container = try PersistenceController.makeContainer(migrateLegacyStore: false)
            openError = nil
        } catch {
            openError = error
        }
    }
}

struct DatabaseRecoveryView: View {
    let error: Error
    let backupURL: URL?
    let onRetry: () -> Void
    let onRebuild: () -> Void

    var body: some View {
        VStack(spacing: AppleDesign.Spacing.lg) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(Color.appError)
            Text("无法打开本地数据库")
                .font(.title2.weight(.bold))
            Text(error.localizedDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack {
                Button("重试", action: onRetry)
                Button("备份并重建", role: .destructive, action: onRebuild)
                    .buttonStyle(.borderedProminent)
            }
            if let backupURL {
                Text("已备份到 \(backupURL.path)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text("重建会清空本机服务器配置，不会删除 Keychain 中的密码。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(AppleDesign.Spacing.xl)
        .frame(minWidth: 560, minHeight: 360)
    }
}
