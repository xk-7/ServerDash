#if os(macOS)
import Combine
import Foundation
import XCTest
@testable import ServerDash

@MainActor private final class FilePublicationCounter {
    var count = 0
}

@inline(never) private func legacyFileBodyProjection(_ items: [RemoteFileItem], selection: Set<String>) -> ([String], [RemoteFileItem]) {
    (items.map(\.id), items.filter { selection.contains($0.id) })
}

final class MacSFTPPerformanceTests: XCTestCase {
    private func files(_ count: Int) -> [RemoteFileItem] {
        (0..<count).map { index in
            let name = index.isMultiple(of: 10) ? ".hidden-\(index)" : "中文配置-\(index).txt"
            return RemoteFileItem(path: "/fixture/\(name)", name: name, kind: .file,
                                  size: Int64(index), permissions: "rw-r--r--", owner: "fixture",
                                  group: "fixture", modifiedText: "2026-09-27")
        }
    }

    @MainActor func testScrollingDoesNotPublishOrRebuildTheListing() {
        let app = AppState(trustCoordinator: HostTrustCoordinator(), fileServicesEnabled: false)
        let controller = MacSFTPController(server: ServerRecord(name: "fixture", host: "fixture.invalid", username: "fixture"), appState: app, automaticallyConnect: false)
        controller.applyDirectoryListing(.init(path: "/fixture", items: files(10_000)))
        controller.selection = [controller.visibleItemIDs[5], controller.visibleItemIDs[50]]
        let expectedSelection = controller.selectedItems
        let generation = controller.listingProjectionBuildCount
        let counter = FilePublicationCounter()
        let observation = controller.objectWillChange.sink { [counter] in
            MainActor.assumeIsolated { counter.count += 1 }
        }
        for row in 0..<1_000 { controller.scrollAnchor = controller.visibleItemIDs[row] }
        XCTAssertEqual(counter.count, 0)
        XCTAssertEqual(controller.listingProjectionBuildCount, generation)
        XCTAssertEqual(controller.selectedItems, expectedSelection)
        XCTAssertEqual(controller.scrollAnchor, controller.visibleItemIDs[999])
        withExtendedLifetime(observation) {}
        controller.close()
    }

    @MainActor func testCachedSelectionOrderingTracksListingRefreshAndFilters() {
        let app = AppState(trustCoordinator: HostTrustCoordinator(), fileServicesEnabled: false)
        let controller = MacSFTPController(server: ServerRecord(name: "fixture", host: "fixture.invalid", username: "fixture"), appState: app, automaticallyConnect: false)
        let all = files(20)
        controller.applyDirectoryListing(.init(path: "/fixture", items: all))
        controller.selection = [all[2].id, all[7].id]
        XCTAssertEqual(controller.selectedItems.map(\.id), [all[2].id, all[7].id])
        controller.scrollAnchor = all[7].id
        controller.applyDirectoryListing(.init(path: "/fixture", items: all.reversed()))
        XCTAssertEqual(controller.selectedItems.map(\.id), [all[7].id, all[2].id])
        XCTAssertEqual(controller.scrollAnchor, all[7].id)
        controller.search = "-2."
        XCTAssertEqual(controller.selection, [all[2].id])
        XCTAssertEqual(controller.scrollAnchor, all[2].id)
        XCTAssertEqual(controller.visibleItems(matching: [all[0].id, all[2].id]), [all[2]])
        controller.search = ""
        XCTAssertEqual(controller.selection, [all[2].id])
        controller.close()
    }

    @MainActor func testTenThousandFilesRepeatedRenderBenchmark() throws {
        let app = AppState(trustCoordinator: HostTrustCoordinator(), fileServicesEnabled: false)
        let controller = MacSFTPController(server: ServerRecord(name: "fixture", host: "fixture.invalid", username: "fixture"), appState: app, automaticallyConnect: false)
        let all = files(10_000)
        controller.applyDirectoryListing(.init(path: "/fixture", items: all))
        controller.selection = Set(controller.visibleItemIDs.suffix(4))
        let visible = controller.visibleItems, selected = controller.selection
        var checksum = 0
        func duration(_ body: () -> Void) -> Double {
            let start = ContinuousClock.now
            body()
            let d = start.duration(to: .now).components
            return Double(d.seconds) * 1_000 + Double(d.attoseconds) / 1e15
        }
        func oldRender() {
            for _ in 0..<100 {
                let (ids, chosen) = legacyFileBodyProjection(visible, selection: selected)
                checksum += ids.count + chosen.count
            }
        }
        func cachedRender() {
            for _ in 0..<100 { checksum += controller.visibleItemIDs.count + controller.selectedItems.count }
        }
        for _ in 0..<3 { oldRender(); cachedRender() }
        var before: [Double] = [], after: [Double] = []
        for _ in 0..<30 {
            before.append(duration(oldRender)); after.append(duration(cachedRender))
        }
        func summary(_ values: [Double]) -> [String: Double] {
            let sorted = values.sorted()
            return ["medianMilliseconds": sorted[sorted.count / 2], "p95Milliseconds": sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1]]
        }
        XCTAssertGreaterThan(checksum, 0)
        XCTAssertEqual(controller.listingProjectionBuildCount, 1)
        let report: [String: Any] = ["testHostResourceUsage": MacPerformanceResourceMetrics.cumulativeTestHostSnapshot(),
                                   "scenario": "100 repeated SFTP body projections", "files": all.count,
                                   "warmups": 3, "iterations": 30, "before": summary(before), "after": summary(after),
                                   "notes": "Exact prior map/filter path versus retained indexes; excludes SwiftUI layout, AppKit drawing and UI automation."]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: "/tmp/serverdash-sftp-performance-benchmark.json"), options: .atomic)
        print("SFTP_PERFORMANCE \(String(decoding: data, as: UTF8.self))")
        controller.close()
    }
}
#endif
