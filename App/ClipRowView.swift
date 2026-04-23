import ClipboardCore
import SwiftUI

struct ClipRowView: View {
  let item: ClipItem
  let isSelected: Bool
  let thumbnailLoader: ThumbnailLoader?

  @State private var thumbnail: NSImage?

  private static let relativeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f
  }()

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      leading
      VStack(alignment: .leading, spacing: 3) {
        Text(displayPreview)
          .font(.system(size: 13, weight: .regular))
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
              .lineLimit(1)
              .truncationMode(.middle)
          }
          if item.pinned {
            Image(systemName: "pin.fill").foregroundStyle(.orange)
          }
          if item.sensitive {
            Image(systemName: "lock.fill").foregroundStyle(.secondary)
          }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .strokeBorder(
          isSelected ? Color.accentColor.opacity(0.45) : Color.clear,
          lineWidth: 0.5
        )
    )
    .contentShape(RoundedRectangle(cornerRadius: 6))
    .onAppear { loadThumbnailIfNeeded() }
  }

  @ViewBuilder
  private var leading: some View {
    if item.kind == .image, !item.sensitive {
      ZStack {
        RoundedRectangle(cornerRadius: 4)
          .fill(Color.secondary.opacity(0.10))
        if let image = thumbnail {
          Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .padding(2)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
          Image(systemName: "photo")
            .foregroundStyle(.secondary)
        }
      }
      .frame(width: 40, height: 40)
      .overlay(
        RoundedRectangle(cornerRadius: 4)
          .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5)
      )
    } else {
      ZStack {
        RoundedRectangle(cornerRadius: 4)
          .fill(kindBackground.opacity(0.15))
        Image(systemName: kindIcon)
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(kindBackground)
      }
      .frame(width: 40, height: 40)
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

  private var kindBackground: Color {
    switch item.kind {
    case .text: return .blue
    case .rtf: return .purple
    case .image: return .green
    case .file: return .orange
    case .mixed: return .gray
    }
  }

  private var displayPreview: String {
    if item.sensitive {
      let bundle = item.sourceBundleID ?? "unknown"
      return "●●●● (from \(bundle))"
    }
    // For image clips the stored preview is a bare sentinel like
    // "<image>" — which isn't useful in the row. If a summary has
    // been generated (OCR text, classification labels, or an LLM
    // description), show that instead so the row is informative.
    if item.kind == .image, let summary = item.summary, !summary.isEmpty {
      return summary
    }
    if item.preview.isEmpty {
      return "(empty)"
    }
    return item.preview
  }
}
