@preconcurrency import Citadel
import Crypto
import Foundation
import NIOCore
@preconcurrency import NIOSSH

struct CitadelRemoteConnectionEngine: RemoteConnectionEngine {
    let capabilities = PlatformCapabilities.mobile

    func connect(
        _ config: ServerConnectionConfig,
        trustHandler: @escaping RemoteHostTrustHandler
    ) async throws -> any RemoteSession {
        guard config.route.isDirect else {
            throw RemoteConnectionFailure.indirectRouteUnsupported
        }
        guard !config.identityReferenceMissing,
              !config.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !config.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemoteConnectionFailure.missingCredential
        }

        let authentication = try MobileSSHKeyCodec.authenticationFactory(for: config)
        let validator = SSHHostKeyValidator.custom(
            CitadelHostKeyValidator(
                host: config.host,
                port: config.port,
                trustHandler: trustHandler
            )
        )
        var settings = SSHClientSettings(
            host: config.host,
            port: config.port,
            authenticationMethod: authentication.make,
            hostKeyValidator: validator
        )
        settings.connectTimeout = .seconds(Int64(max(5, config.connectTimeout.rounded(.up))))
        settings.algorithms = authentication.algorithms

        do {
            let client = try await SSHClient.connect(to: settings)
            EventLogStore.shared.append(
                serverID: config.id,
                module: .ssh,
                message: "移动端原生 SSH 连接成功"
            )
            return CitadelRemoteSession(client: client)
        } catch let error as RemoteConnectionFailure {
            throw error
        } catch {
            EventLogStore.shared.append(
                serverID: config.id,
                module: .ssh,
                level: "error",
                message: "移动端原生 SSH 连接失败"
            )
            throw Self.map(error)
        }
    }

    private static func map(_ error: Error) -> RemoteConnectionFailure {
        let message = error.localizedDescription
        let lowered = message.lowercased()
        if lowered.contains("timed out") || lowered.contains("timeout") {
            return .timedOut
        }
        if error is InvalidHostKey || lowered.contains("host key") {
            return .hostKeyRejected
        }
        return .transport(message)
    }
}

private struct MobileAuthenticationFactory: @unchecked Sendable {
    let make: @Sendable () -> SSHAuthenticationMethod
    let algorithms: SSHAlgorithms
}

enum MobileSSHKeyCodec {
    struct Inspection: Sendable {
        let algorithm: String
        let fingerprint: String
        let publicKey: String
    }

    static func inspect(pem: String, passphrase: String?) throws -> Inspection {
        let privateKey = try parsePrivateKey(pem: pem, passphrase: passphrase)
        return inspection(for: privateKey.nioKey.publicKey)
    }

    fileprivate static func authenticationFactory(
        for config: ServerConnectionConfig
    ) throws -> MobileAuthenticationFactory {
        let password = try KeychainService.password(for: config.credentialID)
        let key: ParsedPrivateKey? = try loadPrivateKey(for: config)
        let algorithms = key?.requiresRSARegistration == true ? rsaAlgorithms() : SSHAlgorithms()

        switch config.authentication {
        case .password:
            guard let password, !password.isEmpty else {
                throw RemoteConnectionFailure.missingCredential
            }
            return MobileAuthenticationFactory(
                make: { .passwordBased(username: config.username, password: password) },
                algorithms: algorithms
            )
        case .privateKey:
            guard let key else { throw RemoteConnectionFailure.missingCredential }
            return MobileAuthenticationFactory(
                make: { key.authentication(username: config.username) },
                algorithms: algorithms
            )
        case .keyThenPassword:
            guard key != nil || password?.isEmpty == false else {
                throw RemoteConnectionFailure.missingCredential
            }
            return MobileAuthenticationFactory(
                make: {
                    let offers = MobileAuthenticationDelegate(
                        username: config.username,
                        privateKey: key?.nioKey,
                        password: password
                    )
                    return .custom(offers)
                },
                algorithms: algorithms
            )
        }
    }

    private enum ParsedPrivateKey: @unchecked Sendable {
        case ed25519(Curve25519.Signing.PrivateKey)
        case rsa(Insecure.RSA.PrivateKey)

        var nioKey: NIOSSHPrivateKey {
            switch self {
            case .ed25519(let key): NIOSSHPrivateKey(ed25519Key: key)
            case .rsa(let key): NIOSSHPrivateKey(custom: key)
            }
        }

        var requiresRSARegistration: Bool {
            if case .rsa = self { return true }
            return false
        }

        func authentication(username: String) -> SSHAuthenticationMethod {
            switch self {
            case .ed25519(let key): .ed25519(username: username, privateKey: key)
            case .rsa(let key): .rsa(username: username, privateKey: key)
            }
        }
    }

    private static func loadPrivateKey(
        for config: ServerConnectionConfig
    ) throws -> ParsedPrivateKey? {
        guard config.usesImportedKey, let keyID = config.sshKeyID,
              let pem = try KeychainService.secret(
                account: KeychainService.importedKeyAccount(for: keyID)
              ) else {
            return nil
        }
        let passphrase: String? = if config.hasPassphrase {
            try KeychainService.secret(account: KeychainService.passphraseAccount(for: keyID))
        } else {
            nil
        }
        return try parsePrivateKey(pem: pem, passphrase: passphrase)
    }

    private static func parsePrivateKey(
        pem: String,
        passphrase: String?
    ) throws -> ParsedPrivateKey {
        let decryptionKey = passphrase?.data(using: .utf8)
        if let key = try? Curve25519.Signing.PrivateKey(
            sshEd25519: pem,
            decryptionKey: decryptionKey
        ) {
            return .ed25519(key)
        }
        if let key = try? Insecure.RSA.PrivateKey(
            sshRsa: pem,
            decryptionKey: decryptionKey
        ) {
            return .rsa(key)
        }
        throw RemoteConnectionFailure.invalidPrivateKey
    }

    private static func rsaAlgorithms() -> SSHAlgorithms {
        var algorithms = SSHAlgorithms()
        algorithms.publicKeyAlgorihtms = .add([
            (Insecure.RSA.PublicKey.self, Insecure.RSA.Signature.self)
        ])
        return algorithms
    }

    private static func inspection(for publicKey: NIOSSHPublicKey) -> Inspection {
        var buffer = ByteBufferAllocator().buffer(capacity: 512)
        publicKey.write(to: &buffer)
        let blob = Data(buffer.readableBytesView)
        let algorithm = algorithm(in: blob) ?? "ssh-key"
        let fingerprint = TrustedHostStore.fingerprint(
            algorithm: algorithm,
            keyBlob: blob
        )
        return Inspection(
            algorithm: TrustedHostStore.algorithmDisplayName(algorithm),
            fingerprint: fingerprint,
            publicKey: "\(algorithm) \(blob.base64EncodedString())"
        )
    }

    fileprivate static func algorithm(in blob: Data) -> String? {
        guard blob.count >= 4 else { return nil }
        let length = blob.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, blob.count >= 4 + length else { return nil }
        return String(data: blob.subdata(in: 4..<(4 + length)), encoding: .utf8)
    }
}

private final class MobileAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private let lock = NSLock()
    private var offers: [NIOSSHUserAuthenticationOffer.Offer]

    init(username: String, privateKey: NIOSSHPrivateKey?, password: String?) {
        self.username = username
        var values: [NIOSSHUserAuthenticationOffer.Offer] = []
        if let privateKey {
            values.append(.privateKey(.init(privateKey: privateKey)))
        }
        if let password, !password.isEmpty {
            values.append(.password(.init(password: password)))
        }
        offers = values
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        lock.lock()
        defer { lock.unlock() }
        while !offers.isEmpty {
            let offer = offers.removeFirst()
            switch offer {
            case .privateKey where !availableMethods.contains(.publicKey): continue
            case .password where !availableMethods.contains(.password): continue
            default:
                nextChallengePromise.succeed(
                    NIOSSHUserAuthenticationOffer(
                        username: username,
                        serviceName: "ssh-connection",
                        offer: offer
                    )
                )
                return
            }
        }
        nextChallengePromise.fail(RemoteConnectionFailure.missingCredential)
    }
}

private final class CitadelHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let host: String
    let port: Int
    let trustHandler: RemoteHostTrustHandler

    init(host: String, port: Int, trustHandler: @escaping RemoteHostTrustHandler) {
        self.host = host
        self.port = port
        self.trustHandler = trustHandler
    }

    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        var buffer = ByteBufferAllocator().buffer(capacity: 512)
        hostKey.write(to: &buffer)
        let blob = Data(buffer.readableBytesView)
        guard let algorithm = MobileSSHKeyCodec.algorithm(in: blob) else {
            validationCompletePromise.fail(RemoteConnectionFailure.hostKeyRejected)
            return
        }
        let presentation = RemoteHostKeyPresentation(
            host: host,
            port: port,
            algorithm: algorithm,
            keyBlob: blob
        )
        Task {
            do {
                switch try await trustHandler(presentation) {
                case .trustOnce, .trustAndStore:
                    validationCompletePromise.succeed(())
                case .reject:
                    validationCompletePromise.fail(RemoteConnectionFailure.hostKeyRejected)
                }
            } catch {
                validationCompletePromise.fail(error)
            }
        }
    }
}

private actor CitadelRemoteSession: RemoteSession {
    private let client: SSHClient
    private var closed = false

    init(client: SSHClient) {
        self.client = client
    }

    func execute(
        _ command: String,
        timeout: TimeInterval,
        maxOutputBytes: Int
    ) async throws -> RemoteCommandResult {
        guard !closed else { throw RemoteConnectionFailure.sessionClosed }
        return try await withThrowingTaskGroup(of: RemoteCommandResult.self) { group in
            group.addTask { [client] in
                var stdout = Data()
                var stderr = Data()
                do {
                    let stream = try await client.executeCommandStream(command)
                    for try await output in stream {
                        try Task.checkCancellation()
                        let chunk: Data
                        switch output {
                        case .stdout(let buffer):
                            chunk = Data(buffer.readableBytesView)
                            stdout.append(chunk)
                        case .stderr(let buffer):
                            chunk = Data(buffer.readableBytesView)
                            stderr.append(chunk)
                        }
                        guard stdout.count + stderr.count <= max(1, maxOutputBytes) else {
                            throw RemoteConnectionFailure.outputLimitExceeded
                        }
                    }
                    return RemoteCommandResult(stdout: stdout, stderr: stderr, exitCode: 0)
                } catch let failure as SSHClient.CommandFailed {
                    return RemoteCommandResult(
                        stdout: stdout,
                        stderr: stderr,
                        exitCode: failure.exitCode
                    )
                }
            }
            group.addTask { [client] in
                try await Task.sleep(for: .seconds(max(1, timeout)))
                try? await client.close()
                throw RemoteConnectionFailure.timedOut
            }
            guard let result = try await group.next() else {
                throw RemoteConnectionFailure.sessionClosed
            }
            group.cancelAll()
            return result
        }
    }

    func openShell(
        dimensions: RemoteShellDimensions
    ) async throws -> any RemoteShellSession {
        guard !closed else { throw RemoteConnectionFailure.sessionClosed }
        let shell = CitadelRemoteShellSession(client: client)
        try await shell.start(dimensions: dimensions)
        return shell
    }

    func openSFTP() async throws -> any RemoteFileClient {
        guard !closed else { throw RemoteConnectionFailure.sessionClosed }
        return CitadelRemoteFileClient(client: try await client.openSFTP())
    }

    func close() async {
        guard !closed else { return }
        closed = true
        try? await client.close()
    }
}

private actor CitadelRemoteShellSession: RemoteShellSession {
    nonisolated let events: AsyncThrowingStream<Data, Error>

    private let client: SSHClient
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var writer: TTYStdinWriter?
    private var task: Task<Void, Never>?
    private var closed = false

    init(client: SSHClient) {
        self.client = client
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    func start(dimensions: RemoteShellDimensions) async throws {
        let size = dimensions.normalized
        task = Task { [client, continuation] in
            do {
                try await client.withPTY(
                    SSHChannelRequestEvent.PseudoTerminalRequest(
                        wantReply: true,
                        term: "xterm-256color",
                        terminalCharacterWidth: size.columns,
                        terminalRowHeight: size.rows,
                        terminalPixelWidth: size.pixelWidth,
                        terminalPixelHeight: size.pixelHeight,
                        terminalModes: .init([.ECHO: 1])
                    )
                ) { inbound, outbound in
                    self.setWriter(outbound)
                    for try await output in inbound {
                        switch output {
                        case .stdout(let buffer), .stderr(let buffer):
                            continuation.yield(Data(buffer.readableBytesView))
                        }
                    }
                }
                continuation.finish()
            } catch is CancellationError {
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }

        for _ in 0..<100 {
            if writer != nil { return }
            if task?.isCancelled == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        task?.cancel()
        task = nil
        closed = true
        try? await client.close()
        continuation.finish(throwing: RemoteConnectionFailure.timedOut)
        throw RemoteConnectionFailure.timedOut
    }

    private func setWriter(_ writer: TTYStdinWriter) {
        self.writer = writer
    }

    func write(_ data: Data) async throws {
        guard !closed, let writer else {
            throw RemoteConnectionFailure.sessionClosed
        }
        try await writer.write(ByteBuffer(bytes: data))
    }

    func resize(_ dimensions: RemoteShellDimensions) async throws {
        guard !closed, let writer else {
            throw RemoteConnectionFailure.sessionClosed
        }
        let size = dimensions.normalized
        try await writer.changeSize(
            cols: size.columns,
            rows: size.rows,
            pixelWidth: size.pixelWidth,
            pixelHeight: size.pixelHeight
        )
    }

    func close() async {
        guard !closed else { return }
        closed = true
        task?.cancel()
        task = nil
        writer = nil
        try? await client.close()
        continuation.finish()
    }
}

private actor CitadelRemoteFileClient: RemoteFileClient {
    private let client: SFTPClient
    private var closed = false

    init(client: SFTPClient) {
        self.client = client
    }

    func list(path: String) async throws -> SFTPDirectoryListing {
        try ensureOpen()
        let resolved = try await client.getRealPath(atPath: path)
        let groups = try await client.listDirectory(atPath: resolved)
        let items = groups
            .flatMap(\.components)
            .filter { $0.filename != "." && $0.filename != ".." }
            .map { component in
                let marker = component.longname.first
                let kind: RemoteFileKind = switch marker {
                case "d": .directory
                case "l": .symbolicLink
                case "-": .file
                default: .other
                }
                let permissions = component.attributes.permissions.map {
                    String(format: "%o", $0 & 0o7777)
                } ?? ""
                let modified = component.attributes.accessModificationTime?.modificationTime
                    .formatted(date: .abbreviated, time: .shortened) ?? ""
                return RemoteFileItem(
                    path: RemotePath.child(component.filename, of: resolved),
                    name: component.filename,
                    kind: kind,
                    size: Int64(component.attributes.size ?? 0),
                    permissions: permissions,
                    owner: "",
                    group: "",
                    modifiedText: modified
                )
            }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        return SFTPDirectoryListing(path: resolved, items: items)
    }

    func createDirectory(named name: String, in path: String) async throws {
        try ensureOpen()
        try validate(name)
        try await client.createDirectory(atPath: RemotePath.child(name, of: path))
    }

    func createFile(named name: String, in path: String) async throws {
        try ensureOpen()
        try validate(name)
        _ = try await client.withFile(
            filePath: RemotePath.child(name, of: path),
            flags: [.write, .create, .truncate]
        ) { _ in () }
    }

    func rename(_ item: RemoteFileItem, to newName: String) async throws {
        try ensureOpen()
        try validate(newName)
        try await client.rename(
            at: item.path,
            to: RemotePath.child(newName, of: RemotePath.parent(of: item.path))
        )
    }

    func move(_ item: RemoteFileItem, to directory: String) async throws {
        try ensureOpen()
        try await client.rename(
            at: item.path,
            to: RemotePath.child(item.name, of: directory)
        )
    }

    func delete(_ item: RemoteFileItem, recursive: Bool) async throws {
        try ensureOpen()
        if item.isDirectory {
            if recursive {
                let listing = try await list(path: item.path)
                for child in listing.items {
                    try await delete(child, recursive: true)
                }
            }
            try await client.rmdir(at: item.path)
        } else {
            try await client.remove(at: item.path)
        }
    }

    func upload(
        localURL: URL,
        to remotePath: String,
        onProgress: (@Sendable (SFTPProgress) -> Void)?
    ) async throws {
        try ensureOpen()
        let values = try localURL.resourceValues(forKeys: [.fileSizeKey])
        let total = Int64(values.fileSize ?? 0)
        let started = Date()
        let local = try FileHandle(forReadingFrom: localURL)
        defer { try? local.close() }
        try await client.withFile(
            filePath: remotePath,
            flags: [.write, .create, .truncate]
        ) { remote in
            var offset: UInt64 = 0
            while let data = try local.read(upToCount: 256 * 1024), !data.isEmpty {
                try Task.checkCancellation()
                try await remote.write(ByteBuffer(bytes: data), at: offset)
                offset += UInt64(data.count)
                Self.publishProgress(
                    transferred: Int64(offset),
                    total: total,
                    started: started,
                    onProgress: onProgress
                )
            }
        }
    }

    func download(
        remotePath: String,
        size: Int64,
        to localURL: URL,
        onProgress: (@Sendable (SFTPProgress) -> Void)?
    ) async throws {
        try ensureOpen()
        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        let local = try FileHandle(forWritingTo: localURL)
        defer { try? local.close() }
        let started = Date()
        try await client.withFile(filePath: remotePath, flags: .read) { remote in
            var offset: UInt64 = 0
            while true {
                try Task.checkCancellation()
                let chunk = try await remote.read(from: offset, length: 256 * 1024)
                guard chunk.readableBytes > 0 else { break }
                let data = Data(chunk.readableBytesView)
                try local.write(contentsOf: data)
                offset += UInt64(data.count)
                Self.publishProgress(
                    transferred: Int64(offset),
                    total: size,
                    started: started,
                    onProgress: onProgress
                )
            }
        }
    }

    func cancelCurrentOperation() async {
        // Upload/download loops check Task cancellation between bounded chunks.
        // The caller owns the operation task so unrelated SFTP work is unaffected.
    }

    func close() async {
        guard !closed else { return }
        closed = true
        try? await client.close()
    }

    private func ensureOpen() throws {
        guard !closed else { throw RemoteConnectionFailure.sessionClosed }
    }

    private func validate(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), trimmed != ".", trimmed != ".." else {
            throw SFTPError.invalidName
        }
    }

    private static func publishProgress(
        transferred: Int64,
        total: Int64,
        started: Date,
        onProgress: (@Sendable (SFTPProgress) -> Void)?
    ) {
        guard let onProgress else { return }
        let elapsed = max(0.1, Date().timeIntervalSince(started))
        let speed = Double(transferred) / elapsed
        onProgress(
            SFTPProgress(
                transferredBytes: transferred,
                totalBytes: total,
                speedBytesPerSecond: speed,
                remaining: speed > 0 ? Double(max(0, total - transferred)) / speed : 0,
                message: "已传输 \(DisplayFormat.bytes(Double(transferred)))"
            )
        )
    }
}
