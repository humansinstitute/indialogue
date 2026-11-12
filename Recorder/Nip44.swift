import CryptoKit
import Foundation
import Security

enum NIP44 {
  static func hmac(_ key: Data, _ data: Data) -> Data {
    Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
  }
  static func keys(_ key: Data, _ nonce: Data) -> Data {
    var result = Data()
    var last = Data()
    for i in 1...3 {
      last = hmac(key, last + nonce + Data([UInt8(i)]))
      result += last
    }
    return result.prefix(76)
  }
  static func paddedLength(_ size: Int) -> Int {
    if size <= 32 { return 32 }
    let next = 1 << (Int.bitWidth - (size - 1).leadingZeroBitCount)
    let chunk = next <= 256 ? 32 : next / 8
    return chunk * ((size - 1) / chunk + 1)
  }
  static func encrypt(_ plaintext: Data, key: Data, nonce: Data? = nil) throws -> String {
    guard (1...16 * 1024 * 1024).contains(plaintext.count), key.count == 32 else {
      throw DiscoveryError.invalid("Invalid encrypted payload size.")
    }
    let nonce = try nonce ?? discoveryRandom(32)
    guard nonce.count == 32 else { throw DiscoveryError.invalid("Invalid encryption nonce.") }
    let size = plaintext.count
    let prefix =
      size >= 65536
      ? Data([
        0, 0, UInt8(truncatingIfNeeded: size >> 24), UInt8(truncatingIfNeeded: size >> 16),
        UInt8(truncatingIfNeeded: size >> 8), UInt8(truncatingIfNeeded: size),
      ]) : Data([UInt8(size >> 8), UInt8(size & 255)])
    var padded = prefix + plaintext
    padded += Data(repeating: 0, count: paddedLength(size) - size)
    let material = keys(key, nonce)
    let cipher = chacha(padded, key: material.prefix(32), nonce: material.subdata(in: 32..<44))
    return (Data([2]) + nonce + cipher + hmac(material.suffix(32), nonce + cipher))
      .base64EncodedString()
  }
  static func decrypt(_ payload: String, key: Data) throws -> Data {
    guard payload.utf8.count <= 24 * 1024 * 1024, let data = Data(base64Encoded: payload),
      data.count >= 99, data.first == 2, key.count == 32
    else { throw DiscoveryError.invalid("Invalid NIP-44 payload.") }
    let nonce = data.subdata(in: 1..<33)
    let cipher = data.subdata(in: 33..<(data.count - 32))
    let material = keys(key, nonce)
    let expected = hmac(material.suffix(32), nonce + cipher)
    let actual = data.suffix(32)
    guard zip(expected, actual).reduce(UInt8(0), { $0 | ($1.0 ^ $1.1) }) == 0 else {
      throw DiscoveryError.invalid("Encrypted payload authentication failed.")
    }
    let padded = chacha(cipher, key: material.prefix(32), nonce: material.subdata(in: 32..<44))
    var size = Int(padded[0]) * 256 + Int(padded[1])
    var prefix = 2
    if size == 0 {
      guard padded.count >= 6 else { throw DiscoveryError.invalid("Invalid extended padding.") }
      size = Int(padded[2]) << 24 | Int(padded[3]) << 16 | Int(padded[4]) << 8 | Int(padded[5])
      prefix = 6
      guard size >= 65536 else { throw DiscoveryError.invalid("Invalid extended length.") }
    }
    guard size > 0, size <= 16 * 1024 * 1024, size + prefix <= padded.count,
      padded.count == paddedLength(size) + prefix
    else { throw DiscoveryError.invalid("Invalid encrypted padding.") }
    let clear = padded.subdata(in: prefix..<(prefix + size))
    guard String(data: clear, encoding: .utf8) != nil else {
      throw DiscoveryError.invalid("Invalid encrypted text.")
    }
    return clear
  }
  static func chacha(_ data: Data, key: Data, nonce: Data) -> Data {
    func words(_ d: Data) -> [UInt32] {
      let b = Array(d)
      return stride(from: 0, to: b.count, by: 4).map {
        UInt32(b[$0]) | UInt32(b[$0 + 1]) << 8 | UInt32(b[$0 + 2]) << 16 | UInt32(b[$0 + 3]) << 24
      }
    }
    func rotate(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }
    func quarter(_ s: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
      s[a] = s[a] &+ s[b]
      s[d] = rotate(s[d] ^ s[a], 16)
      s[c] = s[c] &+ s[d]
      s[b] = rotate(s[b] ^ s[c], 12)
      s[a] = s[a] &+ s[b]
      s[d] = rotate(s[d] ^ s[a], 8)
      s[c] = s[c] &+ s[d]
      s[b] = rotate(s[b] ^ s[c], 7)
    }
    var state: [UInt32] =
      [0x6170_7865, 0x3320_646e, 0x7962_2d32, 0x6b20_6574] + words(key) + [0] + words(nonce)
    var output = Data()
    let input = Array(data)
    for start in stride(from: 0, to: input.count, by: 64) {
      var s = state
      for _ in 0..<10 {
        quarter(&s, 0, 4, 8, 12)
        quarter(&s, 1, 5, 9, 13)
        quarter(&s, 2, 6, 10, 14)
        quarter(&s, 3, 7, 11, 15)
        quarter(&s, 0, 5, 10, 15)
        quarter(&s, 1, 6, 11, 12)
        quarter(&s, 2, 7, 8, 13)
        quarter(&s, 3, 4, 9, 14)
      }
      var block = [UInt8]()
      for i in 0..<16 {
        let w = s[i] &+ state[i]
        block += (0..<4).map { UInt8(truncatingIfNeeded: w >> ($0 * 8)) }
      }
      for i in 0..<min(64, input.count - start) { output.append(input[start + i] ^ block[i]) }
      state[12] &+= 1
    }
    return output
  }
}

func discoveryRandom(_ count: Int) throws -> Data { var bytes = [UInt8](repeating:0,count:count); guard SecRandomCopyBytes(kSecRandomDefault,count,&bytes) == errSecSuccess else { throw DiscoveryError.invalid("Secure random unavailable") }; return Data(bytes) }
