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
}
