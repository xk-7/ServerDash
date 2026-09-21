import XCTest
@testable import ServerDash

private actor AsyncTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

final class MacSettingsPolishTests: XCTestCase {
    private enum FixturePersistenceError: Error { case failed }

    func testWorkspaceBreakpointsUseDetailWidthAndHeight() {
        XCTAssertEqual(MacWorkspaceMetrics(width: 759, height: 900).tier, .compact)
        XCTAssertEqual(MacWorkspaceMetrics(width: 760, height: 679).tier, .compact)
        XCTAssertEqual(MacWorkspaceMetrics(width: 760, height: 680).tier, .regular)
        XCTAssertEqual(MacWorkspaceMetrics(width: 1_199, height: 900).tier, .regular)
        XCTAssertEqual(MacWorkspaceMetrics(width: 1_200, height: 900).tier, .wide)
    }

    func testWorkspaceMetricsClampDimensionsAndExposeStableLayoutTokens() {
        let invalid = MacWorkspaceMetrics(width: -100, height: -20)
        XCTAssertEqual(invalid.width, 0)
        XCTAssertEqual(invalid.height, 0)
        XCTAssertTrue(invalid.isCompact)
        XCTAssertEqual(invalid.pagePadding, AppleDesign.Spacing.md)
        XCTAssertEqual(invalid.gridMinimumWidth, 244)

        let regular = MacWorkspaceMetrics(width: 900, height: 720)
        XCTAssertFalse(regular.isCompact)
        XCTAssertFalse(regular.isWide)
        XCTAssertEqual(regular.pagePadding, AppleDesign.Spacing.lg)
        XCTAssertEqual(regular.gridMinimumWidth, 280)
    }

    func testConnectionEditorReturnKeepsSaveAndConnectAsTheDefaultAction() {
        XCTAssertTrue(ConnectionEditorCommitIntent.defaultAction.connectsAfterSaving)
        XCTAssertFalse(ConnectionEditorCommitIntent.secondaryAction.connectsAfterSaving)
        XCTAssertEqual(ConnectionEditorCommitIntent.defaultAction, .saveAndConnect)
        XCTAssertEqual(ConnectionEditorCommitIntent.secondaryAction, .saveOnly)
    }

    func testSettingsContentWidthsSeparateSimpleAndComplexPages() {
        for page in [SettingsPage.general, .monitoring, .shortcuts, .security] {
            XCTAssertEqual(page.maximumContentWidth, 720)
        }
        for page in [SettingsPage.terminal, .files, .sync, .recording, .ai] {
            XCTAssertEqual(page.maximumContentWidth, 960)
        }
    }

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

    func testSSHKeyMetadataOnlyEditPreservesImportedMaterialAndPassphrase() throws {
        let keyID = UUID()
        let importedAccount = KeychainService.importedKeyAccount(for: keyID)
        let passphraseAccount = KeychainService.passphraseAccount(for: keyID)
        defer {
            try? KeychainService.deleteSecret(account: importedAccount)
            try? KeychainService.deleteSecret(account: passphraseAccount)
        }
        try KeychainService.saveSecret("fixture-private-key", account: importedAccount)
        try KeychainService.saveSecret("fixture-passphrase", account: passphraseAccount)

        let plan = SSHKeyEditorCredentialPlan.make(
            existingStorageMode: .imported,
            existingFilePath: "imported",
            proposedFilePath: "imported",
            importIntoApp: true,
            newPassphrase: "",
            removeStoredPassphrase: false,
            hasStoredPassphrase: true
        )
        try plan.applyPassphrase(to: keyID)

        XCTAssertTrue(plan.reuseImportedMaterial)
        XCTAssertEqual(plan.passphraseEdit, .preserve)
        XCTAssertTrue(plan.resultingHasPassphrase)
        XCTAssertEqual(try KeychainService.secret(account: importedAccount), "fixture-private-key")
        XCTAssertEqual(try KeychainService.secret(account: passphraseAccount), "fixture-passphrase")
    }

    func testSSHKeyPassphraseChangesOnlyOnExplicitReplaceOrRemove() throws {
        let keyID = UUID()
        let account = KeychainService.passphraseAccount(for: keyID)
        defer { try? KeychainService.deleteSecret(account: account) }
        try KeychainService.saveSecret("old-passphrase", account: account)

        let replacement = SSHKeyEditorCredentialPlan.make(
            existingStorageMode: .file,
            existingFilePath: "/tmp/key",
            proposedFilePath: "/tmp/key",
            importIntoApp: false,
            newPassphrase: "new-passphrase",
            removeStoredPassphrase: true,
            hasStoredPassphrase: true
        )
        try replacement.applyPassphrase(to: keyID)
        XCTAssertEqual(replacement.passphraseEdit, .replace("new-passphrase"))
        XCTAssertTrue(replacement.resultingHasPassphrase)
        XCTAssertEqual(try KeychainService.secret(account: account), "new-passphrase")

        let removal = SSHKeyEditorCredentialPlan.make(
            existingStorageMode: .file,
            existingFilePath: "/tmp/key",
            proposedFilePath: "/tmp/key",
            importIntoApp: false,
            newPassphrase: "",
            removeStoredPassphrase: true,
            hasStoredPassphrase: true
        )
        try removal.applyPassphrase(to: keyID)
        XCTAssertEqual(removal.passphraseEdit, .remove)
        XCTAssertFalse(removal.resultingHasPassphrase)
        XCTAssertNil(try KeychainService.secret(account: account))
    }

    func testIdentityMetadataOnlyEditPreservesStoredPassword() throws {
        let identityID = UUID()
        defer { try? KeychainService.deletePassword(for: identityID) }
        try KeychainService.savePassword("existing-password", for: identityID)

        try IdentityPasswordUpdate.apply(
            replacement: "",
            removeStoredPassword: false,
            identityID: identityID
        )
        XCTAssertEqual(try KeychainService.password(for: identityID), "existing-password")

        try IdentityPasswordUpdate.apply(
            replacement: "replacement-password",
            removeStoredPassword: true,
            identityID: identityID
        )
        XCTAssertEqual(try KeychainService.password(for: identityID), "replacement-password")

        try IdentityPasswordUpdate.apply(
            replacement: "",
            removeStoredPassword: false,
            identityID: identityID
        )
        XCTAssertEqual(try KeychainService.password(for: identityID), "replacement-password", "Changing authentication or metadata must not implicitly delete the stored password")

        try IdentityPasswordUpdate.apply(
            replacement: "",
            removeStoredPassword: true,
            identityID: identityID
        )
        XCTAssertNil(try KeychainService.password(for: identityID))
    }

    func testIdentityPasswordReplacementRollsBackWhenModelSaveFails() throws {
        let identityID = UUID()
        defer { try? KeychainService.deletePassword(for: identityID) }
        try KeychainService.savePassword("old-password", for: identityID)

        let mutations = IdentityPasswordUpdate.mutations(
            replacement: "new-password",
            removeStoredPassword: false,
            identityID: identityID
        )
        XCTAssertThrowsError(
            try KeychainMutationTransaction.commit(mutations) {
                throw FixturePersistenceError.failed
            }
        )
        XCTAssertEqual(try KeychainService.password(for: identityID), "old-password")
    }

    func testServerMetadataEditPreservesStoredPasswordAndPassphrase() {
        let serverID = UUID()
        let plan = ServerEditorCredentialPlan.make(
            passwordAccount: serverID.uuidString,
            passphraseAccount: KeychainService.passphraseAccount(for: serverID),
            replacementPassword: "",
            removeStoredPassword: false,
            replacementPassphrase: "",
            removeStoredPassphrase: false
        )
        XCTAssertTrue(plan.mutations.isEmpty, "Changing notes or authentication must not implicitly remove credentials")
    }

    func testServerCredentialChangesRollBackWhenModelSaveFails() throws {
        let serverID = UUID()
        let passwordAccount = serverID.uuidString
        let passphraseAccount = KeychainService.passphraseAccount(for: serverID)
        defer {
            try? KeychainService.deleteSecret(account: passwordAccount)
            try? KeychainService.deleteSecret(account: passphraseAccount)
        }
        try KeychainService.saveSecret("old-password", account: passwordAccount)
        try KeychainService.saveSecret("old-passphrase", account: passphraseAccount)
        let plan = ServerEditorCredentialPlan.make(
            passwordAccount: passwordAccount,
            passphraseAccount: passphraseAccount,
            replacementPassword: "new-password",
            removeStoredPassword: false,
            replacementPassphrase: "",
            removeStoredPassphrase: true
        )

        XCTAssertThrowsError(
            try KeychainMutationTransaction.commit(plan.mutations) {
                throw FixturePersistenceError.failed
            }
        )
        XCTAssertEqual(try KeychainService.secret(account: passwordAccount), "old-password")
        XCTAssertEqual(try KeychainService.secret(account: passphraseAccount), "old-passphrase")
    }

    func testSSHKeySecretsRollBackWhenModelSaveFails() throws {
        let keyID = UUID()
        let importedAccount = KeychainService.importedKeyAccount(for: keyID)
        let passphraseAccount = KeychainService.passphraseAccount(for: keyID)
        let newlyCreatedAccount = "fixture-new-secret.\(keyID.uuidString)"
        defer {
            try? KeychainService.deleteSecret(account: importedAccount)
            try? KeychainService.deleteSecret(account: passphraseAccount)
            try? KeychainService.deleteSecret(account: newlyCreatedAccount)
        }
        try KeychainService.saveSecret("old-private-key", account: importedAccount)
        try KeychainService.saveSecret("old-passphrase", account: passphraseAccount)

        XCTAssertThrowsError(
            try KeychainMutationTransaction.commit([
                .replace(account: importedAccount, value: "new-private-key"),
                .remove(account: passphraseAccount),
                .replace(account: newlyCreatedAccount, value: "temporary-secret")
            ]) {
                throw FixturePersistenceError.failed
            }
        )
        XCTAssertEqual(try KeychainService.secret(account: importedAccount), "old-private-key")
        XCTAssertEqual(try KeychainService.secret(account: passphraseAccount), "old-passphrase")
        XCTAssertNil(try KeychainService.secret(account: newlyCreatedAccount))
    }

    @MainActor
    func testAsyncLeaseRejectsOverlappingSyncSaveAndReleasesAfterCompletion() async throws {
        let account = "fixture-exclusive-lease.\(UUID().uuidString)"
        defer { try? KeychainService.deleteSecret(account: account) }
        try KeychainService.saveSecret("original", account: account)

        let asyncStarted = AsyncTestGate()
        let releaseAsync = AsyncTestGate()
        let activeTransaction = Task { @MainActor in
            try await KeychainMutationTransaction.commitAsync([
                .replace(account: account, value: "leased")
            ]) { () async throws -> Void in
                await asyncStarted.open()
                await releaseAsync.wait()
            }
        }

        await asyncStarted.wait()
        var blockedModelClosureRan = false
        XCTAssertThrowsError(
            try KeychainMutationTransaction.commit([
                .replace(account: account, value: "blocked")
            ]) {
                blockedModelClosureRan = true
            }
        ) { error in
            XCTAssertEqual(error.localizedDescription, "此配置正在另一个窗口中验证或保存，请稍后重试。")
        }
        XCTAssertFalse(blockedModelClosureRan, "A rejected save must not write its model")
        XCTAssertEqual(try KeychainService.secret(account: account), "leased")

        await releaseAsync.open()
        try await activeTransaction.value

        var laterModelClosureRan = false
        try KeychainMutationTransaction.commit([
            .replace(account: account, value: "later")
        ]) {
            laterModelClosureRan = true
        }
        XCTAssertTrue(laterModelClosureRan)
        XCTAssertEqual(try KeychainService.secret(account: account), "later")
    }

    @MainActor
    func testExplicitCoordinationKeyProtectsMetadataOnlyTransactions() async throws {
        let coordinationKey = "fixture-metadata-only.\(UUID().uuidString)"
        let asyncStarted = AsyncTestGate()
        let releaseAsync = AsyncTestGate()
        let activeTransaction = Task { @MainActor in
            try await KeychainMutationTransaction.commitAsync(
                [],
                coordinationKeys: [coordinationKey]
            ) { () async throws -> Void in
                await asyncStarted.open()
                await releaseAsync.wait()
            }
        }

        await asyncStarted.wait()
        var blockedModelClosureRan = false
        XCTAssertThrowsError(
            try KeychainMutationTransaction.commit(
                [],
                coordinationKeys: [coordinationKey]
            ) {
                blockedModelClosureRan = true
            }
        )
        XCTAssertFalse(blockedModelClosureRan)

        await releaseAsync.open()
        try await activeTransaction.value

        var laterModelClosureRan = false
        try KeychainMutationTransaction.commit(
            [],
            coordinationKeys: [coordinationKey]
        ) {
            laterModelClosureRan = true
        }
        XCTAssertTrue(laterModelClosureRan)
    }

    @MainActor
    func testAsyncLeaseReleasesWhenOperationIsCancelled() async throws {
        let coordinationKey = "fixture-cancelled-lease.\(UUID().uuidString)"
        let asyncStarted = AsyncTestGate()
        let activeTransaction = Task { @MainActor in
            try await KeychainMutationTransaction.commitAsync(
                [],
                coordinationKeys: [coordinationKey]
            ) { () async throws -> Void in
                await asyncStarted.open()
                try await Task.sleep(for: .seconds(60))
            }
        }

        await asyncStarted.wait()
        activeTransaction.cancel()
        do {
            try await activeTransaction.value
            XCTFail("Cancellation should leave the async operation through its error path")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        var laterModelClosureRan = false
        try KeychainMutationTransaction.commit(
            [],
            coordinationKeys: [coordinationKey]
        ) {
            laterModelClosureRan = true
        }
        XCTAssertTrue(laterModelClosureRan)
    }

    @MainActor
    func testMultiAccountLeaseIsAtomicAndDoesNotBlockUnrelatedAccounts() async throws {
        let firstAccount = "fixture-exclusive-multi-a.\(UUID().uuidString)"
        let secondAccount = "fixture-exclusive-multi-b.\(UUID().uuidString)"
        let unrelatedAccount = "fixture-exclusive-multi-c.\(UUID().uuidString)"
        defer {
            try? KeychainService.deleteSecret(account: firstAccount)
            try? KeychainService.deleteSecret(account: secondAccount)
            try? KeychainService.deleteSecret(account: unrelatedAccount)
        }
        try KeychainService.saveSecret("first-original", account: firstAccount)
        try KeychainService.saveSecret("second-original", account: secondAccount)

        let asyncStarted = AsyncTestGate()
        let releaseAsync = AsyncTestGate()
        let activeTransaction = Task { @MainActor in
            try await KeychainMutationTransaction.commitAsync([
                .replace(account: secondAccount, value: "second-leased"),
                .replace(account: firstAccount, value: "first-leased")
            ]) { () async throws -> Void in
                await asyncStarted.open()
                await releaseAsync.wait()
                throw FixturePersistenceError.failed
            }
        }

        await asyncStarted.wait()
        XCTAssertThrowsError(
            try KeychainMutationTransaction.commit([
                .replace(account: firstAccount, value: "blocked")
            ]) {}
        )
        XCTAssertThrowsError(
            try KeychainMutationTransaction.commit([
                .replace(account: secondAccount, value: "blocked")
            ]) {}
        )
        try KeychainMutationTransaction.commit([
            .replace(account: unrelatedAccount, value: "unrelated-saved")
        ]) {
            // A disjoint account can save while the two-key lease is active.
        }
        XCTAssertEqual(try KeychainService.secret(account: unrelatedAccount), "unrelated-saved")

        await releaseAsync.open()
        do {
            try await activeTransaction.value
            XCTFail("The active transaction should report its operation failure")
        } catch {
            XCTAssertTrue(error is FixturePersistenceError)
        }
        XCTAssertEqual(try KeychainService.secret(account: firstAccount), "first-original")
        XCTAssertEqual(try KeychainService.secret(account: secondAccount), "second-original")

        XCTAssertNoThrow(
            try KeychainMutationTransaction.commit([
                .replace(account: firstAccount, value: "first-later"),
                .replace(account: secondAccount, value: "second-later")
            ]) {}
        )
    }

    @MainActor
    func testAsyncRollbackPreservesUncoordinatedNewerKeychainValue() async throws {
        let account = "fixture-external-keychain-write.\(UUID().uuidString)"
        defer { try? KeychainService.deleteSecret(account: account) }
        try KeychainService.saveSecret("original", account: account)

        let asyncStarted = AsyncTestGate()
        let releaseAsync = AsyncTestGate()
        let activeTransaction = Task { @MainActor in
            try await KeychainMutationTransaction.commitAsync([
                .replace(account: account, value: "leased")
            ]) { () async throws -> Void in
                await asyncStarted.open()
                await releaseAsync.wait()
                throw FixturePersistenceError.failed
            }
        }

        await asyncStarted.wait()
        try KeychainService.saveSecret("external", account: account)
        await releaseAsync.open()
        do {
            try await activeTransaction.value
            XCTFail("The active transaction should fail")
        } catch {
            XCTAssertTrue(error is FixturePersistenceError)
        }
        XCTAssertEqual(try KeychainService.secret(account: account), "external")
    }

    @MainActor
    func testServerVersionGuardRejectsModelChangeDuringAsyncLease() async throws {
        let account = "fixture-server-version-guard.\(UUID().uuidString)"
        defer { try? KeychainService.deleteSecret(account: account) }
        try KeychainService.saveSecret("original", account: account)
        let record = ServerRecord(name: "Original", host: "example.test", username: "root")
        let expectedVersion = ServerEditorRecordVersion(record)
        XCTAssertThrowsError(try expectedVersion.validate(nil), "A deleted record must be treated as stale")

        let asyncStarted = AsyncTestGate()
        let releaseAsync = AsyncTestGate()
        let activeTransaction = Task { @MainActor in
            try await KeychainMutationTransaction.commitAsync([
                .replace(account: account, value: "leased")
            ]) { () async throws -> Void in
                await asyncStarted.open()
                await releaseAsync.wait()
                try expectedVersion.validate(record)
            }
        }

        await asyncStarted.wait()
        record.notes = "Changed elsewhere"
        await releaseAsync.open()
        do {
            try await activeTransaction.value
            XCTFail("The stale editor should reject its model write")
        } catch {
            XCTAssertEqual(error.localizedDescription, "配置已在另一窗口更新，请重新载入后再试。")
        }
        XCTAssertEqual(try KeychainService.secret(account: account), "original")
    }

    @MainActor
    func testServerLeaseCoversSharedSSHKeyMaterialAndMetadataOnlyKeySaves() async throws {
        let serverID = UUID()
        let identityID = UUID()
        let keyID = UUID()
        let config = ServerConnectionConfig(
            id: serverID,
            credentialID: identityID,
            name: "Fixture",
            host: "example.test",
            port: 22,
            username: "root",
            authentication: .privateKey,
            privateKeyPath: "imported",
            sshKeyID: keyID,
            usesImportedKey: true,
            hasPassphrase: true
        )
        let serverKeys = ConnectionConfigurationCoordination.serverEditor(
            draftID: serverID,
            config: config
        )
        let keyEditorKeys = ConnectionConfigurationCoordination.sshKey(keyID)
        XCTAssertTrue(Set(keyEditorKeys).isSubset(of: Set(serverKeys)))
        XCTAssertTrue(serverKeys.contains(KeychainService.importedKeyAccount(for: keyID)))
        XCTAssertTrue(serverKeys.contains(KeychainService.passphraseAccount(for: keyID)))

        let asyncStarted = AsyncTestGate()
        let releaseAsync = AsyncTestGate()
        let activeTest = Task { @MainActor in
            try await KeychainMutationTransaction.commitAsync(
                [],
                coordinationKeys: serverKeys
            ) { () async throws -> Void in
                await asyncStarted.open()
                await releaseAsync.wait()
            }
        }

        await asyncStarted.wait()
        var staleMetadataSaveRan = false
        XCTAssertThrowsError(
            try KeychainMutationTransaction.commit(
                [],
                coordinationKeys: keyEditorKeys
            ) {
                staleMetadataSaveRan = true
            }
        ) { error in
            XCTAssertEqual(error.localizedDescription, "此配置正在另一个窗口中验证或保存，请稍后重试。")
        }
        XCTAssertFalse(staleMetadataSaveRan)

        await releaseAsync.open()
        try await activeTest.value

        var laterMetadataSaveRan = false
        try KeychainMutationTransaction.commit(
            [],
            coordinationKeys: keyEditorKeys
        ) {
            laterMetadataSaveRan = true
        }
        XCTAssertTrue(laterMetadataSaveRan)
    }

    @MainActor
    func testSSHKeySaveLeaseStartsBeforeAsyncInspectionAndRejectsOverlappingEditor() async throws {
        let keyID = UUID()
        let coordinationKeys = ConnectionConfigurationCoordination.sshKey(keyID)
        let inspectionStarted = AsyncTestGate()
        let releaseInspection = AsyncTestGate()
        var committedEditors: [String] = []

        let firstEditor = Task { @MainActor in
            try await KeychainMutationTransaction.commitAsync(
                [],
                coordinationKeys: coordinationKeys
            ) { () async throws -> Void in
                await inspectionStarted.open()
                await releaseInspection.wait()
                committedEditors.append("first")
            }
        }

        await inspectionStarted.wait()

        do {
            try await KeychainMutationTransaction.commitAsync(
                [],
                coordinationKeys: coordinationKeys
            ) { () async throws -> Void in
                committedEditors.append("second")
            }
            XCTFail("A second SSH key editor must not enter inspection while the first editor holds the save lease")
        } catch {
            XCTAssertEqual(error.localizedDescription, "此配置正在另一个窗口中验证或保存，请稍后重试。")
        }
        XCTAssertTrue(committedEditors.isEmpty)

        await releaseInspection.open()
        try await firstEditor.value
        XCTAssertEqual(committedEditors, ["first"])
    }

    @MainActor
    func testConnectionDependencyGuardRejectsKeyAndRouteChangesDuringAsyncTest() async throws {
        let server = ServerRecord(name: "Fixture", host: "example.test", username: "root")
        let key = SSHKeyRecord(
            name: "Key",
            filePath: "imported",
            algorithm: "ED25519",
            fingerprint: "SHA256:old",
            storageMode: .imported,
            hasPassphrase: true
        )
        let identity = IdentityRecord(
            name: "Identity",
            username: "root",
            authentication: .privateKey,
            sshKeyID: key.id
        )
        server.identityID = identity.id
        let route = try ConnectionRouteRecord(
            route: ConnectionRoute(name: "Original route"),
            serverID: server.id
        )
        let expected = ServerEditorConnectionDependencyVersion(
            server: server,
            identityID: identity.id,
            identity: identity,
            sshKeyID: key.id,
            sshKey: key,
            routes: [route]
        )

        let asyncStarted = AsyncTestGate()
        let releaseAsync = AsyncTestGate()
        var staleModelCommitRan = false
        let activeTest = Task { @MainActor in
            try await KeychainMutationTransaction.commitAsync(
                [],
                coordinationKeys: ConnectionConfigurationCoordination.serverEditor(
                    draftID: server.id,
                    config: ServerConnectionConfig(
                        id: server.id,
                        credentialID: identity.id,
                        name: server.name,
                        host: server.host,
                        port: server.port,
                        username: identity.username,
                        authentication: identity.authentication,
                        privateKeyPath: key.filePath,
                        sshKeyID: key.id,
                        usesImportedKey: true,
                        hasPassphrase: key.hasPassphrase
                    )
                )
            ) { () async throws -> Void in
                await asyncStarted.open()
                await releaseAsync.wait()
                try expected.validate(
                    server: server,
                    identity: identity,
                    sshKey: key,
                    routes: [route]
                )
                staleModelCommitRan = true
            }
        }

        await asyncStarted.wait()
        route.revision = UUID()
        route.routeJSON = #"{"name":"replacement"}"#
        await releaseAsync.open()
        do {
            try await activeTest.value
            XCTFail("A route changed during the SSH test must reject the stale success")
        } catch {
            XCTAssertEqual(error.localizedDescription, "配置已在另一窗口更新，请重新载入后再试。")
        }
        XCTAssertFalse(staleModelCommitRan)

        let keyExpected = ServerEditorConnectionDependencyVersion(
            server: server,
            identityID: identity.id,
            identity: identity,
            sshKeyID: key.id,
            sshKey: key,
            routes: [route]
        )
        key.fingerprint = "SHA256:new"
        XCTAssertThrowsError(
            try keyExpected.validate(
                server: server,
                identity: identity,
                sshKey: key,
                routes: [route]
            )
        ) { error in
            XCTAssertEqual(error.localizedDescription, "配置已在另一窗口更新，请重新载入后再试。")
        }
    }

    func testImportedKeyCanSelectTheSameExternalPathExplicitly() {
        let path = "/tmp/fixture-key"
        let withoutSelection = SSHKeyEditorCredentialPlan.make(
            existingStorageMode: .imported,
            existingFilePath: path,
            proposedFilePath: path,
            importIntoApp: false,
            newPassphrase: "",
            removeStoredPassphrase: false,
            hasStoredPassphrase: false,
            explicitFileSelection: false
        )
        XCTAssertTrue(withoutSelection.requiresExplicitExternalFile)

        let explicitlySelected = SSHKeyEditorCredentialPlan.make(
            existingStorageMode: .imported,
            existingFilePath: path,
            proposedFilePath: path,
            importIntoApp: false,
            newPassphrase: "",
            removeStoredPassphrase: false,
            hasStoredPassphrase: false,
            explicitFileSelection: true
        )
        XCTAssertFalse(explicitlySelected.requiresExplicitExternalFile)

        let replacementImport = SSHKeyEditorCredentialPlan.make(
            existingStorageMode: .imported,
            existingFilePath: path,
            proposedFilePath: path,
            importIntoApp: true,
            newPassphrase: "",
            removeStoredPassphrase: false,
            hasStoredPassphrase: false,
            explicitFileSelection: true
        )
        XCTAssertFalse(replacementImport.reuseImportedMaterial)
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
