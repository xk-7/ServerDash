import CryptoKit
import Foundation
import Security

enum RDPCredentials {
    static let service: String = {
#if SERVERDASH_MAC_QA
        "com.serverdash.app.macqa.rdp.credentials"
#else
        "com.serverdash.rdp.credentials"
#endif
    }()
    static func read(_ id: UUID) throws -> String? {
        var query = base(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = item as? Data, let password = String(data: data, encoding: .utf8) else { throw KeychainError.invalidData }
        return password
    }
    static func save(_ password: String, id: UUID) throws {
        let query = base(id)
        let attributes: [String: Any] = [kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false]
        let status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }
    static func delete(_ id: UUID) throws {
        let status = SecItemDelete(base(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.unexpectedStatus(status) }
    }
    private static func base(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }
}

struct RDPCertificateEvidence: Equatable, Sendable {
    var fingerprint: String
    var subject: String
    var systemTrusted: Bool
    var expires: Date
}

enum RDPCertificateError: LocalizedError {
    case malformed, expired, denied, changed
    var errorDescription: String? { switch self {
    case .malformed: "RDP 证书损坏或格式无效，连接已拒绝。"
    case .expired: "RDP 证书已过期或尚未生效，连接已拒绝。"
    case .denied: "RDP 证书未获信任，连接已取消。"
    case .changed: "RDP 证书已变化，需要重新核对指纹。"
    } }
}

enum RDPCertificateVerifier {
    static func inspect(pem: Data, host: String, now: Date = .now) throws -> RDPCertificateEvidence {
        let certificates = try uniqueCertificates(parseCertificates(pem))
        let leaf = certificates[0]
        let (start, expires) = try validity(of: leaf)
        guard now >= start, now <= expires else { throw RDPCertificateError.expired }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certificates as CFArray, SecPolicyCreateSSL(true, host as CFString), &trust) == errSecSuccess,
              let trust else { throw RDPCertificateError.malformed }
        SecTrustSetNetworkFetchAllowed(trust, false)
        SecTrustSetVerifyDate(trust, now as CFDate)
        let trusted = SecTrustEvaluateWithError(trust, nil)
        // FreeRDP hands over leaf+chain PEM. Windows RDP certs are usually self-issued
        // and presented to an IP, so system SSL trust fails and TOFU must use the leaf.
        guard trusted || SDRDPCertificateChainIsSelfIssued(pem) else { throw RDPCertificateError.malformed }
        let der = SecCertificateCopyData(leaf) as Data
        let fingerprint = SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
        return RDPCertificateEvidence(fingerprint: fingerprint, subject: SecCertificateCopySubjectSummary(leaf) as String? ?? "未知",
            systemTrusted: trusted, expires: expires)
    }

    private static func parseCertificates(_ pem: Data) throws -> [SecCertificate] {
        guard (1...1_048_576).contains(pem.count) else { throw RDPCertificateError.malformed }
        var bytes = pem
        while bytes.last == 0 { bytes.removeLast() }
        guard !bytes.isEmpty else { throw RDPCertificateError.malformed }
        if let text = String(data: bytes, encoding: .utf8) {
            let blocks = text.components(separatedBy: "-----BEGIN CERTIFICATE-----").dropFirst()
            if !blocks.isEmpty {
                guard blocks.count <= 32 else { throw RDPCertificateError.malformed }
                return try blocks.map { block in
                    guard let end = block.range(of: "-----END CERTIFICATE-----") else { throw RDPCertificateError.malformed }
                    let base64 = block[..<end.lowerBound].filter { !$0.isWhitespace }
                    guard let der = Data(base64Encoded: base64), let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
                        throw RDPCertificateError.malformed
                    }
                    return certificate
                }
            }
        }
        guard let certificate = SecCertificateCreateWithData(nil, bytes as CFData) else { throw RDPCertificateError.malformed }
        return [certificate]
    }

    private static func uniqueCertificates(_ certificates: [SecCertificate]) throws -> [SecCertificate] {
        var seen = Set<Data>()
        let unique = certificates.filter { seen.insert(SecCertificateCopyData($0) as Data).inserted }
        guard !unique.isEmpty else { throw RDPCertificateError.malformed }
        return unique
    }

    private static func validity(of certificate: SecCertificate) throws -> (Date, Date) {
        let keys = [kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter] as CFArray
        guard let values = SecCertificateCopyValues(certificate, keys, nil) as? [CFString: Any] else {
            throw RDPCertificateError.malformed
        }
        return (try validityDate(values, oid: kSecOIDX509V1ValidityNotBefore),
                try validityDate(values, oid: kSecOIDX509V1ValidityNotAfter))
    }

    private static func validityDate(_ values: [CFString: Any], oid: CFString) throws -> Date {
        guard let property = values[oid] as? [CFString: Any] else { throw RDPCertificateError.malformed }
        let value = property[kSecPropertyKeyValue]
        if let number = value as? NSNumber { return Date(timeIntervalSinceReferenceDate: number.doubleValue) }
        if let date = value as? Date { return date }
        throw RDPCertificateError.malformed
    }
}

/// Pin storage contains public fingerprints only. It is independent of SSH trusted hosts.
final class RDPCertificatePins: @unchecked Sendable {
    static let shared = RDPCertificatePins()
    private let defaults: UserDefaults
    private let lock = NSLock()
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func fingerprint(host: String, port: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        return defaults.string(forKey: key(host, port))
    }
    func save(_ fingerprint: String, host: String, port: Int) {
        lock.lock(); defer { lock.unlock() }
        defaults.set(fingerprint, forKey: key(host, port))
    }
    private func key(_ host: String, _ port: Int) -> String {
        "rdp.certificate.v1." + SHA256.hash(data: Data("\(host.lowercased()):\(port)".utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// A cancelled connection releases a worker waiting on the main-thread certificate prompt.
final class RDPTrustGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var result: Bool?
    func resolve(_ value: Bool) { condition.lock(); if result == nil { result = value }; condition.broadcast(); condition.unlock() }
    func wait() -> Bool {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: 120)
        while result == nil { if !condition.wait(until: deadline) { result = false } }
        return result == true
    }
}
