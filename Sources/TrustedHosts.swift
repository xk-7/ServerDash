import CryptoKit
import Foundation
import SwiftData

@Model
final class TrustedHostKey {
    @Attribute(.unique) var id: UUID
    var host: String
    var port: Int
    var algorithm: String
    var fingerprint: String
    var keyLine: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        host: String,
        port: Int,
        algorithm: String,
        fingerprint: String,
        keyLine: String,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.host = host
        self.port = port
        self.algorithm = algorithm
        self.fingerprint = fingerprint
        self.keyLine = keyLine
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var lookupHost: String {
        port == 22 ? host : "[\(host)]:\(port)"
    }
}

enum TrustedHostStore {
    static var knownHostsURL: URL = {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ServerDash", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("known_hosts")
    }()

    static func fingerprint(for keyLine: String) -> String? {
        let fields = keyLine.split(separator: " ")
        guard fields.count >= 3, let keyData = Data(base64Encoded: String(fields[2])) else {
            return nil
        }
        let digest = SHA256.hash(data: keyData)
        return "SHA256:" + Data(digest)
            .base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
    }

    static func fingerprint(algorithm: String, keyBlob: Data) -> String {
        _ = algorithm
        let digest = SHA256.hash(data: keyBlob)
        return "SHA256:" + Data(digest)
            .base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
    }

    static func algorithmDisplayName(_ algorithm: String) -> String {
        switch algorithm {
        case "ssh-ed25519": "ED25519"
        case "ecdsa-sha2-nistp256": "ECDSA"
        case "ssh-rsa": "RSA"
        default: algorithm
        }
    }

    static func hostMarkers(_ host: String, port: Int) -> Set<String> {
        if port == 22 {
            return [host, "[\(host)]:22"]
        }
        return ["[\(host)]:\(port)"]
    }

    static func existingKeys(host: String, port: Int) -> [(algorithm: String, fingerprint: String, line: String)] {
        guard let contents = try? String(contentsOf: knownHostsURL, encoding: .utf8) else {
            return []
        }
        let parsed = contents
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .compactMap { line -> (algorithm: String, fingerprint: String, line: String)? in
                guard matches(host: host, port: port, line: line) else { return nil }
                return parsedKey(from: line)
            }
        if !parsed.isEmpty {
            return parsed
        }
        return keysFromKeygen(host: host, port: port)
    }

    static func allKeys() -> [(algorithm: String, fingerprint: String, line: String)] {
        guard let contents = try? String(contentsOf: knownHostsURL, encoding: .utf8) else {
            return []
        }
        return contents
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .compactMap(parsedKey(from:))
    }

    static func existingFingerprint(host: String, port: Int) -> String? {
        existingKeys(host: host, port: port).first?.fingerprint
    }

    static func hasUsableHostName(host: String, port: Int) -> Bool {
        let expected = port == 22 ? host : "[\(host)]:\(port)"
        return existingKeys(host: host, port: port).contains { key in
            let names = key.line.split(separator: " ").first.map(String.init)?
                .split(separator: ",").map(String.init) ?? []
            return names.contains(expected)
        }
    }

    static func scan(host: String, port: Int, preferredAlgorithm: String? = nil) throws -> SSHHostKeyProbe {
#if os(macOS)
        let interval = PerformanceTrace.begin(.hostKeyScan)
        defer { PerformanceTrace.end(interval) }
        let scan = run(
            "/usr/bin/ssh-keyscan",
            ["-T", "8", "-p", String(port), host]
        )
        let validLines = scan.output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { line in
                !line.hasPrefix("#") && line.split(separator: " ").count >= 3
            }
        func algorithm(of line: String) -> String? {
            line.split(separator: " ").dropFirst().first.map(String.init)
        }
        guard let preferred = validLines.first(where: {
            algorithm(of: $0) == preferredAlgorithm
        }) ?? validLines.first(where: {
            algorithm(of: $0) == "ssh-ed25519"
        }) ?? validLines.first else {
            throw SSHValidationError.hostKeyUnavailable(scan.error)
        }
        let fields = preferred.split(separator: " ")
        guard fields.count >= 3, let digest = fingerprint(for: preferred) else {
            throw SSHValidationError.invalidHostKey
        }
        return SSHHostKeyProbe(
            host: host,
            port: port,
            algorithm: algorithmDisplayName(String(fields[1])),
            fingerprint: digest,
            keyLine: preferred,
            additionalKeyLines: validLines.filter { $0 != preferred }
        )
#else
        _ = preferredAlgorithm
        throw SSHValidationError.hostKeyUnavailable(
            "移动端会在 SSH 握手中直接获取并验证主机密钥。"
        )
#endif
    }

    static func inspect(
        _ config: ServerConnectionConfig,
        forceScan: Bool = false
    ) async throws -> HostTrustDecision {
        try await inspect(config, forceScan: forceScan) { host, port, preferredAlgorithm in
            try scan(host: host, port: port, preferredAlgorithm: preferredAlgorithm)
        }
    }

    static func inspect(
        _ config: ServerConnectionConfig,
        forceScan: Bool,
        scanProvider: @escaping @Sendable (String, Int, String?) throws -> SSHHostKeyProbe
    ) async throws -> HostTrustDecision {
        let interval = PerformanceTrace.begin(.hostKeyInspect)
        defer { PerformanceTrace.end(interval) }
        return try await Task.detached(priority: .utility) {
            let stored = existingKeys(host: config.host, port: config.port)
            if !forceScan, let probe = probeFromStoredKeys(
                stored,
                host: config.host,
                port: config.port
            ) {
                return HostTrustDecision.trusted(probe)
            }

            let probe = try scanProvider(
                config.host,
                config.port,
                stored.first?.algorithm
            )
            if stored.isEmpty {
                // A key is trusted for a normalized host and port, not globally by fingerprint.
                // Reusing the same key on another endpoint still requires an explicit decision.
                return .unknown(probe)
            }
            if let matching = stored.first(where: { $0.algorithm == rawAlgorithm(from: probe) })
                ?? stored.first(where: { $0.fingerprint == probe.fingerprint }) {
                if matching.fingerprint == probe.fingerprint {
                    return HostTrustDecision.trusted(probe)
                }
                return .changed(oldFingerprint: matching.fingerprint, probe: probe)
            }
            return .changed(oldFingerprint: stored[0].fingerprint, probe: probe)
        }.value
    }

    private static func probeFromStoredKeys(
        _ stored: [(algorithm: String, fingerprint: String, line: String)],
        host: String,
        port: Int
    ) -> SSHHostKeyProbe? {
        guard let primary = stored.first else { return nil }
        return SSHHostKeyProbe(
            host: host,
            port: port,
            algorithm: algorithmDisplayName(primary.algorithm),
            fingerprint: primary.fingerprint,
            keyLine: primary.line,
            additionalKeyLines: stored.dropFirst().map(\.line)
        )
    }

    static func rawAlgorithm(from probe: SSHHostKeyProbe) -> String {
        probe.keyLine.split(separator: " ").dropFirst().first.map(String.init) ?? probe.algorithm
    }

    static func trust(_ probe: SSHHostKeyProbe, replacing: Bool = false) throws {
        var contents = (try? String(contentsOf: knownHostsURL, encoding: .utf8)) ?? ""
        contents = contents
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !matches(host: probe.host, port: probe.port, line: $0) }
            .joined(separator: "\n")
        if !contents.isEmpty && !contents.hasSuffix("\n") {
            contents.append("\n")
        }
        var seen = Set<String>()
        for line in [probe.keyLine] + probe.additionalKeyLines {
            let normalized = normalizedKeyLine(line, host: probe.host, port: probe.port)
            guard seen.insert(normalized).inserted else { continue }
            contents.append(normalized)
            contents.append("\n")
        }
        _ = replacing
        try contents.write(to: knownHostsURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: knownHostsURL.path
        )
    }

    static func remove(host: String, port: Int) throws {
        guard FileManager.default.fileExists(atPath: knownHostsURL.path) else { return }
        let contents = try String(contentsOf: knownHostsURL, encoding: .utf8)
        let filtered = contents
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !matches(host: host, port: port, line: $0) }
            .joined(separator: "\n")
        try (filtered + (filtered.isEmpty ? "" : "\n"))
            .write(to: knownHostsURL, atomically: true, encoding: .utf8)
    }

    static func normalizedKeyLine(_ line: String, host: String, port: Int) -> String {
        let fields = line.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
        guard fields.count >= 3 else { return line }
        let primary = port == 22 ? host : "[\(host)]:\(port)"
        let markers = hostMarkers(host, port: port)
        let ordered = [primary] + markers.filter { $0 != primary }.sorted()
        return "\(ordered.joined(separator: ",")) \(fields[1]) \(fields[2])"
    }

    private static func parsedKey(from line: String) -> (algorithm: String, fingerprint: String, line: String)? {
        guard !line.hasPrefix("#") else { return nil }
        let fields = line.split(separator: " ")
        guard fields.count >= 3, let digest = fingerprint(for: line) else { return nil }
        return (String(fields[1]), digest, line)
    }

    private static func matches(host: String, port: Int, line: String) -> Bool {
        guard !line.hasPrefix("#"), let names = line.split(separator: " ").first else { return false }
        let markers = hostMarkers(host, port: port)
        return String(names).split(separator: ",").contains { name in
            markers.contains { marker in
                marker.caseInsensitiveCompare(String(name)) == .orderedSame
            }
        }
    }

    private static func keysFromKeygen(host: String, port: Int) -> [(algorithm: String, fingerprint: String, line: String)] {
#if os(macOS)
        hostMarkers(host, port: port).flatMap { lookup -> [(algorithm: String, fingerprint: String, line: String)] in
            let result = run(
                "/usr/bin/ssh-keygen",
                ["-F", lookup, "-f", knownHostsURL.path]
            )
            guard result.status == 0 else { return [] }
            return result.output
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .compactMap(parsedKey(from:))
        }
#else
        _ = host
        _ = port
        return []
#endif
    }

#if os(macOS)
    private static func run(_ executable: String, _ arguments: [String]) -> (
        status: Int32,
        output: String,
        error: String
    ) {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (-1, "", error.localizedDescription)
        }
        return (
            process.terminationStatus,
            String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
#endif
}

enum HostTrustDecision: Sendable {
    case trusted(SSHHostKeyProbe)
    case unknown(SSHHostKeyProbe)
    case changed(oldFingerprint: String, probe: SSHHostKeyProbe)
}

enum HostTrustSource: String, Sendable {
    case monitoring
    case terminal
    case sftp
    case sshTest
    case connectionRoute
    case tunnel

    var title: String {
        switch self {
        case .monitoring: "监控"
        case .terminal: "终端"
        case .sftp: "SFTP"
        case .sshTest: "SSH 测试"
        case .connectionRoute: "连接路线"
        case .tunnel: "SSH 隧道"
        }
    }
}

struct HostTrustRequest: Identifiable, Sendable {
    let id: UUID
    let config: ServerConnectionConfig
    let source: HostTrustSource
    let probe: SSHHostKeyProbe
    let replacing: Bool
    let oldFingerprint: String?
    let createdAt: Date

    var serverID: UUID { config.id }
}

@MainActor
final class HostTrustCoordinator {
    typealias Inspector = @Sendable (
        _ config: ServerConnectionConfig,
        _ forceScan: Bool
    ) async throws -> HostTrustDecision
    typealias Truster = @Sendable (
        _ probe: SSHHostKeyProbe,
        _ replacing: Bool
    ) async throws -> Void

    private struct QueuedRequest {
        let request: HostTrustRequest
        let continuation: CheckedContinuation<Void, Error>
    }

    private(set) var current: HostTrustRequest?
    var currentDidChange: ((HostTrustRequest?) -> Void)?

    private var queue: [QueuedRequest] = []
    private let inspector: Inspector
    private let truster: Truster

    init(
        inspector: @escaping Inspector = { config, forceScan in
            try await SSHConnectionValidator.inspect(config, forceScan: forceScan)
        },
        truster: @escaping Truster = { probe, replacing in
            try await SSHConnectionValidator.trust(probe, replacing: replacing)
        }
    ) {
        self.inspector = inspector
        self.truster = truster
    }

    var queuedCount: Int { queue.count }

    func authorize(
        _ config: ServerConnectionConfig,
        source: HostTrustSource,
        forceScan: Bool = false
    ) async throws {
        try Task.checkCancellation()
        switch try await inspector(config, forceScan) {
        case .trusted(let probe):
            if !TrustedHostStore.hasUsableHostName(host: config.host, port: config.port) {
                try await truster(probe, false)
            }
        case .unknown(let probe):
            try await enqueue(
                config: config,
                source: source,
                probe: probe,
                replacing: false,
                oldFingerprint: nil
            )
        case .changed(let oldFingerprint, let probe):
            try await enqueue(
                config: config,
                source: source,
                probe: probe,
                replacing: true,
                oldFingerprint: oldFingerprint
            )
        }
    }

    func accept(_ requestID: UUID) async throws -> SSHHostKeyProbe? {
        guard queue.first?.request.id == requestID else { return nil }
        let item = queue.removeFirst()
        do {
            try await truster(item.request.probe, item.request.replacing)
            item.continuation.resume()
            resumeAlreadyTrustedRequests(matching: item.request.probe)
            publishNext()
            return item.request.probe
        } catch {
            item.continuation.resume(throwing: error)
            publishNext()
            throw error
        }
    }

    func reject(_ requestID: UUID) {
        cancel(requestID)
    }

    private func enqueue(
        config: ServerConnectionConfig,
        source: HostTrustSource,
        probe: SSHHostKeyProbe,
        replacing: Bool,
        oldFingerprint: String?
    ) async throws {
        let request = HostTrustRequest(
            id: UUID(),
            config: config,
            source: source,
            probe: probe,
            replacing: replacing,
            oldFingerprint: oldFingerprint,
            createdAt: .now
        )
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: ConnectionError.cancelled)
                    return
                }
                queue.append(QueuedRequest(request: request, continuation: continuation))
                if queue.count == 1 {
                    publishNext()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(request.id)
            }
        }
    }

    private func cancel(_ requestID: UUID) {
        guard let index = queue.firstIndex(where: { $0.request.id == requestID }) else { return }
        let wasCurrent = index == queue.startIndex
        let item = queue.remove(at: index)
        item.continuation.resume(throwing: ConnectionError.cancelled)
        if wasCurrent {
            publishNext()
        }
    }

    private func resumeAlreadyTrustedRequests(matching acceptedProbe: SSHHostKeyProbe) {
        var retained: [QueuedRequest] = []
        for item in queue {
            let request = item.request
            if request.config.host == acceptedProbe.host,
               request.config.port == acceptedProbe.port,
               request.probe.fingerprint == acceptedProbe.fingerprint {
                item.continuation.resume()
            } else {
                retained.append(item)
            }
        }
        queue = retained
    }

    private func publishNext() {
        current = queue.first?.request
        currentDidChange?(current)
    }
}
