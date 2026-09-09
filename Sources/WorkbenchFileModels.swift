import Foundation
import SwiftData

/// Task identity belongs to V5. Local folders, automatic-upload permission, and
/// content baselines remain exclusively in this Mac's private binding file.
@Model final class DirectorySyncTaskRecord {
    @Attribute(.unique) var id: UUID
    var serverID: UUID
    var serverName: String
    var remotePath: String
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), serverID: UUID, serverName: String, remotePath: String) {
        self.id = id
        self.serverID = serverID
        self.serverName = serverName
        self.remotePath = remotePath
        createdAt = .now
        updatedAt = .now
    }
}
