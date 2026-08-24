import XCTest
@testable import ServerDash

@MainActor
final class MonitorLayoutStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: MonitorLayoutStore!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "MonitorLayoutStoreTests")
        defaults.removePersistentDomain(forName: "MonitorLayoutStoreTests")
        store = MonitorLayoutStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "MonitorLayoutStoreTests")
        defaults = nil
        store = nil
        super.tearDown()
    }

    func testPersistsOrderAndVisibilityPerServer() {
        let serverID = UUID()
        let order: [MonitorCardKind] = [.memory, .cpu, .network, .load]

        store.setOrder(order, for: serverID)
        store.setHidden(true, card: .load, for: serverID)

        XCTAssertEqual(Array(store.orderedCards(for: serverID).prefix(4)), order)
        XCTAssertTrue(store.isHidden(.load, for: serverID))
        XCTAssertFalse(store.isHidden(.cpu, for: serverID))
    }

    func testAutomaticallyHidesUnavailableCapabilityCards() {
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
        let cards = store.visibleCards(
            for: UUID(),
            snapshot: .empty,
            hideIPInformation: true
        )

        XCTAssertFalse(cards.contains(.location))
    }

    func testResetRestoresDefaults() {
        let serverID = UUID()
        store.setHidden(true, card: .cpu, for: serverID)
        store.setOrder([.docker, .gpu], for: serverID)

        store.reset(serverID: serverID)

        XCTAssertEqual(store.orderedCards(for: serverID), MonitorCardKind.defaultOrder)
        XCTAssertFalse(store.isHidden(.cpu, for: serverID))
    }
}
