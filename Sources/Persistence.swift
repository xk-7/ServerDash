import Foundation
import SwiftData
import SwiftUI

enum PersistenceController {
    static let schemaVersionKey = "serverDashSchemaVersion"
    static let currentSchemaVersion = 2

    static var schema: Schema {
        Schema([
            ServerRecord.self,
            IdentityRecord.self,
            SSHKeyRecord.self,
            CommandSnippetRecord.self,
            TrustedHostKey.self,
            TerminalSessionHistory.self
        ])
    }

    static func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        UserDefaults.standard.set(currentSchemaVersion, forKey: schemaVersionKey)
        return container
    }

    static func makeInMemoryContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    static func backupExistingStore() throws -> URL? {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let backup = support.appendingPathComponent(
            "ServerDash-backup-\(Int(Date().timeIntervalSince1970)).store"
        )
        guard let source = existingStoreURL() else { return nil }
        try FileManager.default.copyItem(at: source, to: backup)
        return backup
    }

    static func destroyStore() throws {
        for url in storeFileURLs() where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func applicationSupportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    private static func existingStoreURL() -> URL? {
        storeFileURLs().first {
            $0.pathExtension == "store" && FileManager.default.fileExists(atPath: $0.path)
        }
    }

    private static func storeFileURLs() -> [URL] {
        let support = applicationSupportDirectory()
        let bases = [
            support.appendingPathComponent("default.store"),
            support.appendingPathComponent("ServerDash.store"),
            support.appendingPathComponent("ServerDash/default.store")
        ]
        let discovered = (try? FileManager.default.contentsOfDirectory(
            at: support,
            includingPropertiesForKeys: nil
        ))?
            .filter { $0.pathExtension == "store" } ?? []
        return (bases + discovered).flatMap { url in
            [url, URL(fileURLWithPath: url.path + "-wal"), URL(fileURLWithPath: url.path + "-shm")]
        }
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
        do {
            container = try PersistenceController.makeContainer()
            openError = nil
        } catch {
            container = nil
            openError = error
            DiagnosticLog.logger(for: .data).error("打开数据库失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    func rebuild() {
        do {
            lastBackupURL = try PersistenceController.backupExistingStore()
            try PersistenceController.destroyStore()
            container = try PersistenceController.makeContainer()
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
