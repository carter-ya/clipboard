import ClipboardCore
import SwiftUI

struct ClipRowView: View {
  let item: ClipItem

  private static let relativeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f
  }()

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: kindIcon)
        .font(.system(size: 16))
        .foregroundStyle(.secondary)
        .frame(width: 20)
      VStack(alignment: .leading, spacing: 2) {
        Text(displayPreview)
          .font(.system(size: 13))
          .lineLimit(2)
          .foregroundStyle(item.sensitive ? .secondary : .primary)
        HStack(spacing: 6) {
          Text(
            Self.relativeFormatter.localizedString(
              for: item.createdAt,
              relativeTo: Date()
            )
          )
          if let bundle = item.sourceBundleID {
            Text("·")
            Text(bundle)
          }
          if item.pinned {
            Image(systemName: "pin.fill")
          }
          if item.sensitive {
            Image(systemName: "lock.fill")
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(.vertical, 4)
  }

  private var kindIcon: String {
    switch item.kind {
    case .text: return "text.alignleft"
    case .rtf: return "doc.richtext"
    case .image: return "photo"
    case .file: return "doc"
    case .mixed: return "square.stack"
    }
  }

  private var displayPreview: String {
    if item.sensitive {
      let bundle = item.sourceBundleID ?? "unknown"
      return "●●●● (from \(bundle))"
    }
    if item.preview.isEmpty {
      return "(empty)"
    }
    return item.preview
  }
}
