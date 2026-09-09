import Foundation
import SwiftData

/// Organization is additive: legacy connection records retain their original schema.
@Model final class MachineGroupRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var parentID: UUID?
    var createdAt: Date
    init(id: UUID = UUID(), name: String, parentID: UUID? = nil) {
        self.id = id; self.name = name; self.parentID = parentID; createdAt = .now
    }
}

@Model final class MachineTagRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var colorName: String
    init(id: UUID = UUID(), name: String, colorName: String = "accent") {
        self.id = id; self.name = name; self.colorName = colorName
    }
}

@Model final class ConfigurationSyncLink {
    @Attribute(.unique) var id: UUID
    var spaceID: UUID
    var remoteID: UUID
    var entityKind: String
    var localID: UUID
    var baseline: Data
    init(spaceID: UUID, remoteID: UUID, entityKind: String, localID: UUID, baseline: Data) {
        id = UUID(); self.spaceID = spaceID; self.remoteID = remoteID
        self.entityKind = entityKind; self.localID = localID; self.baseline = baseline
    }
}

enum MachineOrganization {
    static func cleanName(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func descendants(of id: UUID, groups: [MachineGroupRecord]) -> Set<UUID> {
        var result: Set<UUID> = [id]
        var changed = true
        while changed {
            changed = false
            for group in groups where group.parentID.map(result.contains) == true {
                if result.insert(group.id).inserted { changed = true }
            }
        }
        return result
    }

    static func canMove(_ group: MachineGroupRecord, under parent: UUID?, groups: [MachineGroupRecord]) -> Bool {
        guard let parent else { return true }
        return groups.contains { $0.id == parent } && !descendants(of: group.id, groups: groups).contains(parent)
    }

    /// Adds catalog entries to the caller's transaction without committing it.
    @MainActor static func include(names: [String], tags: [String], context: ModelContext) throws {
        let groups = try context.fetch(FetchDescriptor<MachineGroupRecord>())
        let known = Set(groups.map(\.name))
        for name in Set(names.map(cleanName)).subtracting(known) where !name.isEmpty {
            context.insert(MachineGroupRecord(name: name))
        }
        let knownTags = Set(try context.fetch(FetchDescriptor<MachineTagRecord>()).map(\.name))
        for tag in Set(tags.map(cleanName)).subtracting(knownTags) where !tag.isEmpty {
            context.insert(MachineTagRecord(name: tag))
        }
    }

    @MainActor static func reconcile(names: [String], tags: [String], context: ModelContext) throws {
        try Task.checkCancellation()
        // Startup maintenance must not commit unrelated pending edits.
        let writer = ModelContext(context.container)
        writer.autosaveEnabled = false
        try include(names: names, tags: tags, context: writer)
        try Task.checkCancellation()
        if writer.hasChanges { try writer.save() }
    }

    @MainActor static func prepareCatalog(context: ModelContext) throws {
        let ssh = try context.fetch(FetchDescriptor<ServerRecord>())
        let rdp = try context.fetch(FetchDescriptor<RDPConnectionRecord>())
        let vnc = try context.fetch(FetchDescriptor<VNCConnectionRecord>())
        let serial = try context.fetch(FetchDescriptor<SerialConnectionRecord>())
        let names = ssh.map(\.groupName) + rdp.map(\.groupName) + vnc.map(\.groupName) + serial.map(\.groupName)
        let tags = ssh.flatMap(\.tags) + rdp.flatMap(\.tags) + vnc.flatMap(\.tags) + serial.flatMap(\.tags)
        try reconcile(names: names, tags: tags, context: context)
    }
}
