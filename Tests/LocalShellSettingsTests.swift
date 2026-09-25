import Foundation
import XCTest
@testable import ServerDash

final class LocalShellSettingsTests: XCTestCase {
    func testInvalidShellNeverReplacesEffectiveConfigurationAndCancelReloadsIt() throws {
        let suite = "com.serverdash.tests.localShell.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/bin/zsh", forKey: "workbench.localShellPath")
        defaults.set("inherit", forKey: "workbench.localShellEnvironment")

        let invalid = LocalShellSettingsDraft(path: "relative/shell", environment: "clean")
        XCTAssertNil(invalid.commit(defaults: defaults))
        XCTAssertEqual(defaults.string(forKey: "workbench.localShellPath"), "/bin/zsh")
        XCTAssertEqual(defaults.string(forKey: "workbench.localShellEnvironment"), "inherit")
        XCTAssertEqual(LocalShellSettingsDraft.load(defaults: defaults),
                       LocalShellSettingsDraft(path: "/bin/zsh", environment: "inherit"))
    }

    func testOnlyAbsoluteExecutableFilesOrEmptyLoginShellCanBeSaved() throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let executable = fixtureDirectory.appendingPathComponent("脚本 shell.sh")
        let nonExecutable = fixtureDirectory.appendingPathComponent("plain.sh")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 0\n".write(to: nonExecutable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: nonExecutable.path)

        for invalid in ["relative/shell", fixtureDirectory.path, nonExecutable.path, "~/bin/sh", "/missing/shell", "\0"] {
            XCTAssertNil(MacSettingsValidation.localShellPath(invalid), invalid)
        }
        XCTAssertEqual(MacSettingsValidation.localShellPath("  \n "), "")
        XCTAssertEqual(MacSettingsValidation.localShellPath(" \(executable.path)\n"), executable.path)
    }

    func testSuccessfulCommitNormalizesPathAndEnvironmentAndEmptyPathRestoresLoginShell() throws {
        let suite = "com.serverdash.tests.localShell.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Could not create isolated settings suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let executable = "/bin/sh"
        XCTAssertNotNil(MacSettingsValidation.localShellPath(executable))

        let saved = LocalShellSettingsDraft(path: " \(executable) ", environment: "clean").commit(defaults: defaults)
        XCTAssertEqual(saved, LocalShellSettingsDraft(path: executable, environment: "clean"))
        XCTAssertEqual(LocalShellSettingsDraft.load(defaults: defaults), saved)
        XCTAssertEqual(LocalShellConfiguration.current(defaults: defaults).executable, executable)

        let loginShell = LocalShellSettingsDraft(path: "  ", environment: "inherit").commit(defaults: defaults)
        XCTAssertEqual(loginShell, LocalShellSettingsDraft(path: "", environment: "inherit"))
        XCTAssertEqual(defaults.string(forKey: "workbench.localShellPath"), "")
        XCTAssertFalse(LocalShellConfiguration.current(defaults: defaults).executable.isEmpty)
    }

    func testInvalidEnvironmentCannotCommitAndUnknownStoredEnvironmentLoadsAsInherited() throws {
        let suite = "com.serverdash.tests.localShell.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Could not create isolated settings suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("unknown", forKey: "workbench.localShellEnvironment")
        XCTAssertEqual(LocalShellSettingsDraft.load(defaults: defaults).environment, "inherit")
        XCTAssertNil(LocalShellSettingsDraft(path: "", environment: "unknown").commit(defaults: defaults))
        XCTAssertEqual(defaults.string(forKey: "workbench.localShellEnvironment"), "unknown")
    }

}
