import SwiftData
import XCTest
import ZIPFoundation
#if os(macOS)
@testable import ServerDash
#else
@testable import ServerDashMobile
#endif

final class SessionTransferAdapterTests: XCTestCase {
    func testXShellSanitizedFixtureMapsCoreFieldsAndIgnoresEncryptedPassword() throws {
        let fixture = """
        [CONNECTION]
        Host=prod.example.com
        Port=22022
        Protocol=SSH

        [CONNECTION:AUTHENTICATION]
        UserName=deploy
        Method=PublicKey,Password
        UserKey=/Users/example/.ssh/id_ed25519
        PasswordV2=encrypted-value

        [SESSION_INFO]
        Name=生产网关
        """

        let inspection = try XShellSessionAdapter().inspect([
            .init(path: "XShell/生产环境/生产网关.xsh", data: Data(fixture.utf8))
        ])
        let candidate = try XCTUnwrap(inspection.candidates.first)

        XCTAssertEqual(inspection.candidates.count, 1)
        XCTAssertEqual(candidate.record.name, "生产网关")
        XCTAssertEqual(candidate.record.group, "生产环境")
        XCTAssertEqual(candidate.record.host, "prod.example.com")
        XCTAssertEqual(candidate.record.port, 22_022)
        XCTAssertEqual(candidate.record.username, "deploy")
        XCTAssertEqual(candidate.record.authentication, .keyThenPassword)
        XCTAssertEqual(candidate.record.externalPrivateKeyPath, "/Users/example/.ssh/id_ed25519")
        XCTAssertFalse(candidate.hasPlaintextPassword)
        XCTAssertTrue(candidate.warnings.contains { $0.contains("加密密码") })
    }

    func testSecureCRTINISanitizedFixtureParsesHexPortAndChinesePath() throws {
        let fixture = """
        S:"Hostname"=db.internal.example
        D:"[SSH2] Port"=000056CE
        S:"Username"=数据库用户
        S:"Protocol Name"=SSH2
        S:"Identity Filename V2"=/Users/example/.ssh/db_key
        """

        let inspection = try SecureCRTSessionAdapter().inspect([
            .init(path: "Config/Sessions/数据库/主库.ini", data: Data(fixture.utf8))
        ])
        let candidate = try XCTUnwrap(inspection.candidates.first)

        XCTAssertEqual(candidate.record.name, "主库")
        XCTAssertEqual(candidate.record.group, "数据库")
        XCTAssertEqual(candidate.record.host, "db.internal.example")
        XCTAssertEqual(candidate.record.port, 22_222)
        XCTAssertEqual(candidate.record.username, "数据库用户")
        XCTAssertEqual(candidate.record.authentication, .privateKey)
        XCTAssertTrue(candidate.isValid)
    }

    func testSecureCRTXMLCompatibilityRendererRoundTripsOneSessionWithoutDuplicate() throws {
        let adapter = SecureCRTSessionAdapter()
        let artifact = try adapter.render([sampleRecord], options: fixedOptions)
        let inspection = try adapter.inspect([
            .init(path: "SecureCRT.xml", data: artifact.data)
        ])
        let candidate = try XCTUnwrap(inspection.candidates.first)

        XCTAssertEqual(inspection.candidates.count, 1)
        XCTAssertEqual(candidate.record.name, sampleRecord.name)
        XCTAssertEqual(candidate.record.host, sampleRecord.host)
        XCTAssertEqual(candidate.record.port, sampleRecord.port)
        XCTAssertEqual(candidate.record.username, sampleRecord.username)
    }

    func testSecureCRTTextWizardAcceptsSemicolonDelimiterAndPlaintextPassword() throws {
        let fixture = """
        Hostname;Folder;Session Name;Username;Password;Protocol;Description
        secure.example.com;生产;Secure 主机;operator;temporary-secret;SSH2;脱敏样本
        """
        let inspection = try SecureCRTSessionAdapter().inspect([
            .init(path: "securecrt.csv", data: Data(fixture.utf8))
        ])
        let candidate = try XCTUnwrap(inspection.candidates.first)

        XCTAssertEqual(candidate.record.name, "Secure 主机")
        XCTAssertEqual(candidate.record.group, "生产")
        XCTAssertEqual(candidate.record.host, "secure.example.com")
        XCTAssertEqual(candidate.record.username, "operator")
        XCTAssertTrue(candidate.hasPlaintextPassword)
    }

    func testMobaXtermSanitizedFixtureMapsBookmark() throws {
        let fixture = """
        [MobaXterm sessions]
        ImgNum=42

        [Bookmarks]
        SubRep=生产环境
        ImgNum=42
        API 网关=#109#0%api.example.com%2022%deployer%%-1%-1%%%%%0%0%0%%%-1%0%0%0%%1080%%0%0%1#
        """

        let inspection = try MobaXtermSessionAdapter().inspect([
            .init(path: "sessions.mxtsessions", data: Data(fixture.utf8))
        ])
        let candidate = try XCTUnwrap(inspection.candidates.first)

        XCTAssertEqual(candidate.record.name, "API 网关")
        XCTAssertEqual(candidate.record.group, "生产环境")
        XCTAssertEqual(candidate.record.host, "api.example.com")
        XCTAssertEqual(candidate.record.port, 2_022)
        XCTAssertEqual(candidate.record.username, "deployer")
    }

    func testMobaXtermNonSSHBookmarkIsReportedAsSkipped() async throws {
        let fixture = """
        [Bookmarks]
        SubRep=桌面
        Windows RDP=#91#0%rdp.example.com%3389%administrator#
        """

        let preview = try await SessionMigrationService().preview(
            source: .mobaXterm,
            input: .files([.init(path: "sessions.mxtsessions", data: Data(fixture.utf8))]),
            existing: []
        )

        XCTAssertTrue(preview.candidates.isEmpty)
        XCTAssertTrue(preview.warnings.contains { $0.contains("非 SSH/SFTP") })
    }

    func testFinalShellSanitizedFixtureMapsCoreFieldsButNeverDecryptsPassword() throws {
        let fixture = """
        {
          "name": "边缘节点",
          "host": "edge.example.com",
          "port": 10022,
          "user_name": "ops",
          "authentication_type": 0,
          "password": "ENC:not-plaintext",
          "remark": "脱敏样本"
        }
        """

        let inspection = try FinalShellSessionAdapter().inspect([
            .init(path: "conn/edge.json", data: Data(fixture.utf8))
        ])
        let candidate = try XCTUnwrap(inspection.candidates.first)

        XCTAssertEqual(candidate.record.name, "边缘节点")
        XCTAssertEqual(candidate.record.host, "edge.example.com")
        XCTAssertEqual(candidate.record.port, 10_022)
        XCTAssertEqual(candidate.record.username, "ops")
        XCTAssertEqual(candidate.record.authentication, .password)
        XCTAssertFalse(candidate.hasPlaintextPassword)
        XCTAssertTrue(candidate.warnings.contains { $0.contains("不会被解密") })
    }

    func testXTerminalJSONKeepsPlaintextPasswordOnlyInEphemeralCredential() throws {
        let secret = "correct-but-temporary-password"
        let fixture = """
        [{
          "title": "测试机",
          "folder": "开发",
          "host": "test.example.com",
          "port": 3022,
          "username": "tester",
          "auth": "password",
          "password": "\(secret)"
        }]
        """

        let inspection = try XTerminalSessionAdapter().inspect([
            .init(path: "xterminal.json", data: Data(fixture.utf8))
        ])
        let candidate = try XCTUnwrap(inspection.candidates.first)
        let encodedRecord = try JSONEncoder().encode(candidate.record)

        XCTAssertTrue(candidate.hasPlaintextPassword)
        XCTAssertEqual(candidate.credential?.password(), secret)
        XCTAssertEqual(candidate.record.authentication, .password)
        XCTAssertNil(String(data: encodedRecord, encoding: .utf8)?.range(of: secret))
    }

    func testXTerminalOfficialTextFormatsParseEndpointQuotesAndComments() throws {
        let fixture = """
        # comment
        user@10.0.0.3:2222 |  | temporary | 测试机 | 临时环境
        host=key.example.com user=deploy port=3022 auth=privateKey privateKey="/Users/me/.ssh/prod key" title="Key Login" passphrase=ignored
        """
        let inspection = try XTerminalSessionAdapter().inspect([
            .init(path: "xterminal.txt", data: Data(fixture.utf8))
        ])

        XCTAssertEqual(inspection.candidates.count, 2)
        XCTAssertEqual(inspection.candidates[0].record.host, "10.0.0.3")
        XCTAssertEqual(inspection.candidates[0].record.port, 2_222)
        XCTAssertEqual(inspection.candidates[0].record.username, "user")
        XCTAssertEqual(inspection.candidates[0].record.name, "测试机")
        XCTAssertTrue(inspection.candidates[0].hasPlaintextPassword)
        XCTAssertEqual(inspection.candidates[1].record.externalPrivateKeyPath, "/Users/me/.ssh/prod key")
        XCTAssertEqual(inspection.candidates[1].record.name, "Key Login")
        XCTAssertTrue(inspection.candidates[1].warnings.contains { $0.contains("私钥口令") })
    }

    func testPuTTYUTF16RegistryFixtureParsesNonDefaultPortAndUnicodeName() throws {
        let text = """
        Windows Registry Editor Version 5.00

        [HKEY_CURRENT_USER\\Software\\SimonTatham\\PuTTY\\Sessions\\%E4%B8%AD%E6%96%87%E4%B8%BB%E6%9C%BA]
        "HostName"="putty.example.com"
        "PortNumber"=dword:000061A8
        "UserName"="putty-user"
        "Protocol"="ssh"
        """
        var data = Data([0xFF, 0xFE])
        data.append(try XCTUnwrap(text.data(using: .utf16LittleEndian)))

        let inspection = try PuTTYSessionAdapter().inspect([
            .init(path: "putty.reg", data: data)
        ])
        let candidate = try XCTUnwrap(inspection.candidates.first)

        XCTAssertEqual(candidate.record.name, "中文主机")
        XCTAssertEqual(candidate.record.host, "putty.example.com")
        XCTAssertEqual(candidate.record.port, 25_000)
        XCTAssertEqual(candidate.record.username, "putty-user")
    }

    func testUTF16WithoutBOMIsDetectedBeforeUTF8Fallback() throws {
        let value = "HostName=utf16.example.com\nPortNumber=2222\nUserName=测试用户\n"
        let data = try XCTUnwrap(value.data(using: .utf16LittleEndian))

        XCTAssertEqual(SessionTextDecoder.decode(data), value)
    }

    func testWindows1252IsNotMisdetectedAsUTF16() throws {
        let data = Data([0x4E, 0x61, 0x6D, 0x65, 0x3D, 0x43, 0x61, 0x66, 0xE9])
        XCTAssertEqual(SessionTextDecoder.decode(data), "Name=Café")
    }

    func testOpenSSHConfigImportsConcreteHostsAndReportsSkippedFeatures() throws {
        let fixture = """
        Include conf.d/*.conf
        Host *.wildcard
            User ignored
        Host gateway gateway-alias
            HostName gateway.example.com
            Port 6022
            User deploy
            IdentityFile "~/.ssh/prod key"
            ProxyJump bastion
            LocalForward 8080 localhost:80
        """

        let inspection = try OpenSSHSessionAdapter().inspect([
            .init(path: ".ssh/config", data: Data(fixture.utf8))
        ])

        XCTAssertEqual(inspection.candidates.count, 2)
        XCTAssertEqual(Set(inspection.candidates.map(\.record.name)), ["gateway", "gateway-alias"])
        XCTAssertTrue(inspection.candidates.allSatisfy { $0.record.port == 6_022 })
        XCTAssertTrue(inspection.candidates.allSatisfy { $0.warnings.contains(where: { $0.contains("跳板机") }) })
        XCTAssertTrue(inspection.warnings.contains { $0.contains("Include") })
    }

    func testOpenSSHMatchBlockDoesNotMutatePreviousHost() throws {
        let fixture = """
        Host first
            HostName first.example.com
            User deploy
        Match host first
            User should-not-apply
        Host second
            HostName second.example.com
            User operator
        """

        let inspection = try OpenSSHSessionAdapter().inspect([
            .init(path: "config", data: Data(fixture.utf8))
        ])

        XCTAssertEqual(inspection.candidates.count, 2)
        XCTAssertEqual(inspection.candidates[0].record.username, "deploy")
        XCTAssertEqual(inspection.candidates[1].record.username, "operator")
        XCTAssertTrue(inspection.warnings.contains { $0.contains("Match") })
    }

    func testInvalidExplicitPortIsReportedInsteadOfSilentlyBecoming22() throws {
        let fixture = "host=bad.example.com port=not-a-number username=root"
        let inspection = try XTerminalSessionAdapter().inspect([
            .init(path: "invalid.txt", data: Data(fixture.utf8))
        ])
        let candidate = try XCTUnwrap(inspection.candidates.first)

        XCTAssertFalse(candidate.isValid)
        XCTAssertTrue(candidate.errors.contains { $0.contains("not-a-number") })
    }

    func testXTerminalOfficialTextAllowsHostOnlyEntry() throws {
        let inspection = try XTerminalSessionAdapter().inspect([
            .init(path: "minimal.txt", data: Data("host=minimal.example.com".utf8))
        ])

        let candidate = try XCTUnwrap(inspection.candidates.first)
        XCTAssertEqual(candidate.record.host, "minimal.example.com")
        XCTAssertEqual(candidate.record.port, 22)
        XCTAssertFalse(candidate.isValid)
        XCTAssertTrue(candidate.errors.contains { $0.contains("用户名") })
    }

    func testStableExportersNeverContainPasswordOrPrivateKeyBody() async throws {
        var unsafe = sampleRecord
        unsafe.authentication = .keyThenPassword
        unsafe.externalPrivateKeyPath = "-----BEGIN OPENSSH PRIVATE KEY-----\nprivate-material\n-----END OPENSSH PRIVATE KEY-----"
        let service = SessionMigrationService()

        for target in SessionTransferTarget.allCases where target.exportAvailability == .available {
            let artifact = try await service.export(records: [unsafe], target: target, options: fixedOptions)
            XCTAssertNil(artifact.data.range(of: Data("private-material".utf8)), "Leaked key body for \(target)")
            XCTAssertNil(artifact.data.range(of: Data("correct-but-temporary-password".utf8)))
            XCTAssertTrue(artifact.warnings.contains { $0.contains("私钥正文") })
        }
    }

    func testServerDashVersionedJSONRoundTripsAllCoreFields() throws {
        let adapter = ServerDashSessionAdapter()
        let artifact = try adapter.render([sampleRecord], options: fixedOptions)
        let inspection = try adapter.inspect([
            .init(path: "ServerDash-Sessions.json", data: artifact.data)
        ])

        XCTAssertEqual(inspection.candidates.map(\.record), [sampleRecord])
        let json = try XCTUnwrap(String(data: artifact.data, encoding: .utf8))
        XCTAssertTrue(json.contains("com.serverdash.sessions"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(json.contains("privateKeyText"))
    }

    func testServerDashImportStripsPrivateKeyBodyDisguisedAsPath() throws {
        var unsafe = sampleRecord
        unsafe.externalPrivateKeyPath = "-----BEGIN OPENSSH PRIVATE KEY-----\nprivate-material"
        let document = ServerDashSessionDocument(
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            generator: .init(version: "fixture"),
            sessions: [unsafe]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let inspection = try ServerDashSessionAdapter().inspect([
            .init(path: "ServerDash-Sessions.json", data: try encoder.encode(document))
        ])
        let candidate = try XCTUnwrap(inspection.candidates.first)

        XCTAssertNil(candidate.record.externalPrivateKeyPath)
        XCTAssertTrue(candidate.warnings.contains { $0.contains("私钥正文") })
    }

    func testXShellZipExportCanBeSafelyExpandedAndReimported() throws {
        let adapter = XShellSessionAdapter()
        let artifact = try adapter.render([sampleRecord], options: fixedOptions)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("zip")
        try artifact.data.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let files = try SessionImportFileLoader.load(.urls([url]))
        let inspection = try adapter.inspect(files)

        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(inspection.candidates.first?.record.host, sampleRecord.host)
        XCTAssertEqual(inspection.candidates.first?.record.port, sampleRecord.port)
    }

    func testStableNativeFormatsRoundTripCoreConnectionFields() throws {
        let checks: [(SessionTransferTarget, any SessionImportAdapter, any SessionExportAdapter)] = [
            (.mobaXterm, MobaXtermSessionAdapter(), MobaXtermSessionAdapter()),
            (.xTerminal, XTerminalSessionAdapter(), XTerminalSessionAdapter()),
            (.putty, PuTTYSessionAdapter(), PuTTYSessionAdapter()),
            (.openSSH, OpenSSHSessionAdapter(), OpenSSHSessionAdapter())
        ]

        for (target, importer, exporter) in checks {
            let artifact = try exporter.render([sampleRecord], options: fixedOptions)
            let file = SessionSourceFile(path: artifact.suggestedFileName, data: artifact.data)
            let inspection = try importer.inspect([file])
            let candidate = try XCTUnwrap(inspection.candidates.first, "No round-trip candidate for \(target)")
            XCTAssertEqual(candidate.record.host, sampleRecord.host, "Host mismatch for \(target)")
            XCTAssertEqual(candidate.record.port, sampleRecord.port, "Port mismatch for \(target)")
            XCTAssertEqual(candidate.record.username, sampleRecord.username, "User mismatch for \(target)")
        }
    }

    func testAutomaticDetectionSeparatesXTerminalFromFinalShell() async throws {
        let xTerminal = SessionSourceFile(
            path: "xterminal.json",
            data: Data(#"[{"title":"XT","host":"xt.example.com","port":2022,"username":"xt","auth":"password"}]"#.utf8)
        )
        let finalShell = SessionSourceFile(
            path: "conn/final.json",
            data: Data(#"{"name":"FS","host":"fs.example.com","port":3022,"user_name":"fs","authentication_type":0}"#.utf8)
        )

        let preview = try await SessionMigrationService().preview(
            source: .automatic,
            input: .files([xTerminal, finalShell]),
            existing: []
        )

        XCTAssertEqual(Set(preview.detectedSources), [.xTerminal, .finalShell])
        XCTAssertEqual(Set(preview.candidates.map(\.source)), [.xTerminal, .finalShell])
    }

    func testAutomaticDetectionPreviewsUnknownFilesWithReason() async throws {
        let preview = try await SessionMigrationService().preview(
            source: .automatic,
            input: .files([.init(path: "unknown.bin", data: Data([0x00, 0x01, 0x02]))]),
            existing: []
        )

        XCTAssertTrue(preview.candidates.isEmpty)
        XCTAssertTrue(preview.warnings.contains { $0.contains("无法识别") })
    }

    func testMalformedJSONINIAndRegistryNeverEchoCredentialValues() async throws {
        let secret = "credential-must-stay-hidden"
        let malformedJSON = SessionSourceFile(
            path: "conn/broken.json",
            data: Data("{\"host\":\"broken.example.com\",\"password\":\"\(secret)\"".utf8)
        )
        do {
            _ = try await SessionMigrationService().preview(
                source: .finalShell,
                input: .files([malformedJSON]),
                existing: []
            )
            XCTFail("Expected malformed JSON to be rejected")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains(secret))
        }

        let malformedINI = """
        [CONNECTION]
        Host=ini.example.com
        Port=not-a-port
        [CONNECTION:AUTHENTICATION]
        PasswordV2=\(secret)
        """
        let iniInspection = try XShellSessionAdapter().inspect([
            .init(path: "broken.xsh", data: Data(malformedINI.utf8))
        ])

        let malformedRegistry = """
        Windows Registry Editor Version 5.00
        [HKEY_CURRENT_USER\\Software\\SimonTatham\\PuTTY\\Sessions\\Broken]
        "HostName"="reg.example.com"
        "PortNumber"="not-a-port"
        "UserName"="operator"
        "Password"="\(secret)"
        """
        var registryData = Data([0xFF, 0xFE])
        registryData.append(try XCTUnwrap(malformedRegistry.data(using: .utf16LittleEndian)))
        let registryInspection = try PuTTYSessionAdapter().inspect([
            .init(path: "broken.reg", data: registryData)
        ])

        let candidates = iniInspection.candidates + registryInspection.candidates
        XCTAssertEqual(candidates.count, 2)
        XCTAssertTrue(candidates.allSatisfy { !$0.isValid })
        XCTAssertTrue(candidates.allSatisfy { !$0.hasPlaintextPassword })
        let visibleMessages = candidates.flatMap { $0.warnings + $0.errors }.joined(separator: "\n")
        XCTAssertFalse(visibleMessages.contains(secret))
    }

    func testDuplicateKeyNormalizesHostCaseDotsAndWhitespace() async throws {
        let input = SessionSourceFile(
            path: "hosts.txt",
            data: Data("EXAMPLE.com. | deploy | pw | First\nexample.com | deploy | pw | Second".utf8)
        )
        let preview = try await SessionMigrationService().preview(
            source: .xTerminal,
            input: .files([input]),
            existing: []
        )

        XCTAssertFalse(preview.candidates[0].isDuplicate)
        XCTAssertTrue(preview.candidates[1].isDuplicate)
    }

    func testUnsupportedNativeExportsRemainGated() async throws {
        let service = SessionMigrationService()
        for target in [SessionTransferTarget.secureCRT, .finalShell] {
            do {
                _ = try await service.export(records: [sampleRecord], target: target, options: fixedOptions)
                XCTFail("Expected \(target) to remain gated")
            } catch let error as SessionMigrationError {
                guard case .exportRequiresValidation = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
    }

    private var sampleRecord: SessionTransferRecord {
        SessionTransferRecord(
            name: "Production Gateway",
            group: "Production",
            host: "gateway.example.com",
            port: 22_222,
            username: "deploy",
            authentication: .privateKey,
            externalPrivateKeyPath: "/Users/example/.ssh/id_ed25519",
            notes: "Primary gateway",
            tags: ["production", "edge"],
            defaultRemotePath: "/srv/app"
        )
    }

    private var fixedOptions: SessionExportOptions {
        SessionExportOptions(
            appVersion: "1.0.0-test",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}

final class SessionTransferSafetyTests: XCTestCase {
    func testRejectsTraversalAbsoluteWindowsAndExcessivelyDeepArchivePaths() {
        for path in ["../secret", "/absolute/file", "C:\\secret", String(repeating: "a/", count: 33) + "file"] {
            XCTAssertThrowsError(try SessionImportFileLoader.validateArchivePath(path), "Accepted \(path)")
        }
    }

    func testRejectsOversizedInMemoryInput() {
        let data = Data(count: SessionImportFileLoader.maxFileBytes + 1)
        XCTAssertThrowsError(try SessionImportFileLoader.load(.files([
            .init(path: "oversized.json", data: data)
        ]))) { error in
            XCTAssertEqual(error as? SessionMigrationError, .fileTooLarge("oversized.json"))
        }
    }

    func testRejectsMoreThanTenThousandInMemoryItems() {
        let files = (0...SessionImportFileLoader.maxArchiveEntries).map {
            SessionSourceFile(path: "\($0).txt", data: Data())
        }
        XCTAssertThrowsError(try SessionImportFileLoader.load(.files(files))) { error in
            XCTAssertEqual(error as? SessionMigrationError, .archiveEntryLimit)
        }
    }

    func testCancelledExportStopsBeforeRendering() async {
        let task = Task {
            await Task.yield()
            return try await SessionMigrationService().export(
                records: [SessionTransferRecord(name: "Host", host: "host.example.com", username: "user")],
                target: .serverDash
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCancelledPreviewStopsBeforeParsing() async {
        let task = Task {
            await Task.yield()
            return try await SessionMigrationService().preview(
                source: .xTerminal,
                input: .files([
                    .init(
                        path: "cancelled.txt",
                        data: Data("host=cancelled.example.com user=tester".utf8)
                    )
                ]),
                existing: []
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRejectsSymbolicLinkInput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let target = root.appendingPathComponent("target.xsh")
        let link = root.appendingPathComponent("link.xsh")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("Host=example.com".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(try SessionImportFileLoader.load(.urls([link]))) { error in
            XCTAssertEqual(error as? SessionMigrationError, .symbolicLink("link.xsh"))
        }
    }

    func testArchiveWriterRejectsTraversalBeforeCreatingFile() {
        XCTAssertThrowsError(try SessionArchiveWriter.makeArchive(entries: [
            (path: "../../escape.xsh", data: Data("content".utf8))
        ])) { error in
            XCTAssertEqual(error as? SessionMigrationError, .unsafeArchivePath("../../escape.xsh"))
        }
    }

    func testArchiveReaderRejectsTraversalEntry() throws {
        let url = try makeArchive(
            path: "../escape.xsh",
            type: .file,
            data: Data("Host=escape.example.com".utf8)
        )
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try SessionImportFileLoader.load(.urls([url]))) { error in
            XCTAssertEqual(error as? SessionMigrationError, .unsafeArchivePath("../escape.xsh"))
        }
    }

    func testArchiveReaderRejectsSymbolicLinkEntry() throws {
        let url = try makeArchive(
            path: "sessions/link.xsh",
            type: .symlink,
            data: Data("../target.xsh".utf8)
        )
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try SessionImportFileLoader.load(.urls([url]))) { error in
            XCTAssertEqual(error as? SessionMigrationError, .symbolicLink("sessions/link.xsh"))
        }
    }

    private func makeArchive(path: String, type: Entry.EntryType, data: Data) throws -> URL {
        let archive = try Archive(data: Data(), accessMode: .create)
        try archive.addEntry(
            with: path,
            type: type,
            uncompressedSize: Int64(data.count)
        ) { position, size in
            let start = Int(position)
            let end = min(data.count, start + size)
            return start < end ? data.subdata(in: start..<end) : Data()
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("zip")
        try XCTUnwrap(archive.data).write(to: url, options: .atomic)
        return url
    }
}

@MainActor
final class SessionImportCommitterTests: XCTestCase {
    func testPlaintextPasswordIsNotPersistedWithoutExplicitAuthorization() throws {
        let credential = EphemeralSessionCredential(password: "must-not-be-saved")
        let candidate = makeCandidate(credential: credential)
        let container = try PersistenceController.makeInMemoryContainer()
        let context = ModelContext(container)
        let preview = makePreview(candidate)

        let result = try SessionImportCommitter.commit(
            .init(preview: preview, selectedIDs: [candidate.id]),
            importPlaintextPasswords: false,
            existingServers: [],
            context: context
        )
        let server = try XCTUnwrap(context.fetch(FetchDescriptor<ServerRecord>()).first)
        defer { try? KeychainService.deletePassword(for: server.id) }

        XCTAssertEqual(result.passwordCount, 0)
        XCTAssertNil(try KeychainService.password(for: server.id))
        XCTAssertEqual(server.credentialReadiness, .needsConfiguration)
        XCTAssertNil(credential.password())
    }

    func testAuthorizedPlaintextPasswordMovesToKeychainAndClearsTemporaryValue() throws {
        let password = "authorized-password"
        let credential = EphemeralSessionCredential(password: password)
        let candidate = makeCandidate(credential: credential)
        let container = try PersistenceController.makeInMemoryContainer()
        let context = ModelContext(container)
        let preview = makePreview(candidate)

        let result = try SessionImportCommitter.commit(
            .init(preview: preview, selectedIDs: [candidate.id]),
            importPlaintextPasswords: true,
            existingServers: [],
            context: context
        )
        let server = try XCTUnwrap(context.fetch(FetchDescriptor<ServerRecord>()).first)
        defer { try? KeychainService.deletePassword(for: server.id) }

        XCTAssertEqual(result.passwordCount, 1)
        XCTAssertEqual(try KeychainService.password(for: server.id), password)
        XCTAssertEqual(server.credentialReadiness, .ready)
        XCTAssertNil(credential.password())
    }

    func testDuplicateOverrideImportsCopyWithNumberedName() throws {
        let existing = ServerRecord(name: "Production", host: "existing.example.com", username: "root")
        let candidate = SessionImportCandidate(
            record: .init(name: "Production", host: "new.example.com", username: "root", authentication: .password),
            source: .serverDash,
            sourcePath: "sessions.json",
            isDuplicate: true
        )
        let container = try PersistenceController.makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(existing)
        try context.save()
        let preview = makePreview(candidate)

        let result = try SessionImportCommitter.commit(
            .init(preview: preview, selectedIDs: [candidate.id], duplicateOverrideIDs: [candidate.id]),
            importPlaintextPasswords: false,
            existingServers: [existing],
            context: context
        )
        let names = try context.fetch(FetchDescriptor<ServerRecord>()).map(\.displayName)

        XCTAssertEqual(result.importedCount, 1)
        XCTAssertEqual(Set(names), ["Production", "Production (2)"])
    }

    func testExplicitIdentityMappingUsesExistingCredentialsWithoutOverwritingThem() throws {
        let identity = IdentityRecord(
            name: "Existing identity",
            username: "identity-user",
            authentication: .privateKey,
            sshKeyID: UUID()
        )
        let credential = EphemeralSessionCredential(password: "must-not-overwrite-identity")
        let candidate = makeCandidate(credential: credential)
        let container = try PersistenceController.makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(identity)
        try context.save()
        let preview = makePreview(candidate)

        let result = try SessionImportCommitter.commit(
            .init(
                preview: preview,
                selectedIDs: [candidate.id],
                identityMappingIDs: [candidate.id: identity.id]
            ),
            importPlaintextPasswords: true,
            existingServers: [],
            existingIdentities: [identity],
            context: context
        )
        let server = try XCTUnwrap(context.fetch(FetchDescriptor<ServerRecord>()).first)
        defer { try? KeychainService.deletePassword(for: server.id) }

        XCTAssertEqual(result.passwordCount, 0)
        XCTAssertEqual(server.identityID, identity.id)
        XCTAssertEqual(server.username, "identity-user")
        XCTAssertEqual(server.authentication, .privateKey)
        XCTAssertTrue(server.privateKeyPath.isEmpty)
        XCTAssertNil(try KeychainService.password(for: server.id))
        XCTAssertNil(credential.password())
    }

    func testCredentialFailureRollsBackHostsDeletesWrittenSecretsAndClearsTemporaryValues() throws {
        enum StubFailure: Error { case rejected }

        let firstCredential = EphemeralSessionCredential(password: "first-secret")
        let secondCredential = EphemeralSessionCredential(password: "second-secret")
        let first = makeCandidate(credential: firstCredential)
        let second = SessionImportCandidate(
            record: .init(
                name: "Imported 2",
                host: "import-2.example.com",
                port: 2_223,
                username: "tester",
                authentication: .password
            ),
            source: .xTerminal,
            sourcePath: "fixture-2.json",
            credential: secondCredential
        )
        let preview = SessionImportPreview(
            requestedSource: .xTerminal,
            detectedSources: [.xTerminal],
            candidates: [first, second],
            warnings: []
        )
        let container = try PersistenceController.makeInMemoryContainer()
        let context = ModelContext(container)
        var savedIDs: [UUID] = []
        var deletedIDs: [UUID] = []
        let store = SessionImportCredentialStore(
            savePassword: { _, id in
                guard !savedIDs.isEmpty else {
                    savedIDs.append(id)
                    return
                }
                throw StubFailure.rejected
            },
            deletePassword: { deletedIDs.append($0) }
        )

        XCTAssertThrowsError(try SessionImportCommitter.commit(
            .init(preview: preview, selectedIDs: [first.id, second.id]),
            importPlaintextPasswords: true,
            existingServers: [],
            credentialStore: store,
            context: context
        ))

        XCTAssertEqual(deletedIDs, savedIDs)
        XCTAssertTrue(try context.fetch(FetchDescriptor<ServerRecord>()).isEmpty)
        XCTAssertNil(firstCredential.password())
        XCTAssertNil(secondCredential.password())
    }

    func testCredentialCleanupFailureIsSurfacedAfterDatabaseRollback() throws {
        enum StubFailure: Error { case saveRejected, cleanupRejected }

        let first = makeCandidate(credential: EphemeralSessionCredential(password: "first"))
        let second = makeCandidate(credential: EphemeralSessionCredential(password: "second"))
        let preview = SessionImportPreview(
            requestedSource: .xTerminal,
            detectedSources: [.xTerminal],
            candidates: [first, second],
            warnings: []
        )
        let container = try PersistenceController.makeInMemoryContainer()
        let context = ModelContext(container)
        var saves = 0
        let store = SessionImportCredentialStore(
            savePassword: { _, _ in
                saves += 1
                if saves == 2 { throw StubFailure.saveRejected }
            },
            deletePassword: { _ in throw StubFailure.cleanupRejected }
        )

        XCTAssertThrowsError(try SessionImportCommitter.commit(
            .init(preview: preview, selectedIDs: [first.id, second.id]),
            importPlaintextPasswords: true,
            existingServers: [],
            credentialStore: store,
            context: context
        )) { error in
            XCTAssertEqual(error as? SessionMigrationError, .credentialCleanupFailed)
        }
        XCTAssertTrue(try context.fetch(FetchDescriptor<ServerRecord>()).isEmpty)
        XCTAssertNil(first.credential?.password())
        XCTAssertNil(second.credential?.password())
    }

    private func makeCandidate(credential: EphemeralSessionCredential?) -> SessionImportCandidate {
        SessionImportCandidate(
            record: .init(
                name: "Imported",
                group: "Tests",
                host: "import.example.com",
                port: 2_222,
                username: "tester",
                authentication: .password
            ),
            source: .xTerminal,
            sourcePath: "fixture.json",
            credential: credential
        )
    }

    private func makePreview(_ candidate: SessionImportCandidate) -> SessionImportPreview {
        SessionImportPreview(
            requestedSource: candidate.source,
            detectedSources: [candidate.source],
            candidates: [candidate],
            warnings: []
        )
    }
}
