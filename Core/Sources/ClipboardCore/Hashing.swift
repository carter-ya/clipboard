import CryptoKit
import Foundation

enum Hashing {
  /// Canonical content hash across all payloads of a clip.
  /// Payloads are sorted by pasteboardType so that ordering in the
  /// source pasteboard does not affect the hash.
  static func sha256(of payloads: [RawPayload]) -> String {
    var hasher = SHA256()
    for payload in payloads.sorted(by: { $0.pasteboardType < $1.pasteboardType }) {
      hasher.update(data: Data(payload.pasteboardType.utf8))
      hasher.update(data: Data([0]))
      hasher.update(data: payload.data)
      hasher.update(data: Data([0]))
    }
    return hexString(hasher.finalize())
  }

  /// Stable per-payload hash used for blob filename deduplication.
  static func sha256(of data: Data) -> String {
    hexString(SHA256.hash(data: data))
  }

  private static func hexString<S: Sequence>(_ digest: S) -> String
  where S.Element == UInt8 {
    digest.lazy.map { String(format: "%02x", $0) }.joined()
  }
}
