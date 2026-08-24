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

    static func algorithmDisplayName(_ algorithm: String) -> String {
        switch algorithm {
        case "ssh-ed25519": "ED25519"
        case "ecdsa-sha2-nistp256": "ECDSA"
        case "ssh-rsa": "RSA"
        default: algorithm
        }
    }

    static func hostMarkers(_ host: String, port: Int) -> Set<String> {
        [host, "[\(host)]:\(port)", "[\(host)]:22"]
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
    }

    static func inspect(_ config: ServerConnectionConfig) async throws -> HostTrustDecision {
        try await Task.detached(priority: .utility) {
            let stored = existingKeys(host: config.host, port: config.port)
            let probe = try scan(
                host: config.host,
                port: config.port,
                preferredAlgorithm: stored.first?.algorithm
            )
            if stored.isEmpty {
                if allKeys().contains(where: { $0.fingerprint == probe.fingerprint }) {
                    return HostTrustDecision.trusted(probe)
                }
                return PrivacySettings.confirmHostFingerprint ? .unknown(probe) : .trusted(probe)
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
        var names = Set(String(fields[0]).split(separator: ",").map(String.init))
        names.formUnion(hostMarkers(host, port: port))
        let ordered = [host] + names.filter { $0 != host }.sorted()
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
            if markers.contains(String(name)) {
                return true
            }
            let hostOnly = String(name)
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                .split(separator: ":")
                .first
                .map(String.init) ?? String(name)
            return hostOnly.caseInsensitiveCompare(host) == .orderedSame
        }
    }

    private static func keysFromKeygen(host: String, port: Int) -> [(algorithm: String, fingerprint: String, line: String)] {
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
    }

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
}

enum HostTrustDecision: Sendable {
    case trusted(SSHHostKeyProbe)
    case unknown(SSHHostKeyProbe)
    case changed(oldFingerprint: String, probe: SSHHostKeyProbe)
}
