import Foundation

/// Value-only input keeps live monitoring changes out of the browser index.
struct MachineBrowserItem: Equatable {
    let id: String
    let name: String
    let address: String
    let group: String
    let tags: [String]
    let notes: String
    let kind: String
    let createdAt: Date
    let monitoringEnabled: Bool?
}

struct MachineBrowserGroup: Equatable, Identifiable {
    let id: UUID
    let name: String
    let parentID: UUID?
}

struct MachineBrowserQuery: Equatable {
    var search = ""
    var group = ""
    var tag = ""
    var kind = "all"
    var monitoring = "all"
    var sort = "name"
}

struct MachineBrowserGroupRow: Identifiable {
    let group: MachineBrowserGroup
    let depth: Int
    let count: Int
    var id: UUID { group.id }
}

/// Rebuilt only when connection metadata or organization changes, never for latency updates.
struct MachineBrowserProjection {
    let items: [MachineBrowserItem]
    let groupRows: [MachineBrowserGroupRow]
    let groupCounts: [String: Int]
    let groupNames: Set<String>
    private let descendantNames: [String: Set<String>]
    private let searchableText: [String: String]
    private let sortedItems: [String: [MachineBrowserItem]]

    init(items: [MachineBrowserItem], groups: [MachineBrowserGroup]) {
        self.items = items
        groupNames = Set(groups.map(\.name))
        var text: [String: String] = [:]
        var directCounts: [String: Int] = [:]
        for item in items {
            text[item.id] = ([item.name, item.address, item.group, item.notes] + item.tags).joined(separator: "\n")
            directCounts[item.group, default: 0] += 1
        }
        searchableText = text

        let byID = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let children = Dictionary(grouping: groups.compactMap { value -> MachineBrowserGroup? in
            value.parentID == nil ? nil : value
        }, by: { $0.parentID! })
        var descendants: [String: Set<String>] = [:]
        var counts = directCounts
        for group in groups {
            var stack = [group]
            var seen = Set<UUID>()
            var names = Set<String>()
            while let value = stack.popLast() {
                guard seen.insert(value.id).inserted else { continue }
                names.insert(value.name)
                stack.append(contentsOf: children[value.id] ?? [])
            }
            descendants[group.name] = names
            counts[group.name] = names.reduce(0) { $0 + directCounts[$1, default: 0] }
        }
        descendantNames = descendants
        groupCounts = counts

        var rows: [MachineBrowserGroupRow] = []
        var visited = Set<UUID>()
        func append(_ value: MachineBrowserGroup, depth: Int) {
            guard visited.insert(value.id).inserted else { return }
            rows.append(.init(group: value, depth: depth, count: counts[value.name, default: 0]))
            for child in children[value.id] ?? [] { append(child, depth: depth + 1) }
        }
        for group in groups where group.parentID == nil || byID[group.parentID!] == nil { append(group, depth: 0) }
        // Imported malformed hierarchies remain visible without recursive loops.
        for group in groups where !visited.contains(group.id) { append(group, depth: 0) }
        groupRows = rows

        var orderings: [String: [MachineBrowserItem]] = [:]
        for sort in ["name", "nameDescending", "newest", "group"] {
            orderings[sort] = items.sorted { lhs, rhs in
                if sort == "newest", lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                if sort == "group", lhs.group != rhs.group { return lhs.group.localizedStandardCompare(rhs.group) == .orderedAscending }
                let order = lhs.name.localizedStandardCompare(rhs.name)
                if order != .orderedSame { return order == (sort == "nameDescending" ? .orderedDescending : .orderedAscending) }
                return lhs.id < rhs.id
            }
        }
        sortedItems = orderings
    }

    func filteredIDs(_ query: MachineBrowserQuery) -> [String] {
        let terms = query.search.split(whereSeparator: \.isWhitespace).map(String.init)
        let included = descendantNames[query.group] ?? [query.group]
        return (sortedItems[query.sort] ?? sortedItems["name"] ?? []).compactMap { item in
            guard query.kind == "all" || item.kind.lowercased() == query.kind,
                  query.group.isEmpty || included.contains(item.group),
                  query.tag.isEmpty || item.tags.contains(query.tag),
                  query.monitoring == "all" || item.monitoringEnabled == (query.monitoring == "enabled"),
                  terms.allSatisfy({ searchableText[item.id, default: ""].localizedCaseInsensitiveContains($0) }) else { return nil }
            return item.id
        }
    }
}

/// A deterministic memoization cache, without publishing from a SwiftUI body.
final class MachineBrowserProjectionCache {
    private var sourceItems: [MachineBrowserItem] = []
    private var sourceGroups: [MachineBrowserGroup] = []
    private var projection: MachineBrowserProjection?
    private var lastQuery: MachineBrowserQuery?
    private var lastIDs: [String] = []
    private(set) var buildCount = 0
    private(set) var filterCount = 0

    func resolve(items: [MachineBrowserItem], groups: [MachineBrowserGroup]) -> MachineBrowserProjection {
        if projection == nil || sourceItems != items || sourceGroups != groups {
            sourceItems = items; sourceGroups = groups
            projection = MachineBrowserProjection(items: items, groups: groups)
            lastQuery = nil
            buildCount += 1
        }
        return projection!
    }

    func filteredIDs(_ query: MachineBrowserQuery) -> [String] {
        if lastQuery != query {
            lastIDs = projection?.filteredIDs(query) ?? []
            lastQuery = query
            filterCount += 1
        }
        return lastIDs
    }
}

struct MachineBrowserLayout: Equatable {
    let contentWidth: CGFloat
    let prefersGroups: Bool
    var showsGroupPanel: Bool { prefersGroups && contentWidth >= 900 }
    var usesCompactToolbar: Bool { contentWidth < 760 }
    var usesCompactTable: Bool { contentWidth - (showsGroupPanel ? 191 : 0) < 760 }
}
