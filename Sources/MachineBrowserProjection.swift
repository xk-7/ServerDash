import Foundation

/// Value-only input keeps live monitoring changes out of the browser index.
struct MachineBrowserItem: Equatable {
    let id: String
    let name: String
    let address: String
    let username: String
    let group: String
    let tags: [String]
    let tagSearchText: String
    let notes: String
    let kind: String
    let createdAt: Date
    let monitoringEnabled: Bool?

    init(
        id: String,
        name: String,
        address: String,
        username: String = "",
        group: String,
        tags: [String],
        tagSearchText: String? = nil,
        notes: String,
        kind: String,
        createdAt: Date,
        monitoringEnabled: Bool?
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.username = username
        self.group = group
        self.tags = tags
        self.tagSearchText = tagSearchText ?? tags.joined(separator: " ")
        self.notes = notes
        self.kind = kind
        self.createdAt = createdAt
        self.monitoringEnabled = monitoringEnabled
    }
}

/// Cheap, exact dashboard invalidation input. SwiftData-backed values are read
/// on every body evaluation, while trimming, UUID formatting, and tag parsing
/// happen only when one of these query-relevant values (or its order) changes.
struct DashboardServerMetadataInput: Equatable {
    let id: UUID
    let name: String
    let address: String
    let username: String
    let group: String
    let tagsText: String
    let notes: String
    let createdAt: Date
    let monitoringEnabled: Bool

    init(server: ServerRecord) {
        id = server.id
        name = server.name
        address = server.host
        username = server.username
        group = server.groupName
        tagsText = server.tagsText
        notes = server.notes
        createdAt = server.createdAt
        monitoringEnabled = server.enableDashboardMonitor
    }

    init(
        id: UUID,
        name: String,
        address: String,
        username: String,
        group: String,
        tagsText: String,
        notes: String,
        createdAt: Date,
        monitoringEnabled: Bool
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.username = username
        self.group = group
        self.tagsText = tagsText
        self.notes = notes
        self.createdAt = createdAt
        self.monitoringEnabled = monitoringEnabled
    }

    fileprivate var browserItem: MachineBrowserItem {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let tags = tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return MachineBrowserItem(
            id: id.uuidString,
            name: trimmedName.isEmpty ? address : trimmedName,
            address: address,
            username: username,
            group: ServerBrowserQuery.effectiveGroupName(group),
            tags: tags,
            tagSearchText: tagsText,
            notes: notes,
            kind: "SSH",
            createdAt: createdAt,
            monitoringEnabled: monitoringEnabled
        )
    }
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

    var hasFilters: Bool {
        !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !group.isEmpty || !tag.isEmpty || kind != "all" || monitoring != "all"
    }
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
    private let indexByID: [String: Int]
    private let searchableText: [String: String]
    private let sortedItems: [String: [MachineBrowserItem]]

    init(items: [MachineBrowserItem], groups: [MachineBrowserGroup]) {
        self.items = items
        groupNames = Set(groups.map(\.name))
        var text: [String: String] = [:]
        var directCounts: [String: Int] = [:]
        var indices: [String: Int] = [:]
        for (index, item) in items.enumerated() {
            text[item.id] = ([
                item.name,
                item.address,
                item.username,
                item.group,
                item.tagSearchText,
                item.notes
            ] + item.tags).joined(separator: "\n")
            indices[item.id] = index
            directCounts[item.group, default: 0] += 1
        }
        searchableText = text
        indexByID = indices

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

    func itemIndex(id: String) -> Int? { indexByID[id] }

    /// The dashboard uses the same catalog hierarchy as the machine browser.
    func groupNamesIncludingDescendants(of id: UUID) -> Set<String>? {
        guard let name = groupNameByID[id] else { return nil }
        return descendantNames[name] ?? [name]
    }
}

struct DashboardProjectionResult {
    let catalog: DashboardFilterCatalog
    let query: MachineBrowserQuery
    let indices: [Int]
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

/// Shared dashboard and machine-browser catalog. IDs remain stable across renames;
/// virtual entries cover legacy records that have not acquired catalog records yet.
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

/// The machine page stores directory IDs in SceneStorage while keeping search,
/// protocol and sorting independent. Clearing filters must never change the sort.
struct MachineBrowserFilterState: Equatable {
    var search = ""
    var groupID = ""
    var tagID = ""
    var kind = "all"
    var monitoring = "all"
    var sort = "name"

    var hasFilters: Bool {
        !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !groupID.isEmpty || !tagID.isEmpty || kind != "all" || monitoring != "all"
    }

    func query(catalog: DashboardFilterCatalog) -> MachineBrowserQuery {
        MachineBrowserQuery(search: search,
                            group: catalog.group(id: groupID)?.name ?? "",
                            tag: catalog.tag(id: tagID)?.name ?? "",
                            kind: kind, monitoring: monitoring, sort: sort)
    }

    mutating func clearFilters() {
        search = ""
        groupID = ""
        tagID = ""
        kind = "all"
        monitoring = "all"
    }
}

/// A deterministic memoization cache, without publishing from a SwiftUI body.
final class MachineBrowserProjectionCache {
    private var sourceItems: [MachineBrowserItem] = []
    private var sourceGroups: [MachineBrowserGroup] = []
    private var dashboardMetadataInputs: [DashboardServerMetadataInput]?
    private var projection: MachineBrowserProjection?
    private var lastQuery: MachineBrowserQuery?
    private var lastIDs: [String] = []
    private var lastIndices: [Int] = []
    private var cachedDashboardCatalog: DashboardFilterCatalog?
    private var dashboardCatalogTags: [DashboardCatalogTag] = []
    private var dashboardCatalogProjectionBuild = -1
    private(set) var buildCount = 0
    private(set) var filterCount = 0
    private(set) var catalogBuildCount = 0

    func resolve(items: [MachineBrowserItem], groups: [MachineBrowserGroup]) -> MachineBrowserProjection {
        dashboardMetadataInputs = nil
        return resolveProjection(items: items, groups: groups)
    }

    private func resolveProjection(
        items: [MachineBrowserItem],
        groups: [MachineBrowserGroup]
    ) -> MachineBrowserProjection {
        if projection == nil || sourceItems != items || sourceGroups != groups {
            sourceItems = items; sourceGroups = groups
            projection = MachineBrowserProjection(items: items, groups: groups)
            lastQuery = nil
            lastIDs = []
            lastIndices = []
            cachedDashboardCatalog = nil
            buildCount += 1
        }
        return projection!
    }

    func filteredIDs(_ query: MachineBrowserQuery) -> [String] {
        if lastQuery != query {
            lastIDs = projection?.filteredIDs(query) ?? []
            lastIndices = lastIDs.compactMap { projection?.itemIndex(id: $0) }
            lastQuery = query
            filterCount += 1
        }
        return lastIDs
    }

    func filteredIndices(_ query: MachineBrowserQuery) -> [Int] {
        _ = filteredIDs(query)
        return lastIndices
    }

    func dashboardCatalog(
        items: [MachineBrowserItem],
        groups: [MachineBrowserGroup],
        tags: [DashboardCatalogTag]
    ) -> DashboardFilterCatalog {
        dashboardMetadataInputs = nil
        let resolved = resolveProjection(items: items, groups: groups)
        return dashboardCatalog(
            projection: resolved,
            items: items,
            tags: tags
        )
    }

    private func dashboardCatalog(
        projection resolved: MachineBrowserProjection,
        items: [MachineBrowserItem],
        tags: [DashboardCatalogTag]
    ) -> DashboardFilterCatalog {
        if cachedDashboardCatalog == nil ||
            dashboardCatalogProjectionBuild != buildCount ||
            dashboardCatalogTags != tags {
            cachedDashboardCatalog = DashboardFilterCatalog(
                projection: resolved,
                items: items,
                tags: tags
            )
            dashboardCatalogProjectionBuild = buildCount
            dashboardCatalogTags = tags
            catalogBuildCount += 1
        }
        return cachedDashboardCatalog!
    }

    func resolveDashboard(
        items: [MachineBrowserItem],
        groups: [MachineBrowserGroup],
        tags: [DashboardCatalogTag],
        query: (DashboardFilterCatalog) -> MachineBrowserQuery
    ) -> DashboardProjectionResult {
        let interval = PerformanceTrace.begin(.dashboardFilter)
        defer { PerformanceTrace.end(interval) }
        let catalog = dashboardCatalog(items: items, groups: groups, tags: tags)
        return dashboardResult(catalog: catalog, query: query)
    }

    func resolveDashboard(
        inputs: [DashboardServerMetadataInput],
        groups: [MachineBrowserGroup],
        tags: [DashboardCatalogTag],
        query: (DashboardFilterCatalog) -> MachineBrowserQuery
    ) -> DashboardProjectionResult {
        let interval = PerformanceTrace.begin(.dashboardFilter)
        defer { PerformanceTrace.end(interval) }
        let items: [MachineBrowserItem]
        let inputsChanged = dashboardMetadataInputs != inputs
        if inputsChanged {
            dashboardMetadataInputs = inputs
            items = inputs.map(\.browserItem)
        } else {
            items = sourceItems
        }
        let resolved: MachineBrowserProjection
        if inputsChanged || projection == nil || sourceGroups != groups {
            resolved = resolveProjection(items: items, groups: groups)
        } else {
            resolved = projection!
        }
        let catalog = dashboardCatalog(
            projection: resolved,
            items: items,
            tags: tags
        )
        return dashboardResult(catalog: catalog, query: query)
    }

    private func dashboardResult(
        catalog: DashboardFilterCatalog,
        query: (DashboardFilterCatalog) -> MachineBrowserQuery
    ) -> DashboardProjectionResult {
        let resolvedQuery = query(catalog)
        return DashboardProjectionResult(
            catalog: catalog,
            query: resolvedQuery,
            indices: filteredIndices(resolvedQuery)
        )
    }
}

struct MachineBrowserLayout: Equatable {
    let contentWidth: CGFloat
    let prefersGroups: Bool
    var showsGroupPanel: Bool { prefersGroups && contentWidth >= 900 }
    var usesCompactToolbar: Bool { contentWidth < 760 }
    var usesCompactTable: Bool { contentWidth - (showsGroupPanel ? 191 : 0) < 760 }
}
