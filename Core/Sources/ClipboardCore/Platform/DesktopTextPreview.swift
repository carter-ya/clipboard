import Foundation

/// A display-only UTF-8 budget. Original payloads remain available to Copy.
public struct DesktopTextPreview: Equatable, Sendable {
  public let text: String
  public let isTruncated: Bool

  public init(_ fullText: String, maxUTF8Bytes: Int = 64 * 1024) {
    precondition(maxUTF8Bytes >= 0)
    let bytes = fullText.utf8
    guard bytes.count > maxUTF8Bytes else {
      text = fullText
      isTruncated = false
      return
    }
    var end = bytes.index(bytes.startIndex, offsetBy: maxUTF8Bytes)
    // Do not turn a split multi-byte scalar into a replacement character.
    while end > bytes.startIndex && bytes[end] & 0xC0 == 0x80 {
      end = bytes.index(before: end)
    }
    text = String(decoding: bytes[..<end], as: UTF8.self)
    isTruncated = true
  }
}
