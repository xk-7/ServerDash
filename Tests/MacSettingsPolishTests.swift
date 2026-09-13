import XCTest
@testable import ServerDash

final class MacSettingsPolishTests: XCTestCase {
    func testTimeoutOnlyAcceptsEffectiveIntegerRange() {
        for value in ["", "0", "1", "4", "301", "999", "NaN", "15.5", "1e2", "-8", "１２"] {
            XCTAssertNil(MacSettingsValidation.timeout(value), value)
        }
        XCTAssertEqual(MacSettingsValidation.timeout("5"), 5)
        XCTAssertEqual(MacSettingsValidation.timeout(" 30 "), 30)
        XCTAssertEqual(MacSettingsValidation.timeout("300"), 300)
    }
    func testVersionComesFromBundleMetadata() {
        XCTAssertEqual(MacSettingsValidation.versionLabel(info: ["CFBundleShortVersionString": "2.4", "CFBundleVersion": "19"]), "2.4（19）")
        XCTAssertEqual(MacSettingsValidation.versionLabel(info: [:]), "—")
    }
    func testTimeoutDisplayMatchesTheEffectiveValueBeforeSubmission() {
        XCTAssertEqual(MacSettingsValidation.timeoutText(8), "8")
        XCTAssertEqual(MacSettingsValidation.timeoutText(8.5), "8.5")
    }
    func testSettingsCategoriesHaveStableStoredIDs() {
        XCTAssertEqual(SettingsPage(rawValue: "files"), .files)
        XCTAssertNil(SettingsPage(rawValue: "removed-page"))
    }

    func testServerLocationLookupRequiresPositiveOptIn() throws {
        let suite = "ServerDash.LocationPrivacy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(false, forKey: "disableLocationLookup")
        PrivacySettings.migrateLocationLookupPreference(in: defaults)
        XCTAssertFalse(PrivacySettings.locationLookupEnabled(in: defaults))
        XCTAssertEqual(defaults.object(forKey: "disableLocationLookup") as? Bool, true)

        PrivacySettings.setLocationLookupEnabled(true, in: defaults)
        XCTAssertTrue(PrivacySettings.locationLookupEnabled(in: defaults))
        XCTAssertEqual(defaults.object(forKey: "disableLocationLookup") as? Bool, false)

        PrivacySettings.setLocationLookupEnabled(false, in: defaults)
        XCTAssertFalse(PrivacySettings.locationLookupEnabled(in: defaults))
        XCTAssertEqual(defaults.object(forKey: "disableLocationLookup") as? Bool, true)
    }
}
