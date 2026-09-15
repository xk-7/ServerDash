import XCTest
@testable import ServerDash

final class MacUIFixtureConfigurationTests: XCTestCase {
    func testEveryDocumentedPageRouteParses() {
        for page in MacUIFixturePage.allCases {
            let configuration = MacUIFixture.configuration(arguments: [
                "ServerDash Mac QA", "--fixture-page", page.rawValue
            ])
            XCTAssertEqual(configuration.page, page)
        }
    }

    func testConfigurationParsesThemeSizeCountsAndAccessibility() {
        let configuration = MacUIFixture.configuration(arguments: [
            "ServerDash Mac QA",
            "--fixture-page", "terminal",
            "--fixture-theme", "dark",
            "--fixture-width", "1920",
            "--fixture-height", "1080",
            "--fixture-hosts", "1000",
            "--fixture-panes", "16",
            "--fixture-reduce-motion",
            "--fixture-reduce-transparency",
            "--fixture-increase-contrast"
        ])

        XCTAssertEqual(configuration.page, .terminal)
        XCTAssertEqual(configuration.theme, .dark)
        XCTAssertEqual(configuration.width, 1920)
        XCTAssertEqual(configuration.height, 1080)
        XCTAssertEqual(configuration.hostCount, 1000)
        XCTAssertEqual(configuration.paneCount, 16)
        XCTAssertEqual(
            configuration.accessibility,
            MacUIFixtureAccessibility(
                reduceMotion: true,
                reduceTransparency: true,
                increaseContrast: true
            )
        )
    }

    func testUnsafeOrUnsupportedArgumentsFallBackToBoundedDefaults() {
        let configuration = MacUIFixture.configuration(arguments: [
            "ServerDash Mac QA",
            "--fixture-page", "unknown",
            "--fixture-theme", "neon",
            "--fixture-width", "200",
            "--fixture-height", "99999",
            "--fixture-hosts", "50000",
            "--fixture-panes", "0"
        ])

        XCTAssertEqual(configuration.page, .dashboard)
        XCTAssertEqual(configuration.theme, .system)
        XCTAssertEqual(configuration.width, 900)
        XCTAssertEqual(configuration.height, 2160)
        XCTAssertEqual(configuration.hostCount, 1000)
        XCTAssertEqual(configuration.paneCount, 1)
    }

    func testEmptyPageAlwaysSuppressesSyntheticHosts() {
        let configuration = MacUIFixture.configuration(arguments: [
            "ServerDash Mac QA", "--fixture-page", "empty", "--fixture-hosts", "1000"
        ])
        XCTAssertEqual(configuration.page, .empty)
        XCTAssertEqual(configuration.hostCount, 0)
    }

    func testIsolationPolicySelectsOfflineTransportAndEphemeralCredentials() {
        XCTAssertFalse(MacUIFixtureIsolationPolicy.blocksNetwork(fixtureEnabled: false))
        XCTAssertTrue(MacUIFixtureIsolationPolicy.blocksNetwork(fixtureEnabled: true))
        XCTAssertEqual(
            MacUIFixtureIsolationPolicy.credentialBackend(fixtureEnabled: false),
            .systemKeychain
        )
        XCTAssertEqual(
            MacUIFixtureIsolationPolicy.credentialBackend(fixtureEnabled: true),
            .processMemory
        )
        XCTAssertNoThrow(
            try MacUIFixtureIsolationPolicy.requireNetworkAllowed(fixtureEnabled: false)
        )
        XCTAssertThrowsError(
            try MacUIFixtureIsolationPolicy.requireNetworkAllowed(fixtureEnabled: true)
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                MacUIFixtureIsolationPolicy.networkDisabledMessage
            )
        }
    }

    func testProductionTargetCannotEnableFixtureFromLaunchArguments() {
        #if SERVERDASH_MAC_QA
        XCTFail("ServerDashTests must exercise the production target without SERVERDASH_MAC_QA")
        #else
        XCTAssertFalse(MacUIFixture.isEnabled)
        #endif
    }
}
