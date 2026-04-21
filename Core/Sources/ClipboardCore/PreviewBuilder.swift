import AppKit
import Foundation

enum PreviewBuilder {
  static let limit = 256

  /// Build a short, human-readable preview for a raw clip item.
  /// The result is always truncated to `limit` characters.
  static func build(for payloads: [RawPayload], limit: Int = limit) -> String {
    let text = extractText(from: payloads)
    if !text.isEmpty {
      return String(text.prefix(limit))
    }
    if let fileName = extractFileName(from: payloads) {
      return String(fileName.prefix(limit))
    }
    if hasImageType(payloads) {
      return "<image>"
    }
    return ""
  }

  private static func extractText(from payloads: [RawPayload]) -> String {
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
    if let html = payloads.first(where: { $0.pasteboardType == "public.html" })?.data,
      let text = String(data: html, encoding: .utf8)
    {
      return text
    }
    return ""
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
    let imageTypes: Set<String> = [
      "public.png", "public.tiff", "public.jpeg", "public.image",
    ]
    return payloads.contains { imageTypes.contains($0.pasteboardType) }
  }
}
