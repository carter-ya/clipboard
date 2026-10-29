import ClipboardCore
import SwiftUI

struct ClipRowView: View {
  let item: ClipItem
  let isSelected: Bool
  let thumbnailLoader: ThumbnailLoader?

  @State private var thumbnail: NSImage?

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      leading
      VStack(alignment: .leading, spacing: 3) {
        Text(displayPreview)
          .font(.system(size: 13, weight: .regular))
          .lineLimit(2)
          .foregroundStyle(
            isSelected ? Color.white : (item.sensitive ? Color.secondary : Color.primary)
          )
        HStack(spacing: 6) {
          // SwiftUI owns the refresh cadence for .relative — the row's
          // body no longer re-runs RelativeDateTimeFormatter every
          // publish, which was a per-row hotspot during scroll.
          Text(item.createdAt, style: .relative)
          if let bundle = item.sourceBundleID {
            Text("·")
            Text(BundleNameResolver.shared.displayName(for: bundle))
              .lineLimit(1)
              .truncationMode(.middle)
          }
          if item.pinned {
            Image(systemName: "pin.fill")
          }
          if item.sensitive {
            Image(systemName: "lock.fill")
          }
        }
        .font(.system(size: 11))
        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(isSelected ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear)
    )
    .contentShape(RoundedRectangle(cornerRadius: 8))
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
          .fill(isSelected ? Color.white.opacity(0.15) : kindBackground.opacity(0.10))
        Image(systemName: ClipKindFormatting.icon(for: item.kind))
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(isSelected ? Color.white : kindBackground)
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

  private var kindBackground: Color {
    ClipKindFormatting.tint(for: item.kind)
  }

  private var displayPreview: String {
    if item.sensitive {
      return "●●●●"
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
