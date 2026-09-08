import CryptoKit
import Foundation
import Security

enum RDPCredentials {
    static let service = "com.serverdash.rdp.credentials"
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
        guard pem.count <= 1024 * 1024, let text = String(data: pem, encoding: .utf8) else { throw RDPCertificateError.malformed }
        let blocks = text.components(separatedBy: "-----BEGIN CERTIFICATE-----").dropFirst()
        guard !blocks.isEmpty, blocks.count <= 32 else { throw RDPCertificateError.malformed }
        let certificates: [SecCertificate] = try blocks.map { block in
            guard let end = block.range(of: "-----END CERTIFICATE-----") else { throw RDPCertificateError.malformed }
            let base64 = block[..<end.lowerBound].filter { !$0.isWhitespace }
            guard let der = Data(base64Encoded: base64), let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
                throw RDPCertificateError.malformed
            }
            return certificate
        }
        let leaf = certificates[0]
        let keys = [kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter] as CFArray
        guard let values = SecCertificateCopyValues(leaf, keys, nil) as? [CFString: Any],
              let before = values[kSecOIDX509V1ValidityNotBefore] as? [CFString: Any],
              let after = values[kSecOIDX509V1ValidityNotAfter] as? [CFString: Any],
              let start = before[kSecPropertyKeyValue] as? NSNumber,
              let end = after[kSecPropertyKeyValue] as? NSNumber else { throw RDPCertificateError.malformed }
        let expires = Date(timeIntervalSinceReferenceDate: end.doubleValue)
        guard now >= Date(timeIntervalSinceReferenceDate: start.doubleValue), now <= expires else { throw RDPCertificateError.expired }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certificates as CFArray, SecPolicyCreateSSL(true, host as CFString), &trust) == errSecSuccess,
              let trust else { throw RDPCertificateError.malformed }
        SecTrustSetNetworkFetchAllowed(trust, false)
        SecTrustSetVerifyDate(trust, now as CFDate)
        let trusted = SecTrustEvaluateWithError(trust, nil)
        // Manual trust is for a correctly signed self-signed leaf, not arbitrary chain/signature failures.
        guard trusted || (certificates.count == 1 && SDRDPCertificateIsSelfSigned(pem)) else { throw RDPCertificateError.malformed }
        let der = SecCertificateCopyData(leaf) as Data
        let fingerprint = SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
        return RDPCertificateEvidence(fingerprint: fingerprint, subject: SecCertificateCopySubjectSummary(leaf) as String? ?? "未知",
            systemTrusted: trusted, expires: expires)
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
