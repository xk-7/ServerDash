import XCTest
@testable import ServerDash

@MainActor
final class MonitorLayoutStoreTests: XCTestCase {
    private func fixture() -> (UserDefaults, MonitorLayoutStore) {
        let suite = "MonitorLayoutStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
        }
        return (defaults, MonitorLayoutStore(defaults: defaults))
    }

    func testPersistsOrderAndVisibilityPerServer() {
        let (_, store) = fixture()
        let serverID = UUID()
        let order: [MonitorCardKind] = [.memory, .cpu, .network, .load]

        store.setOrder(order, for: serverID)
        store.setHidden(true, card: .load, for: serverID)

        XCTAssertEqual(Array(store.orderedCards(for: serverID).prefix(4)), order)
        XCTAssertTrue(store.isHidden(.load, for: serverID))
        XCTAssertFalse(store.isHidden(.cpu, for: serverID))
    }

    func testAutomaticallyHidesUnavailableCapabilityCards() {
        let (_, store) = fixture()
        let serverID = UUID()
        let cards = store.visibleCards(
            for: serverID,
            snapshot: .empty,
            hideIPInformation: false
        )

        XCTAssertFalse(cards.contains(.gpu))
        XCTAssertFalse(cards.contains(.docker))
        XCTAssertTrue(cards.contains(.cpu))
        XCTAssertTrue(cards.contains(.location))
    }

    func testHideIPPreferenceRemovesLocationCard() {
        let (_, store) = fixture()
        let cards = store.visibleCards(
            for: UUID(),
            snapshot: .empty,
            hideIPInformation: true
        )

        XCTAssertFalse(cards.contains(.location))
    }

    func testResetRestoresDefaults() {
        let (_, store) = fixture()
        let serverID = UUID()
        store.setHidden(true, card: .cpu, for: serverID)
        store.setOrder([.docker, .gpu], for: serverID)

        store.reset(serverID: serverID)

        XCTAssertEqual(store.orderedCards(for: serverID), MonitorCardKind.defaultOrder)
        XCTAssertFalse(store.isHidden(.cpu, for: serverID))
    }
}

@MainActor
final class EventLogStoreConcurrencyTests: XCTestCase {
    func testConcurrentBackgroundIngressIsBoundedAndRedacted() async throws {
        let store = EventLogStore.shared
        store.clear()
        defer { store.clear() }

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<320 {
                group.addTask {
                    EventLogStore.append(
                        serverID: nil,
                        module: .app,
                        message: "background event \(index)"
                    )
                }
            }
        }

        for _ in 0..<100 where store.events.count < 300 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(store.events.count, 300)

        EventLogStore.append(
            serverID: nil,
            module: .app,
            message: "privacy-marker token=do-not-store 192.0.2.1"
        )
        for _ in 0..<100 where !store.events.contains(where: { $0.message.contains("privacy-marker") }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        let event = try XCTUnwrap(store.events.last(where: { $0.message.contains("privacy-marker") }))
        XCTAssertFalse(event.message.contains("do-not-store"))
        XCTAssertFalse(event.message.contains("192.0.2.1"))
    }
}
