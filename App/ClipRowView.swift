import ClipboardCore
import SwiftUI

struct ClipRowView: View {
  let item: ClipItem
  let thumbnailLoader: ThumbnailLoader?

  @State private var thumbnail: NSImage?

  private static let relativeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f
  }()

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      leading
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
    .onAppear { loadThumbnailIfNeeded() }
  }

  @ViewBuilder
  private var leading: some View {
    if item.kind == .image, !item.sensitive {
      if let image = thumbnail {
        Image(nsImage: image)
          .resizable()
          .interpolation(.high)
          .aspectRatio(contentMode: .fit)
          .frame(width: 36, height: 36)
          .cornerRadius(4)
      } else {
        Image(systemName: "photo")
          .frame(width: 36, height: 36)
          .foregroundStyle(.secondary)
      }
    } else {
      Image(systemName: kindIcon)
        .font(.system(size: 16))
        .foregroundStyle(.secondary)
        .frame(width: 36, height: 36)
    }
  }

  private func loadThumbnailIfNeeded() {
    guard item.kind == .image, !item.sensitive, thumbnail == nil else { return }
    guard let loader = thumbnailLoader else { return }
    if let immediate = loader.thumbnail(for: item, completion: { img in self.thumbnail = img }) {
      thumbnail = immediate
    }
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
