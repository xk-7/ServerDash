import Foundation
import XCTest
@testable import ServerDash

final class DashboardFilterCatalogTests: XCTestCase {
    func testCatalogHierarchyIncludesEmptyGroupsAndCountsOnlySSHItems() {
        let parent = MachineBrowserGroup(id: UUID(), name: "生产", parentID: nil)
        let child = MachineBrowserGroup(id: UUID(), name: "数据库", parentID: parent.id)
        let empty = MachineBrowserGroup(id: UUID(), name: "尚无主机", parentID: parent.id)
        let items = [item("1", group: parent.name, tags: ["生产"]),
                     item("2", group: child.name, tags: ["生产"])]
        let projection = MachineBrowserProjection(items: items, groups: [parent, child, empty])
        let unused = DashboardCatalogTag(id: UUID(), name: "待分配")
        let catalog = DashboardFilterCatalog(projection: projection, items: items,
                                             tags: [DashboardCatalogTag(id: UUID(), name: "生产"), unused])

        XCTAssertEqual(catalog.group(id: parent.id.uuidString)?.count, 2)
        XCTAssertEqual(catalog.group(id: child.id.uuidString)?.count, 1)
        XCTAssertEqual(catalog.group(id: empty.id.uuidString)?.count, 0)
        XCTAssertEqual(catalog.group(id: empty.id.uuidString)?.depth, 1)
        XCTAssertEqual(catalog.includedGroupNames(id: parent.id.uuidString), ["生产", "数据库", "尚无主机"])
        XCTAssertEqual(catalog.tag(id: unused.id.uuidString)?.count, 0)
        XCTAssertEqual(catalog.groups.first?.name, "默认分组")
    }

    @MainActor func testDefaultGroupMatchesLegacyEmptyGroupAndKeepsMonitorSetting() {
        let legacy = ServerRecord(name: "旧服务器", host: "192.0.2.1", username: "root", groupName: "",
                                  enableDashboardMonitor: false)
        let other = ServerRecord(name: "生产服务器", host: "192.0.2.2", username: "root", groupName: "生产")
        let items = [item(legacy.id.uuidString, group: "默认分组"), item(other.id.uuidString, group: "生产")]
        let projection = MachineBrowserProjection(items: items, groups: [])
        let catalog = DashboardFilterCatalog(projection: projection, items: items, tags: [])
        let query = ServerBrowserQuery(group: "默认分组",
                                       includedGroupNames: catalog.includedGroupNames(id: DashboardFilterCatalog.virtualDefaultGroupID))

        XCTAssertEqual(query.apply(to: [other, legacy]).map(\.id), [legacy.id])
        XCTAssertFalse(legacy.enableDashboardMonitor)
        XCTAssertEqual(catalog.group(id: DashboardFilterCatalog.virtualDefaultGroupID)?.count, 1)
    }

    func testNameMigrationAndRenamePreserveCatalogIDsButDeletionClearsThem() {
        let groupID = UUID(), tagID = UUID()
        let initial = makeCatalog(groups: [.init(id: groupID, name: "生产", parentID: nil)],
                                  tags: [.init(id: tagID, name: "重要")], items: [item("1", group: "生产", tags: ["重要"])])
        XCTAssertEqual(initial.resolvedGroupID("", legacyName: "生产"), groupID.uuidString)
        XCTAssertEqual(initial.resolvedTagID("", legacyName: "重要"), tagID.uuidString)

        let renamed = makeCatalog(groups: [.init(id: groupID, name: "线上", parentID: nil)],
                                  tags: [.init(id: tagID, name: "紧急")], items: [item("1", group: "线上", tags: ["紧急"])])
        XCTAssertEqual(renamed.resolvedGroupID(groupID.uuidString), groupID.uuidString)
        XCTAssertEqual(renamed.resolvedTagID(tagID.uuidString), tagID.uuidString)
        XCTAssertEqual(renamed.group(id: groupID.uuidString)?.name, "线上")
        XCTAssertEqual(renamed.tag(id: tagID.uuidString)?.name, "紧急")

        let deleted = makeCatalog(groups: [], tags: [], items: [])
        XCTAssertEqual(deleted.resolvedGroupID(groupID.uuidString, legacyName: "生产"), "")
        XCTAssertEqual(deleted.resolvedTagID(tagID.uuidString, legacyName: "重要"), "")
    }

    func testUncataloguedLegacySelectionMovesToCatalogIDWhenDirectoryAppears() {
        let host = item("1", group: "外部导入", tags: ["迁移中"])
        let before = makeCatalog(groups: [], tags: [], items: [host])
        let groupSelection = before.resolvedGroupID("", legacyName: "外部导入")
        let tagSelection = before.resolvedTagID("", legacyName: "迁移中")
        XCTAssertFalse(groupSelection.isEmpty)
        XCTAssertFalse(tagSelection.isEmpty)

        let groupID = UUID(), tagID = UUID()
        let after = makeCatalog(groups: [.init(id: groupID, name: "外部导入", parentID: nil)],
                                tags: [.init(id: tagID, name: "迁移中")], items: [host])
        XCTAssertEqual(after.resolvedGroupID(groupSelection), groupID.uuidString)
        XCTAssertEqual(after.resolvedTagID(tagSelection), tagID.uuidString)
    }

    func testVirtualDefaultSelectionMovesToCatalogIDWhenDirectoryAppears() {
        let host = item("1", group: "默认分组")
        let before = makeCatalog(groups: [], tags: [], items: [host])
        XCTAssertEqual(before.resolvedGroupID(DashboardFilterCatalog.virtualDefaultGroupID),
                       DashboardFilterCatalog.virtualDefaultGroupID)
        let groupID = UUID()
        let after = makeCatalog(groups: [.init(id: groupID, name: "默认分组", parentID: nil)],
                                tags: [], items: [host])
        XCTAssertEqual(after.resolvedGroupID(DashboardFilterCatalog.virtualDefaultGroupID), groupID.uuidString)
    }

    @MainActor func testParentGroupStillCombinesSearchTagAndMonitoringFilters() {
        let parent = MachineBrowserGroup(id: UUID(), name: "生产", parentID: nil)
        let child = MachineBrowserGroup(id: UUID(), name: "数据库", parentID: parent.id)
        let matching = ServerRecord(name: "DB 01", host: "192.0.2.3", username: "root",
                                    groupName: "数据库", tagsText: "重要")
        let paused = ServerRecord(name: "DB 02", host: "192.0.2.4", username: "root",
                                  groupName: "数据库", tagsText: "重要", enableDashboardMonitor: false)
        let wrongTag = ServerRecord(name: "DB 03", host: "192.0.2.5", username: "root",
                                    groupName: "生产", tagsText: "测试")
        let projection = MachineBrowserProjection(items: [item("1", group: "数据库")], groups: [parent, child])
        let names = projection.groupNamesIncludingDescendants(of: parent.id)
        let query = ServerBrowserQuery(search: "DB", group: "生产", includedGroupNames: names,
                                       tag: "重要", monitoring: .enabled)
        XCTAssertEqual(query.apply(to: [paused, wrongTag, matching]).map(\.id), [matching.id])
        XCTAssertFalse(paused.enableDashboardMonitor)
    }

    @MainActor func testThousandHostDashboardFilterBenchmark() throws {
        let roots = (0..<8).map { MachineBrowserGroup(id: UUID(), name: "区域 \($0)", parentID: nil) }
        let groups = roots + (0..<40).map {
            MachineBrowserGroup(id: UUID(), name: "项目 \($0)", parentID: roots[$0 % roots.count].id)
        }
        let tagID = UUID()
        let servers = (0..<1_000).map { index in
            ServerRecord(
                name: "主机 \(index)", host: "192.0.2.\(index % 240 + 1)", username: "fixture",
                groupName: groups[index % groups.count].name,
                tagsText: index.isMultiple(of: 2) ? "生产" : "开发",
                enableDashboardMonitor: index.isMultiple(of: 3)
            )
        }
        let items = servers.map { server in
            MachineBrowserItem(
                id: server.id.uuidString, name: server.displayName, address: server.host,
                group: server.groupName, tags: server.tags, notes: server.notes,
                kind: "SSH", createdAt: server.createdAt,
                monitoringEnabled: server.enableDashboardMonitor
            )
        }

        let buildStart = ProcessInfo.processInfo.systemUptime
        let projection = MachineBrowserProjection(items: items, groups: groups)
        let catalog = DashboardFilterCatalog(
            projection: projection, items: items,
            tags: [DashboardCatalogTag(id: tagID, name: "生产")]
        )
        let buildMS = (ProcessInfo.processInfo.systemUptime - buildStart) * 1_000

        let parentNames = try XCTUnwrap(catalog.includedGroupNames(id: roots[2].id.uuidString))
        let production = try XCTUnwrap(catalog.tag(id: tagID.uuidString))
        let queries = [
            ServerBrowserQuery(group: roots[2].name, includedGroupNames: parentNames),
            ServerBrowserQuery(tag: production.name),
            ServerBrowserQuery(search: "主机 9"),
            ServerBrowserQuery(monitoring: .paused),
            ServerBrowserQuery(group: roots[2].name, includedGroupNames: parentNames,
                               tag: production.name, monitoring: .enabled)
        ]
        let filterStart = ProcessInfo.processInfo.systemUptime
        let results = queries.map { $0.apply(to: servers) }
        let filterMS = (ProcessInfo.processInfo.systemUptime - filterStart) * 1_000

        XCTAssertEqual(Set(results[0].map(\.id)), Set(servers.filter { parentNames.contains($0.groupName) }.map(\.id)))
        XCTAssertEqual(results[1].count, 500)
        XCTAssertEqual(results[3].count, 666)
        XCTAssertEqual(Set(results[4].map(\.id)), Set(servers.filter {
            parentNames.contains($0.groupName) && $0.tags.contains("生产") && $0.enableDashboardMonitor
        }.map(\.id)))

        let report: [String: Any] = [
            "hosts": servers.count,
            "groups": groups.count,
            "queries": queries.count,
            "mainThread": Thread.isMainThread,
            "catalogBuildMilliseconds": buildMS,
            "fiveDashboardQueriesMilliseconds": filterMS,
            "totalMeasuredMilliseconds": buildMS + filterMS,
            "semanticResultsEqual": true,
            "notes": "In-memory SSH records; measures dashboard catalog construction and ServerBrowserQuery filtering on the main actor, excluding fixture creation and SwiftUI rendering."
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("serverdash-dashboard-filter-benchmark.json")
        try data.write(to: url, options: .atomic)
        print("DASHBOARD_FILTER_BENCHMARK \(String(decoding: data, as: UTF8.self)); report=\(url.path)")
    }

    private func makeCatalog(groups: [MachineBrowserGroup], tags: [DashboardCatalogTag],
                             items: [MachineBrowserItem]) -> DashboardFilterCatalog {
        DashboardFilterCatalog(projection: MachineBrowserProjection(items: items, groups: groups),
                               items: items, tags: tags)
    }

    private func item(_ id: String, group: String, tags: [String] = []) -> MachineBrowserItem {
        MachineBrowserItem(id: id, name: "主机 \(id)", address: "192.0.2.1", group: group,
                           tags: tags, notes: "", kind: "SSH", createdAt: .now, monitoringEnabled: true)
    }
}
