import Foundation

public enum ClipKind: String, Sendable, Codable, CaseIterable, Equatable {
  case text
  case rtf
  case image
  case file
  case mixed

  /// Pasteboard UTTypes that carry image bytes we know how to decode /
  /// thumbnail / summarise. Kept here so App-layer call sites (row
  /// thumbnails, preview pane, image summarizer) share one definition
  /// instead of copy-pasting the literal set.
  public static let imagePayloadTypes: Set<String> = [
    "public.png", "public.tiff", "public.jpeg", "public.image",
  ]

  /// Maps a raw pasteboard type identifier to its primary kind, if any.
  static func primary(for pasteboardType: String) -> ClipKind? {
    switch pasteboardType {
    case "public.rtf": return .rtf
    case "public.png", "public.tiff", "public.jpeg", "public.image": return .image
    case "public.file-url": return .file
    case "public.utf8-plain-text", "public.string", "public.plain-text", "NSStringPboardType":
      return .text
    case "public.html": return .text
    default: return nil
    }
  }

  /// Determines the overall kind for a set of pasteboard types. Picks
  /// the richest primary present, so a browser image copy (PNG + HTML
  /// wrapper) reads as `.image` and rich text (RTF + plain text) reads
  /// as `.rtf` rather than both collapsing into the old `.mixed`.
  /// Priority: image > file > rtf > text (html counts as text). Image
  /// beats file because Telegram / Messages / screenshot tools copy
  /// pictures with an accompanying temp `public.file-url`; users think
  /// of those as images. Pure Finder file copies (file-url only, no
  /// image payload) still resolve to `.file`. `.mixed` is retained as
  /// an enum case for backward compatibility but never produced here.
  static func infer(from pasteboardTypes: [String]) -> ClipKind {
    var hasImage = false
    var hasFile = false
    var hasRtf = false
    var hasText = false
    for type in pasteboardTypes {
      guard let primary = primary(for: type) else { continue }
      switch primary {
      case .image: hasImage = true
      case .file: hasFile = true
      case .rtf: hasRtf = true
      case .text: hasText = true
      case .mixed: break
      }
    }
    if hasImage { return .image }
    if hasFile { return .file }
    if hasRtf { return .rtf }
    if hasText { return .text }
    return .text
  }
}

extension String {
  /// File extension (no leading dot) to use when this pasteboard type is
  /// persisted as a blob under `blobs/<sha256>.<ext>`.
  public var blobExtension: String {
    switch self {
    case "public.png": return "png"
    case "public.tiff": return "tiff"
    case "public.jpeg": return "jpeg"
    case "public.rtf": return "rtf"
    case "public.html": return "html"
    case "public.utf8-plain-text", "public.plain-text", "NSStringPboardType": return "txt"
    case "public.file-url": return "url"
    default: return "bin"
    }
  }
}
