import Foundation
import CryptoKit
import CommonCrypto
import Security
import SwiftUI
import P256K

enum VaultError: LocalizedError {
    case invalidNsec, invalidPIN, exists, unavailable, invalidVault
    var errorDescription: String? {
        switch self {
        case .invalidNsec: "Enter a valid Bech32 nsec with a 32-byte Nostr secret key."
        case .invalidPIN: "PIN must contain 4 to 12 digits."
        case .exists: "An identity already exists. Explicitly remove it before importing another."
        case .unavailable: "Recorder Keychain secret unavailable. Existing identity has been retained."
        case .invalidVault: "Incorrect PIN or damaged identity vault. Existing identity has been retained."
        }
    }
}

enum NsecValidation {
    static func decode(_ input: String) throws -> Data {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard input == input.lowercased() || input == input.uppercased() else { throw VaultError.invalidNsec }
        let value = input.lowercased()
        let alphabet = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
        guard value.hasPrefix("nsec1"), value.count == 63 else { throw VaultError.invalidNsec }
        let payload = try value.dropFirst(5).map { char -> UInt32 in
            guard let index = alphabet.firstIndex(of: char) else { throw VaultError.invalidNsec }
            return UInt32(index)
        }
        let hrp = Array("nsec".utf8)
        let expanded = hrp.map { UInt32($0 >> 5) } + [0] + hrp.map { UInt32($0 & 31) }
        let generators: [UInt32] = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
        var checksum: UInt32 = 1
        for v in expanded + payload {
            let top = checksum >> 25
            checksum = ((checksum & 0x1ffffff) << 5) ^ v
            for i in 0..<5 where ((top >> i) & 1) != 0 { checksum ^= generators[i] }
        }
        guard checksum == 1 else { throw VaultError.invalidNsec }
        var accumulator: UInt32 = 0; var bits = 0; var bytes = Data()
        for v in payload.dropLast(6) {
            accumulator = ((accumulator << 5) | v) & 0xffff
            bits += 5
            if bits >= 8 { bits -= 8; bytes.append(UInt8((accumulator >> bits) & 255)) }
        }
        guard bits < 5, ((accumulator << (8 - bits)) & 255) == 0, bytes.count == 32,
              bytes.contains(where: { $0 != 0 }) else { throw VaultError.invalidNsec }
        // secp256k1 scalar must be strictly below the curve order.
        let order: [UInt8] = [0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xfe,0xba,0xae,0xdc,0xe6,0xaf,0x48,0xa0,0x3b,0xbf,0xd2,0x5e,0x8c,0xd0,0x36,0x41,0x41]
        guard Array(bytes).lexicographicallyPrecedes(order) else { throw VaultError.invalidNsec }
        return bytes
    }
}

protocol VaultSecretStore {
    func read() throws -> Data?
    func write(_ data: Data) throws
}
struct RecorderKeychain: VaultSecretStore {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "studio.otherstuff.PeteRecorder.identity-vault.v1",
         kSecAttrAccount as String: "device-secret",
         kSecAttrSynchronizable as String: false]
    }
    func read() throws -> Data? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count == 32 else { throw VaultError.unavailable }
        return data
    }
    func write(_ data: Data) throws {
        var q = query; q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw VaultError.unavailable }
    }
}

/// Only the encrypted scalar goes to disk. The installation secret never leaves Keychain.
/// Signing stays inside the vault; transport only receives public identity and events.
final class IdentityVault {
    struct Envelope: Codable {
        var version = 1
        var iterations = 210_000
        let salt: Data
        var sealed: Data
    }
    let url: URL
    private let secrets: VaultSecretStore
    private var clear: Data?
    var isUnlocked: Bool { clear != nil }
    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }
    init(url: URL, secrets: VaultSecretStore = RecorderKeychain()) { self.url = url; self.secrets = secrets }
    private func random(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { throw VaultError.unavailable }
        return Data(bytes)
    }
    private func key(pin: String, secret: Data, salt: Data) throws -> SymmetricKey {
        guard pin.range(of: "^[0-9]{4,12}$", options: .regularExpression) != nil else { throw VaultError.invalidPIN }
        let password = Array((pin + ":" + secret.base64EncodedString()).utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = password.withUnsafeBytes { p in salt.withUnsafeBytes { s in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), p.baseAddress!.assumingMemoryBound(to: Int8.self), password.count,
                s.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 210_000, &derived, 32)
        } }
        guard status == kCCSuccess else { throw VaultError.unavailable }
        defer { _ = derived.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        return SymmetricKey(data: derived)
    }
    func create(nsec: String, pin: String) throws {
        guard !exists else { throw VaultError.exists }
        guard pin.range(of: "^[0-9]{4,12}$", options: .regularExpression) != nil else { throw VaultError.invalidPIN }
        var bytes = try NsecValidation.decode(nsec)
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        let secret: Data
        if let existing = try secrets.read() { secret = existing }
        else { let created = try random(32); try secrets.write(created); secret = created }
        let salt = try random(16)
        let sealed = try AES.GCM.seal(bytes, using: key(pin: pin, secret: secret, salt: salt))
        guard let combined = sealed.combined else { throw VaultError.invalidVault }
        let envelope = Envelope(salt: salt, sealed: combined)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var dir = url.deletingLastPathComponent(); var values = URLResourceValues(); values.isExcludedFromBackup = true; try dir.setResourceValues(values)
        guard !exists else { throw VaultError.exists }
        try JSONEncoder().encode(envelope).write(to: url, options: [.atomic, .completeFileProtection])
        clear = bytes
    }
    func unlock(pin: String) throws {
        lock()
        guard let secret = try secrets.read() else { throw VaultError.unavailable }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
            guard envelope.version == 1, envelope.iterations == 210_000, envelope.salt.count == 16 else { throw VaultError.invalidVault }
            let opened = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.sealed), using: key(pin: pin, secret: secret, salt: envelope.salt))
            guard opened.count == 32 else { throw VaultError.invalidVault }
            clear = opened
        } catch { throw VaultError.invalidVault }
    }
    func lock() { if clear != nil { clear!.resetBytes(in: 0..<clear!.count) }; clear = nil }
    func signerNpub() throws -> String {
        guard let clear else { throw VaultError.unavailable }
        let key = try P256K.Schnorr.PrivateKey(dataRepresentation: clear)
        return NostrCodec.npub(Data(key.xonly.bytes))
    }
    func sign(kind: Int, tags: [[String]], content: String, createdAt: Int = Int(Date().timeIntervalSince1970)) throws -> NostrEvent {
        guard let clear else { throw VaultError.unavailable }
        let key = try P256K.Schnorr.PrivateKey(dataRepresentation: clear)
        let pubkey = Data(key.xonly.bytes).hex
        let serialized = try NostrCodec.json([0, pubkey, createdAt, kind, tags, content])
        var digest = Array(SHA256.hash(data: serialized))
        var auxiliary = [UInt8](try random(32))
        defer { _ = auxiliary.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }; _ = digest.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        let signature = try key.signature(message: &digest, auxiliaryRand: &auxiliary)
        return NostrEvent(id: NostrCodec.hash(serialized), pubkey: pubkey, created_at: createdAt, kind: kind, tags: tags, content: content, sig: Data(signature.dataRepresentation).hex)
    }
    func remove() throws {
        lock()
        if exists { try FileManager.default.removeItem(at: url) }
        // Keep this per-install secret; remove only the explicitly selected identity.
    }
}

@MainActor
final class IdentityModel: ObservableObject {
    @Published private(set) var exists = false
    @Published private(set) var unlocked = false
    @Published var notice: String?
    private let vault: IdentityVault?
    @Published private(set) var npub: String?
    init() {
        let root = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        vault = root.map { IdentityVault(url: $0.appendingPathComponent("Identity/vault.json")) }
        exists = vault?.exists == true
    }
    func perform(_ operation: (IdentityVault) throws -> Void) {
        guard let vault else { notice = "Identity storage unavailable."; return }
        do { try operation(vault); notice = nil } catch { notice = error.localizedDescription }
        exists = vault.exists; unlocked = vault.isUnlocked; npub = try? vault.signerNpub()
    }
    func lock() { vault?.lock(); unlocked = false; npub = nil }
    func sign(kind: Int, tags: [[String]], content: String) throws -> NostrEvent {
        guard let vault else { throw VaultError.unavailable }
        return try vault.sign(kind: kind, tags: tags, content: content)
    }
}
