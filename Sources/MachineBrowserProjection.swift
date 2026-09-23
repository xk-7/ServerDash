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
    private let groupNameByID: [UUID: String]
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
        groupNameByID = byID.mapValues(\.name)
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

    /// The dashboard uses the same catalog hierarchy as the machine browser.
    func groupNamesIncludingDescendants(of id: UUID) -> Set<String>? {
        guard let name = groupNameByID[id] else { return nil }
        return descendantNames[name] ?? [name]
    }
}

struct DashboardFilterOption: Identifiable, Equatable {
    let id: String
    let name: String
    let depth: Int
    let count: Int
}

struct DashboardCatalogTag: Equatable {
    let id: UUID
    let name: String
}

/// Dashboard-only presentation of the machine catalog. IDs remain stable across renames;
/// virtual entries cover legacy SSH records that have not acquired catalog records yet.
struct DashboardFilterCatalog {
    static let virtualDefaultGroupID = "virtual-default-group"
    private static let legacyGroupPrefix = "legacy-group:"
    private static let legacyTagPrefix = "legacy-tag:"

    let groups: [DashboardFilterOption]
    let tags: [DashboardFilterOption]
    private let projection: MachineBrowserProjection

    init(projection: MachineBrowserProjection, items: [MachineBrowserItem], tags catalogTags: [DashboardCatalogTag]) {
        self.projection = projection
        let catalogNames = projection.groupNames
        let directCounts = Dictionary(grouping: items, by: \.group).mapValues(\.count)
        var groupOptions = projection.groupRows.map {
            DashboardFilterOption(id: $0.id.uuidString, name: $0.group.name, depth: $0.depth, count: $0.count)
        }
        if !catalogNames.contains("默认分组") {
            groupOptions.insert(.init(id: Self.virtualDefaultGroupID, name: "默认分组", depth: 0,
                                      count: directCounts["默认分组", default: 0]), at: 0)
        }
        for name in Set(items.map(\.group)).subtracting(catalogNames).subtracting(["默认分组"])
            .sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            groupOptions.append(.init(id: Self.legacyGroupPrefix + name, name: name, depth: 0,
                                      count: directCounts[name, default: 0]))
        }
        groups = groupOptions

        let tagCounts = items.flatMap(\.tags).reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        var tagOptions = catalogTags.map {
            DashboardFilterOption(id: $0.id.uuidString, name: $0.name, depth: 0,
                                  count: tagCounts[$0.name, default: 0])
        }
        let knownTags = Set(catalogTags.map(\.name))
        for name in Set(tagCounts.keys).subtracting(knownTags)
            .sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            tagOptions.append(.init(id: Self.legacyTagPrefix + name, name: name, depth: 0,
                                    count: tagCounts[name, default: 0]))
        }
        tags = tagOptions
    }

    func group(id: String) -> DashboardFilterOption? { groups.first { $0.id == id } }
    func tag(id: String) -> DashboardFilterOption? { tags.first { $0.id == id } }

    func includedGroupNames(id: String) -> Set<String>? {
        guard let option = group(id: id) else { return nil }
        if let catalogID = UUID(uuidString: id) {
            return projection.groupNamesIncludingDescendants(of: catalogID)
        }
        return [option.name]
    }

    /// A deleted UUID must clear, even if a virtual entry with its former name remains.
    func resolvedGroupID(_ storedID: String, legacyName: String = "") -> String {
        if !storedID.isEmpty {
            if storedID == Self.virtualDefaultGroupID,
               let current = groups.first(where: { $0.name == "默认分组" }) {
                return current.id
            }
            if storedID.hasPrefix(Self.legacyGroupPrefix),
               let current = groups.first(where: { $0.name == String(storedID.dropFirst(Self.legacyGroupPrefix.count)) }) {
                return current.id
            }
            return group(id: storedID) == nil ? "" : storedID
        }
        return groups.first(where: { $0.name == legacyName })?.id ?? ""
    }

    func resolvedTagID(_ storedID: String, legacyName: String = "") -> String {
        if !storedID.isEmpty {
            if storedID.hasPrefix(Self.legacyTagPrefix),
               let current = tags.first(where: { $0.name == String(storedID.dropFirst(Self.legacyTagPrefix.count)) }) {
                return current.id
            }
            return tag(id: storedID) == nil ? "" : storedID
        }
        return tags.first(where: { $0.name == legacyName })?.id ?? ""
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
