import CryptoKit
import Foundation
import Security

public protocol AgreementKey: Sendable {
    /// 65-byte uncompressed P-256 point.
    var publicKey: Data { get }
    /// Raw ECDH shared secret (x coordinate, 32 bytes) with `peer` (65-byte point).
    func sharedSecret(with peer: Data) throws -> Data
}

public protocol SigningKey: Sendable {
    var publicKey: Data { get }
    /// ECDSA P-256 / SHA-256, raw r‖s (64 bytes).
    func sign(_ data: Data) throws -> Data
}

// MARK: Software keys (tests, simulator)

public struct SoftwareAgreementKey: AgreementKey {
    let key: P256.KeyAgreement.PrivateKey
    public init(_ key: P256.KeyAgreement.PrivateKey = .init()) { self.key = key }
    public var publicKey: Data { key.publicKey.x963Representation }
    public func sharedSecret(with peer: Data) throws -> Data {
        try key.sharedSecretFromKeyAgreement(with: .init(x963Representation: peer)).withUnsafeBytes { Data($0) }
    }
}

public struct SoftwareSigningKey: SigningKey {
    let key: P256.Signing.PrivateKey
    public init(_ key: P256.Signing.PrivateKey = .init()) { self.key = key }
    public var publicKey: Data { key.publicKey.x963Representation }
    public func sign(_ data: Data) throws -> Data { try key.signature(for: data).rawRepresentation }
}

// MARK: Secure Enclave keys

public struct EnclaveAgreementKey: AgreementKey {
    let key: SecureEnclave.P256.KeyAgreement.PrivateKey
    public var publicKey: Data { key.publicKey.x963Representation }
    public func sharedSecret(with peer: Data) throws -> Data {
        try key.sharedSecretFromKeyAgreement(with: .init(x963Representation: peer)).withUnsafeBytes { Data($0) }
    }
}

public struct EnclaveSigningKey: SigningKey {
    let key: SecureEnclave.P256.Signing.PrivateKey
    public var publicKey: Data { key.publicKey.x963Representation }
    public func sign(_ data: Data) throws -> Data { try key.signature(for: data).rawRepresentation }
}

// MARK: Device identity

/// This device's two long-lived keys. On hardware they live in the Secure Enclave;
/// only the SE-wrapped `dataRepresentation` (useless off this device) is stored in
/// the shared keychain group so the app and its extensions can all use them.
public struct DeviceKeys: Sendable {
    public let agreement: any AgreementKey
    public let signing: any SigningKey

    public static func loadOrCreate(accessGroup: String?) throws -> DeviceKeys {
        let store = KeychainStore(accessGroup: accessGroup)
        if SecureEnclave.isAvailable {
            let ka = try store.loadOrCreate("ka.se") { try SecureEnclave.P256.KeyAgreement.PrivateKey().dataRepresentation }
            let ks = try store.loadOrCreate("ks.se") { try SecureEnclave.P256.Signing.PrivateKey().dataRepresentation }
            return DeviceKeys(
                agreement: EnclaveAgreementKey(key: try .init(dataRepresentation: ka)),
                signing: EnclaveSigningKey(key: try .init(dataRepresentation: ks)))
        }
        // Simulator: no Secure Enclave. Software keys in the keychain — development only.
        let ka = try store.loadOrCreate("ka.sw") { P256.KeyAgreement.PrivateKey().rawRepresentation }
        let ks = try store.loadOrCreate("ks.sw") { P256.Signing.PrivateKey().rawRepresentation }
        return DeviceKeys(
            agreement: SoftwareAgreementKey(try .init(rawRepresentation: ka)),
            signing: SoftwareSigningKey(try .init(rawRepresentation: ks)))
    }
}

struct KeychainStore {
    let accessGroup: String?
    let service = "teleport.keys"

    struct Failure: Error { let status: OSStatus }

    #if os(macOS)
    /// Prefer the modern (iOS-style) keychain on macOS; it needs a signed app with an
    /// application identifier, so fall back to the login keychain if that's missing.
    nonisolated(unsafe) static var useDataProtection = true
    #endif

    private func baseQuery(_ account: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        #if os(macOS)
        if Self.useDataProtection { q[kSecUseDataProtectionKeychain as String] = true }
        #endif
        return q
    }

    func loadOrCreate(_ account: String, create: () throws -> Data) throws -> Data {
        var q = baseQuery(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        #if os(macOS)
        if status == errSecMissingEntitlement, Self.useDataProtection {
            Self.useDataProtection = false
            return try loadOrCreate(account, create: create)
        }
        #endif
        if status == errSecSuccess, let data = out as? Data { return data }
        guard status == errSecItemNotFound else { throw Failure(status: status) }

        let data = try create()
        var add = baseQuery(account)
        add[kSecValueData as String] = data
        // Readable by the NSE while the phone is locked (after first unlock), never synced or backed up.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw Failure(status: addStatus) }
        return data
    }
}
