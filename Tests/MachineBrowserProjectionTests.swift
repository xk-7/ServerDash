import Foundation
import XCTest
@testable import ServerDash

final class MachineBrowserProjectionTests: XCTestCase {
    func testHierarchyCountsAndFilteringIncludeDescendants() {
        let parent = MachineBrowserGroup(id: UUID(), name: "生产", parentID: nil)
        let child = MachineBrowserGroup(id: UUID(), name: "数据库", parentID: parent.id)
        let leaf = MachineBrowserGroup(id: UUID(), name: "只读副本", parentID: child.id)
        let items = [item("1", group: parent.name), item("2", group: child.name), item("3", group: leaf.name), item("4")]
        let projection = MachineBrowserProjection(items: items, groups: [parent, child, leaf])
        XCTAssertEqual(projection.groupRows.map(\.depth), [0, 1, 2])
        XCTAssertEqual(projection.groupRows.map(\.count), [3, 2, 1])
        XCTAssertEqual(projection.groupCounts["默认分组"], 1)
        XCTAssertEqual(Set(projection.filteredIDs(.init(group: parent.name))), ["1", "2", "3"])
        XCTAssertEqual(projection.filteredIDs(.init(group: "默认分组")), ["4"])
    }

    func testSearchCombinesFieldsAndPreservesProtocolAndMonitoringRules() {
        let items = [
            item("1", name: "生产 API", group: "广州", tags: ["Blue"], kind: "SSH", monitoring: true),
            item("2", name: "生产 API", group: "广州", tags: ["Blue"], kind: "RDP", monitoring: nil),
            item("3", name: "开发 API", group: "北京", tags: ["Green"], kind: "SSH", monitoring: false)
        ]
        let projection = MachineBrowserProjection(items: items, groups: [])
        XCTAssertEqual(projection.filteredIDs(.init(search: "生产 blue 广州", kind: "rdp")), ["2"])
        XCTAssertEqual(projection.filteredIDs(.init(search: "API", monitoring: "enabled")), ["1"])
        XCTAssertEqual(projection.filteredIDs(.init(search: "API", monitoring: "disabled")), ["3"])
        XCTAssertEqual(projection.filteredIDs(.init(search: "9999")), ["3", "1", "2"])
        XCTAssertEqual(projection.filteredIDs(.init(tag: "Blue")), ["1", "2"])
        XCTAssertTrue(projection.filteredIDs(.init(search: "不存在")).isEmpty)
    }

    func testDeterministicNaturalSortingAndMetadataInvalidation() {
        let cache = MachineBrowserProjectionCache()
        let items = [item("1", name: "Host 10"), item("2", name: "Host 2"), item("3", name: "Host 2")]
        _ = cache.resolve(items: items, groups: [])
        XCTAssertEqual(cache.filteredIDs(.init()), ["2", "3", "1"])
        _ = cache.resolve(items: items, groups: [])
        XCTAssertEqual(cache.filteredIDs(.init()), ["2", "3", "1"])
        XCTAssertEqual(cache.buildCount, 1)
        XCTAssertEqual(cache.filterCount, 1)
        XCTAssertEqual(cache.filteredIDs(.init(sort: "nameDescending")), ["1", "2", "3"])
        XCTAssertEqual(cache.buildCount, 1)
        XCTAssertEqual(cache.filterCount, 2)
        _ = cache.resolve(items: [item("1", name: "Renamed")] + Array(items.dropFirst()), groups: [])
        XCTAssertEqual(cache.buildCount, 2)
        XCTAssertEqual(cache.filteredIDs(.init(search: "Renamed")), ["1"])
    }

    func testMalformedHierarchyCannotHideGroupsOrLoop() {
        let a = UUID(), b = UUID()
        let groups = [MachineBrowserGroup(id: a, name: "循环 A", parentID: b),
                      MachineBrowserGroup(id: b, name: "循环 B", parentID: a),
                      MachineBrowserGroup(id: UUID(), name: "缺失父分组", parentID: UUID())]
        let projection = MachineBrowserProjection(items: [item("1", group: "循环 B")], groups: groups)
        XCTAssertEqual(Set(projection.groupRows.map(\.id)), Set(groups.map(\.id)))
        XCTAssertEqual(projection.groupRows.count, 3)
        XCTAssertEqual(projection.filteredIDs(.init(group: "循环 A")), ["1"])
    }

    func testNarrowLayoutDoesNotChangeWideWindowPreference() {
        for preference in [true, false] {
            let wide = MachineBrowserLayout(contentWidth: 1100, prefersGroups: preference)
            let narrow = MachineBrowserLayout(contentWidth: 670, prefersGroups: wide.prefersGroups)
            let restored = MachineBrowserLayout(contentWidth: 1100, prefersGroups: narrow.prefersGroups)
            XCTAssertFalse(narrow.showsGroupPanel)
            XCTAssertTrue(narrow.usesCompactToolbar)
            XCTAssertTrue(narrow.usesCompactTable)
            XCTAssertEqual(restored.showsGroupPanel, preference)
            XCTAssertEqual(restored.prefersGroups, preference)
        }
        XCTAssertTrue(MachineBrowserLayout(contentWidth: 900, prefersGroups: true).showsGroupPanel)
        XCTAssertFalse(MachineBrowserLayout(contentWidth: 899, prefersGroups: true).showsGroupPanel)
    }

    @MainActor func testThousandHostBeforeAndAfterBenchmark() throws {
        let roots = (0..<8).map { MachineBrowserGroup(id: UUID(), name: "区域 \($0)", parentID: nil) }
        let groups = roots + (0..<40).map { MachineBrowserGroup(id: UUID(), name: "项目 \($0)", parentID: roots[$0 % roots.count].id) }
        let items = (0..<1000).map { index in
            item("\(index)", name: "主机 \(index)", group: groups[index % groups.count].name,
                 tags: [index.isMultiple(of: 2) ? "生产" : "开发"], monitoring: index.isMultiple(of: 3))
        }
        let queries = [MachineBrowserQuery(), .init(search: "主机 9"), .init(group: roots[2].name),
                       .init(tag: "生产", monitoring: "enabled"), .init(sort: "group"), .init(search: "9999", sort: "newest")]
        let beforeStart = ProcessInfo.processInfo.systemUptime
        let beforeCounts = Dictionary(uniqueKeysWithValues: groups.map { group in
            (group.name, items.filter { legacyGroupNames(group.name, groups: groups).contains($0.group) }.count)
        })
        let beforeResults = queries.map { legacyFilter(items, groups: groups, query: $0) }
        let beforeMS = (ProcessInfo.processInfo.systemUptime - beforeStart) * 1000
        let afterStart = ProcessInfo.processInfo.systemUptime
        let cache = MachineBrowserProjectionCache()
        let projection = cache.resolve(items: items, groups: groups)
        let afterResults = queries.map { cache.filteredIDs($0) }
        let afterMS = (ProcessInfo.processInfo.systemUptime - afterStart) * 1000
        XCTAssertEqual(beforeResults, afterResults)
        XCTAssertEqual(beforeCounts, projection.groupCounts)

        let repeatStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<100 {
            _ = cache.resolve(items: items, groups: groups)
            _ = cache.filteredIDs(queries.last!)
        }
        let repeatMS = (ProcessInfo.processInfo.systemUptime - repeatStart) * 1000
        XCTAssertEqual(cache.buildCount, 1)
        // Synchronous main-actor wall time is the period this work occupies the UI thread.
        let report: [String: Any] = ["hosts": items.count, "groups": groups.count,
            "queryCount": queries.count, "mainThread": Thread.isMainThread,
            "beforeMainThreadMilliseconds": beforeMS, "afterMainThreadMilliseconds": afterMS,
            "cached100UpdatesMainThreadMilliseconds": repeatMS, "semanticResultsEqual": true,
            "notes": "Old per-row hierarchy/count scans and per-query sorts versus one projection build plus cached sorts; includes construction cost."]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("serverdash-mac-browser-benchmark.json")
        try data.write(to: url, options: .atomic)
        print("Machine browser benchmark: \(String(decoding: data, as: UTF8.self)); report=\(url.path)")
    }

    private func item(_ id: String, name: String? = nil, group: String = "默认分组", tags: [String] = [],
                      kind: String = "SSH", monitoring: Bool? = true) -> MachineBrowserItem {
        .init(id: id, name: name ?? "主机 \(id)", address: "user@host:9999", group: group,
              tags: tags, notes: "中文备注", kind: kind, createdAt: Date(timeIntervalSince1970: 100), monitoringEnabled: monitoring)
    }

    private func legacyGroupNames(_ name: String, groups: [MachineBrowserGroup]) -> Set<String> {
        guard let parent = groups.first(where: { $0.name == name }) else { return [name] }
        var ids: Set<UUID> = [parent.id]
        var changed = true
        while changed {
            changed = false
            for group in groups where group.parentID.map(ids.contains) == true {
                if ids.insert(group.id).inserted { changed = true }
            }
        }
        return Set(groups.filter { ids.contains($0.id) }.map(\.name))
    }

    private func legacyFilter(_ items: [MachineBrowserItem], groups: [MachineBrowserGroup], query: MachineBrowserQuery) -> [String] {
        let included = legacyGroupNames(query.group, groups: groups)
        let terms = query.search.split(whereSeparator: \.isWhitespace).map(String.init)
        return items.filter { item in
            (query.kind == "all" || item.kind.lowercased() == query.kind) &&
            (query.group.isEmpty || included.contains(item.group)) && (query.tag.isEmpty || item.tags.contains(query.tag)) &&
            (query.monitoring == "all" || item.monitoringEnabled == (query.monitoring == "enabled")) &&
            terms.allSatisfy { term in [item.name, item.address, item.group, item.tags.joined(separator: " "), item.notes].contains { $0.localizedCaseInsensitiveContains(term) } }
        }.sorted {
            if query.sort == "newest", $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            if query.sort == "group", $0.group != $1.group { return $0.group.localizedStandardCompare($1.group) == .orderedAscending }
            let order = $0.name.localizedStandardCompare($1.name)
            if order != .orderedSame { return order == (query.sort == "nameDescending" ? .orderedDescending : .orderedAscending) }
            return $0.id < $1.id
        }.map(\.id)
    }
}
