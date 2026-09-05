import Foundation

struct PlatformCapabilities: Sendable, Equatable {
    let interactiveShell: Bool
    let remoteCommand: Bool
    let fileTransfer: Bool
    let localForward: Bool
    let remoteForward: Bool
    let dynamicForward: Bool
    let jumpHosts: Bool
    let socks5Proxy: Bool
    let httpConnectProxy: Bool
    let sshAgent: Bool
    let externalPrivateKeyPath: Bool

    static let macOS = PlatformCapabilities(
        interactiveShell: true,
        remoteCommand: true,
        fileTransfer: true,
        localForward: true,
        remoteForward: true,
        dynamicForward: true,
        jumpHosts: true,
        socks5Proxy: true,
        httpConnectProxy: true,
        sshAgent: true,
        externalPrivateKeyPath: true
    )

    static let mobile = PlatformCapabilities(
        interactiveShell: true,
        remoteCommand: true,
        fileTransfer: true,
        localForward: false,
        remoteForward: false,
        dynamicForward: false,
        jumpHosts: false,
        socks5Proxy: false,
        httpConnectProxy: false,
        sshAgent: false,
        externalPrivateKeyPath: false
    )

    static var current: PlatformCapabilities {
#if os(macOS)
        .macOS
#else
        .mobile
#endif
    }
}

struct RemoteCommandResult: Sendable, Equatable {
    let stdout: Data
    let stderr: Data
    let exitCode: Int?

    var output: String { String(decoding: stdout, as: UTF8.self) }
    var errorOutput: String { String(decoding: stderr, as: UTF8.self) }
}

struct RemoteShellDimensions: Sendable, Equatable {
    var columns: Int
    var rows: Int
    var pixelWidth: Int
    var pixelHeight: Int

    static let standard = RemoteShellDimensions(
        columns: 80,
        rows: 24,
        pixelWidth: 0,
        pixelHeight: 0
    )

    var normalized: RemoteShellDimensions {
        RemoteShellDimensions(
            columns: max(2, columns),
            rows: max(2, rows),
            pixelWidth: max(0, pixelWidth),
            pixelHeight: max(0, pixelHeight)
        )
    }
}

struct RemoteHostKeyPresentation: Sendable, Equatable {
    let host: String
    let port: Int
    let algorithm: String
    let keyBlob: Data

    var fingerprint: String {
        TrustedHostStore.fingerprint(algorithm: algorithm, keyBlob: keyBlob)
    }

    var keyLine: String {
        let lookup = port == 22 ? host : "[\(host)]:\(port)"
        return "\(lookup) \(algorithm) \(keyBlob.base64EncodedString())"
    }

    var probe: SSHHostKeyProbe {
        SSHHostKeyProbe(
            host: host,
            port: port,
            algorithm: TrustedHostStore.algorithmDisplayName(algorithm),
            fingerprint: fingerprint,
            keyLine: keyLine
        )
    }
}

enum RemoteHostTrustDecision: Sendable, Equatable {
    case trustOnce
    case trustAndStore
    case reject
}

typealias RemoteHostTrustHandler = @Sendable (
    RemoteHostKeyPresentation
) async throws -> RemoteHostTrustDecision

protocol RemoteConnectionEngine: Sendable {
    var capabilities: PlatformCapabilities { get }

    func connect(
        _ config: ServerConnectionConfig,
        trustHandler: @escaping RemoteHostTrustHandler
    ) async throws -> any RemoteSession
}

protocol RemoteSession: Sendable {
    func execute(
        _ command: String,
        timeout: TimeInterval,
        maxOutputBytes: Int
    ) async throws -> RemoteCommandResult

    func openShell(
        dimensions: RemoteShellDimensions
    ) async throws -> any RemoteShellSession

    func openSFTP() async throws -> any RemoteFileClient
    func close() async
}

protocol RemoteShellSession: Sendable {
    var events: AsyncThrowingStream<Data, Error> { get }

    func write(_ data: Data) async throws
    func resize(_ dimensions: RemoteShellDimensions) async throws
    func close() async
}

protocol RemoteFileClient: Sendable {
    func list(path: String) async throws -> SFTPDirectoryListing
    func createDirectory(named name: String, in path: String) async throws
    func createFile(named name: String, in path: String) async throws
    func rename(_ item: RemoteFileItem, to newName: String) async throws
    func move(_ item: RemoteFileItem, to directory: String) async throws
    func delete(_ item: RemoteFileItem, recursive: Bool) async throws
    func upload(
        localURL: URL,
        to remotePath: String,
        onProgress: (@Sendable (SFTPProgress) -> Void)?
    ) async throws
    func download(
        remotePath: String,
        size: Int64,
        to localURL: URL,
        onProgress: (@Sendable (SFTPProgress) -> Void)?
    ) async throws
    /// Cancels work owned by the calling task. Implementations may additionally
    /// tear down protocol-level state when cancellation cannot interrupt an I/O wait.
    func cancelCurrentOperation() async
    func close() async
}

enum RemoteConnectionFailure: LocalizedError, Sendable, Equatable {
    case unsupported(String)
    case indirectRouteUnsupported
    case missingCredential
    case invalidPrivateKey
    case hostKeyRejected
    case sessionClosed
    case outputLimitExceeded
    case timedOut
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let feature): "当前平台暂不支持\(feature)。"
        case .indirectRouteUnsupported: "iPhone 与 iPad 首版仅支持直接 SSH 连接。"
        case .missingCredential: "本机 Keychain 中缺少连接凭据。"
        case .invalidPrivateKey: "私钥格式或口令无效；支持导入 OpenSSH Ed25519 与 RSA 私钥。"
        case .hostKeyRejected: "主机密钥未被信任，连接已关闭。"
        case .sessionClosed: "SSH 会话已关闭。"
        case .outputLimitExceeded: "远程输出超过安全上限。"
        case .timedOut: "连接或命令执行超时。"
        case .transport(let detail): detail.isEmpty ? "SSH 连接失败。" : detail
        }
    }
}
