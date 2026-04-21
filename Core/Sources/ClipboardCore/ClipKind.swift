import Foundation

public enum ClipKind: String, Sendable, Codable, CaseIterable, Equatable {
  case text
  case rtf
  case image
  case file
  case mixed

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

  /// Determines the overall kind for a set of pasteboard types.
  /// Returns `.mixed` when two or more distinct primary kinds are present.
  static func infer(from pasteboardTypes: [String]) -> ClipKind {
    var primaries = Set<ClipKind>()
    for type in pasteboardTypes {
      if let primary = primary(for: type) {
        primaries.insert(primary)
      }
    }
    if primaries.count >= 2 { return .mixed }
    return primaries.first ?? .text
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
