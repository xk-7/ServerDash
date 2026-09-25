import Foundation
import XCTest
@testable import ServerDash

final class MachineBrowserFilterStateTests: XCTestCase {
    func testNameMigrationAndDirectoryRenameKeepMachineFilterSelection() {
        let groupID = UUID(), tagID = UUID()
        let before = catalog(
            groups: [.init(id: groupID, name: "生产", parentID: nil)],
            tags: [.init(id: tagID, name: "重要")],
            items: [item("host", group: "生产", tags: ["重要"])]
        )
        var filters = MachineBrowserFilterState()
        filters.groupID = before.resolvedGroupID("", legacyName: "生产")
        filters.tagID = before.resolvedTagID("", legacyName: "重要")
        XCTAssertEqual(filters.groupID, groupID.uuidString)
        XCTAssertEqual(filters.tagID, tagID.uuidString)

        let renamedItem = item("host", group: "线上", tags: ["紧急"])
        let renamed = catalog(
            groups: [.init(id: groupID, name: "线上", parentID: nil)],
            tags: [.init(id: tagID, name: "紧急")], items: [renamedItem]
        )
        XCTAssertEqual(renamed.resolvedGroupID(filters.groupID), groupID.uuidString)
        XCTAssertEqual(renamed.resolvedTagID(filters.tagID), tagID.uuidString)
        XCTAssertEqual(filters.query(catalog: renamed).group, "线上")
        XCTAssertEqual(filters.query(catalog: renamed).tag, "紧急")
        XCTAssertEqual(MachineBrowserProjection(items: [renamedItem], groups: [
            .init(id: groupID, name: "线上", parentID: nil)
        ]).filteredIDs(filters.query(catalog: renamed)), ["host"])

        let deleted = catalog(groups: [], tags: [], items: [])
        XCTAssertEqual(deleted.resolvedGroupID(filters.groupID), "")
        XCTAssertEqual(deleted.resolvedTagID(filters.tagID), "")
    }

    func testMachineFilterIncludesDescendantsAndDefaultGroup() {
        let parent = MachineBrowserGroup(id: UUID(), name: "业务", parentID: nil)
        let child = MachineBrowserGroup(id: UUID(), name: "数据库", parentID: parent.id)
        let items = [item("parent", group: parent.name), item("child", group: child.name),
                     item("legacy", group: "默认分组")]
        let projection = MachineBrowserProjection(items: items, groups: [parent, child])
        let catalog = DashboardFilterCatalog(projection: projection, items: items, tags: [])

        let nested = MachineBrowserFilterState(groupID: parent.id.uuidString).query(catalog: catalog)
        XCTAssertEqual(Set(projection.filteredIDs(nested)), ["parent", "child"])

        let defaultGroup = MachineBrowserFilterState(
            groupID: DashboardFilterCatalog.virtualDefaultGroupID
        ).query(catalog: catalog)
        XCTAssertEqual(projection.filteredIDs(defaultGroup), ["legacy"])
    }

    func testClearingFiltersKeepsSortUntilExplicitlyChanged() {
        var state = MachineBrowserFilterState(search: "生产", groupID: UUID().uuidString,
                                              tagID: UUID().uuidString, kind: "ssh",
                                              monitoring: "enabled", sort: "newest")
        XCTAssertTrue(state.hasFilters)
        state.clearFilters()
        XCTAssertFalse(state.hasFilters)
        XCTAssertEqual(state.sort, "newest")
        XCTAssertEqual(state.query(catalog: catalog(groups: [], tags: [], items: [])).sort, "newest")
        state.sort = "name"
        XCTAssertEqual(state.sort, "name")
    }

    @MainActor func testLegacyDefaultGroupNameParticipatesInDashboardSearch() {
        let legacy = ServerRecord(name: "旧主机", host: "192.0.2.1", username: "root", groupName: "")
        let whitespace = ServerRecord(name: "空白旧主机", host: "192.0.2.3", username: "root", groupName: "  ")
        let production = ServerRecord(name: "生产主机", host: "192.0.2.2", username: "root", groupName: "生产")
        XCTAssertEqual(Set(ServerBrowserQuery(search: "默认分组").apply(to: [production, legacy, whitespace]).map(\.id)),
                       Set([legacy.id, whitespace.id]))
    }

    private func catalog(groups: [MachineBrowserGroup], tags: [DashboardCatalogTag],
                         items: [MachineBrowserItem]) -> DashboardFilterCatalog {
        DashboardFilterCatalog(projection: MachineBrowserProjection(items: items, groups: groups),
                               items: items, tags: tags)
    }

    private func item(_ id: String, group: String, tags: [String] = []) -> MachineBrowserItem {
        MachineBrowserItem(id: id, name: "主机 \(id)", address: "192.0.2.1", group: group,
                           tags: tags, notes: "", kind: "SSH", createdAt: .now,
                           monitoringEnabled: true)
    }
}
