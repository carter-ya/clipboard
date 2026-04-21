import CryptoKit
import Foundation

enum Hashing {
  /// Types considered "primary content" — if any of these exist in a
  /// clip, only the first (in this priority order) contributes to the
  /// dedup hash. This keeps dedup stable across apps that decorate the
  /// pasteboard with slightly different UTI metadata for the same
  /// content (e.g., NSStringPboardType presence varies by source app).
  static let primaryContentPriority: [String] = [
    "public.png", "public.tiff", "public.jpeg", "public.image",
    "public.rtf",
    "public.utf8-plain-text", "public.plain-text", "public.string",
    "public.html",
    "public.file-url",
  ]

  /// Canonical content hash for a clip — used for dedup.
  /// Prefers a single primary-content payload when present; only
  /// falls back to hashing the full payload set when no primary type
  /// is recognized.
  static func sha256(of payloads: [RawPayload]) -> String {
    if let primary = primaryPayload(in: payloads) {
      return allPayloadsHash([primary])
    }
    return allPayloadsHash(payloads)
  }

  /// Returns the highest-priority primary payload in the clip, or
  /// `nil` if none of the well-known primary types are declared.
  static func primaryPayload(in payloads: [RawPayload]) -> RawPayload? {
    for type in primaryContentPriority {
      if let hit = payloads.first(where: { $0.pasteboardType == type }) {
        return hit
      }
    }
    return nil
  }

  private static func allPayloadsHash(_ payloads: [RawPayload]) -> String {
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
