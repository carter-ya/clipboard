import ClipboardCore
import SwiftUI

/// Shared view-layer mapping from `ClipKind` to its SF Symbol name,
/// localized label, and tint color. Previously duplicated inside
/// `ClipRowView` and `ClipPreviewView`; the two copies were byte-for-byte
/// identical, so consolidating here keeps the kind palette in one place.
///
/// Localized-label keys (`"Text"`, `"Rich Text"`, `"Image"`, `"File"`,
/// `"Mixed"`) must stay in sync with `*.lproj/Localizable.strings`.
enum ClipKindFormatting {
  static func icon(for kind: ClipKind) -> String {
    switch kind {
    case .text: return "text.alignleft"
    case .rtf: return "doc.richtext"
    case .image: return "photo"
    case .file: return "doc"
    case .mixed: return "square.stack"
    }
  }

  static func label(for kind: ClipKind) -> LocalizedStringKey {
    switch kind {
    case .text: return "Text"
    case .rtf: return "Rich Text"
    case .image: return "Image"
    case .file: return "File"
    case .mixed: return "Mixed"
    }
  }

  static func tint(for kind: ClipKind) -> Color {
    switch kind {
    case .text: return .blue
    case .rtf: return .purple
    case .image: return .green
    case .file: return .orange
    case .mixed: return .gray
    }
  }
}
