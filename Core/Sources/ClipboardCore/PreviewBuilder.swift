import AppKit
import Foundation

enum PreviewBuilder {
  static let limit = 256

  /// Build a short, human-readable preview for a raw clip item.
  /// The result is always truncated to `limit` characters.
  ///
  /// Priority: `<image>` sentinel (when the clip carries image data)
  /// → plain text or RTF → HTML rendered as plain text → file name.
  /// The image check is unconditionally first: when users copy an
  /// image the intent is the image, and browsers routinely dump an
  /// HTML source wrapper into the plain-text slot too (for apps that
  /// only read plain text), so trusting plain text first would leak
  /// raw `<meta charset=...><img src=...>` strings into the preview.
  static func build(for payloads: [RawPayload], limit: Int = limit) -> String {
    if hasImageType(payloads) {
      return "<image>"
    }
    let plain = extractPlainTextOrRtf(from: payloads)
    if !plain.isEmpty {
      return String(plain.prefix(limit))
    }
    let html = extractHtmlPlainText(from: payloads)
    if !html.isEmpty {
      return String(html.prefix(limit))
    }
    if let fileName = extractFileName(from: payloads) {
      return String(fileName.prefix(limit))
    }
    return ""
  }

  private static func extractPlainTextOrRtf(from payloads: [RawPayload]) -> String {
    for type in ["public.utf8-plain-text", "public.plain-text", "public.string"] {
      if let data = payloads.first(where: { $0.pasteboardType == type })?.data,
        let text = String(data: data, encoding: .utf8),
        !text.isEmpty
      {
        return text
      }
    }
    if let rtf = payloads.first(where: { $0.pasteboardType == "public.rtf" }) {
      if let attrib = try? NSAttributedString(
        data: rtf.data,
        options: [.documentType: NSAttributedString.DocumentType.rtf],
        documentAttributes: nil
      ) {
        return attrib.string
      }
    }
    return ""
  }

  private static func extractHtmlPlainText(from payloads: [RawPayload]) -> String {
    guard let data = payloads.first(where: { $0.pasteboardType == "public.html" })?.data
    else {
      return ""
    }
    if let attrib = try? NSAttributedString(
      data: data,
      options: [
        .documentType: NSAttributedString.DocumentType.html,
        .characterEncoding: String.Encoding.utf8.rawValue,
      ],
      documentAttributes: nil
    ) {
      return attrib.string
    }
    return String(data: data, encoding: .utf8) ?? ""
  }

  private static func extractFileName(from payloads: [RawPayload]) -> String? {
    guard let payload = payloads.first(where: { $0.pasteboardType == "public.file-url" }),
      let urlString = String(data: payload.data, encoding: .utf8)
    else { return nil }
    if let url = URL(string: urlString) {
      return url.lastPathComponent
    }
    return urlString
  }

  private static func hasImageType(_ payloads: [RawPayload]) -> Bool {
    payloads.contains { ClipKind.imagePayloadTypes.contains($0.pasteboardType) }
  }
}
