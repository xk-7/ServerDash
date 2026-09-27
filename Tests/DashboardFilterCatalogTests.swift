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
        let projection = MachineBrowserProjection(
            items: [matching, paused, wrongTag].map { server in
                MachineBrowserItem(
                    id: server.id.uuidString,
                    name: server.displayName,
                    address: server.host,
                    username: server.username,
                    group: ServerBrowserQuery.effectiveGroupName(server.groupName),
                    tags: server.tags,
                    tagSearchText: server.tagsText,
                    notes: server.notes,
                    kind: "SSH",
                    createdAt: server.createdAt,
                    monitoringEnabled: server.enableDashboardMonitor
                )
            },
            groups: [parent, child]
        )
        let names = projection.groupNamesIncludingDescendants(of: parent.id)
        let query = ServerBrowserQuery(search: "DB", group: "生产", includedGroupNames: names,
                                       tag: "重要", monitoring: .enabled)
        XCTAssertEqual(query.apply(to: [paused, wrongTag, matching]).map(\.id), [matching.id])
        XCTAssertEqual(
            projection.filteredIDs(
                .init(
                    search: "DB root",
                    group: parent.name,
                    tag: "重要",
                    monitoring: ServerMonitorFilter.enabled.rawValue
                )
            ),
            [matching.id.uuidString]
        )
        XCTAssertFalse(paused.enableDashboardMonitor)
    }

    @MainActor func testDashboardMetadataInputCacheInvalidatesOnlyRelevantValuesAndKeepsIndicesExact() {
        let first = ServerRecord(
            name: "  ",
            host: "192.0.2.20",
            username: "deploy",
            groupName: "  ",
            tagsText: "Blue",
            enableDashboardMonitor: true
        )
        let second = ServerRecord(
            name: "Other",
            host: "192.0.2.21",
            username: "operator",
            groupName: "生产",
            tagsText: "Green",
            enableDashboardMonitor: true
        )
        let cache = MachineBrowserProjectionCache()
        func resolve(
            _ servers: [ServerRecord],
            query: MachineBrowserQuery
        ) -> DashboardProjectionResult {
            cache.resolveDashboard(
                inputs: servers.map { DashboardServerMetadataInput(server: $0) },
                groups: [],
                tags: [],
                query: { _ in query }
            )
        }

        XCTAssertEqual(resolve([first, second], query: .init(search: "deploy")).indices, [0])
        XCTAssertEqual(resolve([first, second], query: .init(search: "deploy")).indices, [0])
        XCTAssertEqual(cache.buildCount, 1)
        XCTAssertEqual(cache.catalogBuildCount, 1)
        XCTAssertEqual(cache.filterCount, 1)

        first.lastLatencyMS = 125
        XCTAssertEqual(resolve([first, second], query: .init(search: "deploy")).indices, [0])
        XCTAssertEqual(cache.buildCount, 1)

        first.username = "release"
        first.tagsText = " Blue, Critical , "
        let changed = resolve(
            [first, second],
            query: .init(
                search: "192.0.2.20 release",
                group: "默认分组",
                tag: "Critical"
            )
        )
        XCTAssertEqual(changed.indices, [0])
        XCTAssertEqual(cache.buildCount, 2)
        XCTAssertEqual(cache.catalogBuildCount, 2)
        XCTAssertEqual(
            resolve([first, second], query: .init(search: "Blue,")).indices,
            [0]
        )

        let reordered = resolve(
            [second, first],
            query: .init(search: "release", tag: "Critical")
        )
        XCTAssertEqual(reordered.indices, [1])
        XCTAssertEqual(cache.buildCount, 3)

        first.enableDashboardMonitor = false
        XCTAssertTrue(
            resolve(
                [second, first],
                query: .init(search: "release", monitoring: "enabled")
            ).indices.isEmpty
        )
        XCTAssertEqual(cache.buildCount, 4)
    }

    @MainActor func testHundredAndThousandHostDashboardProjectionBenchmark() throws {
        var reports: [[String: Any]] = []

        for hostCount in [100, 1_000] {
            let rootRecords = (0..<8).map {
                MachineGroupRecord(name: "区域 \($0)")
            }
            let groupRecords = rootRecords + (0..<40).map {
                MachineGroupRecord(
                    name: "项目 \($0)",
                    parentID: rootRecords[$0 % rootRecords.count].id
                )
            }
            let tagRecord = MachineTagRecord(name: "生产")
            func makeGroups() -> [MachineBrowserGroup] {
                groupRecords.map {
                    MachineBrowserGroup(id: $0.id, name: $0.name, parentID: $0.parentID)
                }
            }
            let groups = makeGroups()
            let roots = Array(groups.prefix(rootRecords.count))
            let servers = (0..<hostCount).map { index in
                ServerRecord(
                    name: "主机 \(index)",
                    host: "192.0.2.\(index % 240 + 1)",
                    username: "operator\(index % 10)",
                    groupName: groups[index % groups.count].name,
                    tagsText: index.isMultiple(of: 2) ? "生产" : "开发",
                    enableDashboardMonitor: index.isMultiple(of: 3)
                )
            }
            func makeItems() -> [MachineBrowserItem] {
                servers.map { server in
                    MachineBrowserItem(
                        id: server.id.uuidString,
                        name: server.displayName,
                        address: server.host,
                        username: server.username,
                        group: ServerBrowserQuery.effectiveGroupName(server.groupName),
                        tags: server.tags,
                        tagSearchText: server.tagsText,
                        notes: server.notes,
                        kind: "SSH",
                        createdAt: server.createdAt,
                        monitoringEnabled: server.enableDashboardMonitor
                    )
                }
            }
            func makeDashboardInputs() -> [DashboardServerMetadataInput] {
                servers.map { DashboardServerMetadataInput(server: $0) }
            }
            func makeTags() -> [DashboardCatalogTag] {
                [DashboardCatalogTag(id: tagRecord.id, name: tagRecord.name)]
            }
            let items = makeItems()
            let catalogTags = makeTags()
            let referenceProjection = MachineBrowserProjection(items: items, groups: groups)
            let referenceCatalog = DashboardFilterCatalog(
                projection: referenceProjection,
                items: items,
                tags: catalogTags
            )
            let parentNames = try XCTUnwrap(
                referenceCatalog.includedGroupNames(id: roots[2].id.uuidString)
            )
            let production = try XCTUnwrap(referenceCatalog.tag(id: tagRecord.id.uuidString))
            let queryPairs: [(ServerBrowserQuery, MachineBrowserQuery)] = [
                (.init(), .init()),
                (.init(search: "operator9"), .init(search: "operator9")),
                (
                    .init(
                        group: roots[2].name,
                        includedGroupNames: parentNames,
                        sort: .group
                    ),
                    .init(group: roots[2].name, sort: "group")
                ),
                (
                    .init(tag: production.name, sort: .newest, monitoring: .enabled),
                    .init(
                        tag: production.name,
                        monitoring: ServerMonitorFilter.enabled.rawValue,
                        sort: ServerBrowserSort.newest.rawValue
                    )
                ),
                (
                    .init(search: "主机 9 operator9", sort: .nameDescending),
                    .init(
                        search: "主机 9 operator9",
                        sort: ServerBrowserSort.nameDescending.rawValue
                    )
                )
            ]

            let semanticCache = MachineBrowserProjectionCache()
            _ = semanticCache.dashboardCatalog(
                items: items,
                groups: groups,
                tags: catalogTags
            )
            for (legacy, cached) in queryPairs {
                let expected = legacy.apply(to: servers).map(\.id)
                let actual = semanticCache.filteredIndices(cached).map { servers[$0].id }
                XCTAssertEqual(actual, expected)
            }

            let bodyGroupID = roots[2].id.uuidString
            let bodyTagID = tagRecord.id.uuidString
            func legacyDashboardBody(
                cache: MachineBrowserProjectionCache
            ) -> (visible: [ServerRecord], catalog: DashboardFilterCatalog) {
                let bodyItems = makeItems()
                let projection = cache.resolve(
                    items: bodyItems,
                    groups: makeGroups()
                )
                let catalog = DashboardFilterCatalog(
                    projection: projection,
                    items: bodyItems,
                    tags: makeTags()
                )
                let query = ServerBrowserQuery(
                    search: "operator8",
                    group: catalog.group(id: bodyGroupID)?.name ?? "",
                    includedGroupNames: catalog.includedGroupNames(id: bodyGroupID),
                    tag: catalog.tag(id: bodyTagID)?.name ?? "",
                    sort: .group,
                    monitoring: .enabled
                )
                return (query.apply(to: servers), catalog)
            }
            func cachedDashboardBody(
                cache: MachineBrowserProjectionCache
            ) -> (visible: [ServerRecord], catalog: DashboardFilterCatalog) {
                let result = cache.resolveDashboard(
                    inputs: makeDashboardInputs(),
                    groups: makeGroups(),
                    tags: makeTags(),
                    query: { catalog in
                        MachineBrowserQuery(
                            search: "operator8",
                            group: catalog.group(id: bodyGroupID)?.name ?? "",
                            tag: catalog.tag(id: bodyTagID)?.name ?? "",
                            monitoring: ServerMonitorFilter.enabled.rawValue,
                            sort: ServerBrowserSort.group.rawValue
                        )
                    }
                )
                let visible = result.indices.compactMap { index in
                    servers.indices.contains(index) ? servers[index] : nil
                }
                return (visible, result.catalog)
            }

            let legacySemanticBody = legacyDashboardBody(
                cache: MachineBrowserProjectionCache()
            )
            let cachedSemanticBody = cachedDashboardBody(
                cache: MachineBrowserProjectionCache()
            )
            XCTAssertEqual(
                cachedSemanticBody.visible.map(\.id),
                legacySemanticBody.visible.map(\.id)
            )

            let cold = benchmark(warmups: 3, iterations: 30) {
                let cache = MachineBrowserProjectionCache()
                let result = cache.resolveDashboard(
                    items: items,
                    groups: groups,
                    tags: catalogTags,
                    query: { _ in queryPairs[3].1 }
                )
                return result.indices.count + result.catalog.groups.count
            }

            let filterCache = MachineBrowserProjectionCache()
            _ = filterCache.dashboardCatalog(items: items, groups: groups, tags: catalogTags)
            let queries = benchmark(warmups: 3, iterations: 30) {
                queryPairs.reduce(into: 0) { count, pair in
                    count += filterCache.filteredIndices(pair.1).count
                }
            }

            let legacyBodyCache = MachineBrowserProjectionCache()
            let cachedBodyCache = MachineBrowserProjectionCache()
            let bodyComparison = benchmarkPair(warmups: 3, iterations: 30) {
                let result = legacyDashboardBody(cache: legacyBodyCache)
                return result.visible.count + result.catalog.groups.count
                    + result.catalog.tags.count
            } second: {
                let result = cachedDashboardBody(cache: cachedBodyCache)
                return result.visible.count + result.catalog.groups.count
                    + result.catalog.tags.count
            }
            XCTAssertEqual(
                bodyComparison.first.checksum,
                bodyComparison.second.checksum
            )

            let buildConfiguration: String
            #if DEBUG
            buildConfiguration = "Debug"
            #else
            buildConfiguration = "Release"
            #endif

            reports.append([
                "hosts": hostCount,
                "groups": groups.count,
                "queriesPerIteration": queryPairs.count,
                "iterations": 30,
                "warmups": 3,
                "mainThread": Thread.isMainThread,
                "processIdentifier": ProcessInfo.processInfo.processIdentifier,
                "buildConfiguration": buildConfiguration,
                "baselineCommit": "e4d6b84e8561be3fe0688bb38fb9685654e5ffa3",
                "legacyDashboardBodyProjectionAndFilter": [
                    "medianMilliseconds": bodyComparison.first.median,
                    "p95Milliseconds": bodyComparison.first.p95,
                    "checksum": bodyComparison.first.checksum
                ],
                "cachedDashboardInputsAndIndexLookup": [
                    "medianMilliseconds": bodyComparison.second.median,
                    "p95Milliseconds": bodyComparison.second.p95,
                    "checksum": bodyComparison.second.checksum
                ],
                "dashboardBodyMedianSpeedup": bodyComparison.first.median
                    / max(bodyComparison.second.median, Double.leastNonzeroMagnitude),
                "coldCatalogAndFilterMedianMilliseconds": cold.median,
                "coldCatalogAndFilterP95Milliseconds": cold.p95,
                "fiveQueriesMedianMilliseconds": queries.median,
                "fiveQueriesP95Milliseconds": queries.p95,
                "cachedDashboardInputAndLookupMedianMilliseconds": bodyComparison.second.median,
                "cachedDashboardInputAndLookupP95Milliseconds": bodyComparison.second.p95,
                "semanticResultsEqual": true,
                "checksum": cold.checksum + queries.checksum
                    + bodyComparison.first.checksum + bodyComparison.second.checksum,
                "comparisonScope": "Same-process e4d6b84 body-algorithm replay and current cached body path over identical SwiftData model objects. The legacy path rebuilds fully derived item/group/tag values, retains its projection cache exactly as the old @State did, then rebuilds DashboardFilterCatalog and runs full ServerBrowserQuery filtering/sorting on every body evaluation. The current path rebuilds exact raw metadata inputs, derives UUID/name/group/tag values only after relevant input changes, reuses catalog/filter results, and maps cached indices back to servers.",
                "excluded": "Geometry, SwiftUI layout, card body rendering, scrolling, and first-frame presentation are excluded. This is a dashboard metadata/filter body-path microbenchmark.",
                "diagnostics": "Cold catalog/filter uses prebuilt inputs. Five-query timing exercises current cached projection queries and is not part of the legacy/current body ratio.",
                "releaseInvocation": "Scripts/benchmark-macos.sh compiles and runs this comparison in Release with -O."
            ])
        }

        let data = try JSONSerialization.data(
            withJSONObject: [
                "measurements": reports,
                "testHostResourceUsage": MacPerformanceResourceMetrics.cumulativeTestHostSnapshot()
            ],
            options: [.prettyPrinted, .sortedKeys]
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("serverdash-dashboard-benchmark.json")
        try data.write(to: url, options: .atomic)
        print("DASHBOARD_PERFORMANCE \(String(decoding: data, as: UTF8.self)); report=\(url.path)")
    }

    private func benchmark(
        warmups: Int,
        iterations: Int,
        operation: () -> Int
    ) -> (median: Double, p95: Double, checksum: Int) {
        for _ in 0..<warmups { _ = operation() }
        var durations: [Double] = []
        var checksum = 0
        durations.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let started = ProcessInfo.processInfo.systemUptime
            checksum &+= operation()
            durations.append(
                (ProcessInfo.processInfo.systemUptime - started) * 1_000
            )
        }
        durations.sort()
        let median = durations[durations.count / 2]
        let p95Index = min(
            durations.count - 1,
            max(0, Int(ceil(Double(durations.count) * 0.95)) - 1)
        )
        return (median, durations[p95Index], checksum)
    }

    private func benchmarkPair(
        warmups: Int,
        iterations: Int,
        first: () -> Int,
        second: () -> Int
    ) -> (
        first: (median: Double, p95: Double, checksum: Int),
        second: (median: Double, p95: Double, checksum: Int)
    ) {
        for _ in 0..<warmups {
            _ = first()
            _ = second()
        }
        var firstDurations: [Double] = []
        var secondDurations: [Double] = []
        var firstChecksum = 0
        var secondChecksum = 0
        firstDurations.reserveCapacity(iterations)
        secondDurations.reserveCapacity(iterations)

        func measure(
            _ operation: () -> Int,
            durations: inout [Double],
            checksum: inout Int
        ) {
            let started = ProcessInfo.processInfo.systemUptime
            checksum &+= operation()
            durations.append(
                (ProcessInfo.processInfo.systemUptime - started) * 1_000
            )
        }

        for iteration in 0..<iterations {
            if iteration.isMultiple(of: 2) {
                measure(first, durations: &firstDurations, checksum: &firstChecksum)
                measure(second, durations: &secondDurations, checksum: &secondChecksum)
            } else {
                measure(second, durations: &secondDurations, checksum: &secondChecksum)
                measure(first, durations: &firstDurations, checksum: &firstChecksum)
            }
        }
        return (
            statistics(firstDurations, checksum: firstChecksum),
            statistics(secondDurations, checksum: secondChecksum)
        )
    }

    private func statistics(
        _ durations: [Double],
        checksum: Int
    ) -> (median: Double, p95: Double, checksum: Int) {
        let sorted = durations.sorted()
        let median = sorted[sorted.count / 2]
        let p95Index = min(
            sorted.count - 1,
            max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        )
        return (median, sorted[p95Index], checksum)
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
