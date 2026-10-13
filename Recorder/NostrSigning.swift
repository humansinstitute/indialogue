import Foundation
import CryptoKit
import P256K

struct NostrEvent: Codable {
    let id: String
    let pubkey: String
    let created_at: Int
    let kind: Int
    let tags: [[String]]
    let content: String
    let sig: String
}
extension Data { var hex: String { map { String(format: "%02x", $0) }.joined() } }
enum NostrCodec {
    static func hash(_ bytes: Data) -> String { Data(SHA256.hash(data: bytes)).hex }
    static func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    static let alphabet = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
    static func npub(_ bytes: Data) -> String {
        var words: [UInt32] = []; var accumulator: UInt32 = 0; var bits = 0
        for byte in bytes { accumulator = ((accumulator << 8) | UInt32(byte)) & 0xffff; bits += 8
            while bits >= 5 { bits -= 5; words.append((accumulator >> bits) & 31) }
        }
        if bits > 0 { words.append((accumulator << (5 - bits)) & 31) }
        let hrp = Array("npub".utf8)
        var checksum: UInt32 = 1
        for v in hrp.map({ UInt32($0 >> 5) }) + [0] + hrp.map({ UInt32($0 & 31) }) + words + [UInt32](repeating: 0, count: 6) {
            let top = checksum >> 25; checksum = ((checksum & 0x1ffffff) << 5) ^ v
            for (i, g) in [UInt32(0x3b6a57b2),0x26508e6d,0x1ea119fa,0x3d4233dd,0x2a1462b3].enumerated() where ((top >> i) & 1) != 0 { checksum ^= g }
        }
        checksum ^= 1
        let tail: [UInt32] = (0..<6).map { (checksum >> (5 * (5 - $0))) & 31 }
        let encoded = (words + tail).map { String(alphabet[Int($0)]) }.joined()
        return "npub1" + encoded
    }
    static func validNpub(_ value: String) -> Bool {
        guard value.hasPrefix("npub1"), value.count == 63, value == value.lowercased() else { return false }
        // Same Bech32 checksum validation as nsec; scalar range is irrelevant to public keys.
        let hrp = Array("npub".utf8); var checksum: UInt32 = 1
        var words: [UInt32] = []
        for c in value.dropFirst(5) { guard let i = alphabet.firstIndex(of: c) else { return false }; words.append(UInt32(i)) }
        for v in hrp.map({ UInt32($0 >> 5) }) + [0] + hrp.map({ UInt32($0 & 31) }) + words {
            let top = checksum >> 25; checksum = ((checksum & 0x1ffffff) << 5) ^ v
            for (i,g) in [UInt32(0x3b6a57b2),0x26508e6d,0x1ea119fa,0x3d4233dd,0x2a1462b3].enumerated() where ((top >> i) & 1) != 0 { checksum ^= g }
        }
        return checksum == 1 && (words[51] & 15) == 0
    }
}
