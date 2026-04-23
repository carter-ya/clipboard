import ClipboardCore
import ImageIO
import SwiftUI

struct ClipPreviewView: View {
  let item: ClipItem?
  let thumbnailLoader: ThumbnailLoader?
  let resolver: PayloadResolver?

  @State private var previewImage: NSImage?
  @State private var loadedImageForID: UUID?
  @State private var loadEpoch: Int = 0
  @State private var revealed: Bool = false
  @State private var isHoveringImage = false
  @State private var showPeek = false
  @State private var peekHideTask: Task<Void, Never>?

  var body: some View {
    VStack(spacing: 0) {
      if let item {
        header(for: item)
        Divider()
        if let summary = item.summary, !summary.isEmpty, !item.sensitive {
          summarySection(summary: summary, source: item.summarySource)
          Divider()
        }
      }
      Group {
        if let item {
          if item.sensitive, !revealed {
            masked(item)
          } else {
            content(for: item)
          }
        } else {
          empty
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  @ViewBuilder
  private func summarySection(summary: String, source: SummarySource?) -> some View {
    HStack(alignment: .top, spacing: 6) {
      Image(systemName: "sparkles")
        .font(.caption2)
        .foregroundStyle(.secondary)
      Text(summary)
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button(action: { copySummary(summary) }) {
        Image(systemName: "doc.on.doc")
          .font(.caption2)
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help("Copy summary")
      .accessibilityLabel("Copy summary")
      if let source {
        Text(sourceBadge(for: source))
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 5)
          .padding(.vertical, 1.5)
          .background(
            RoundedRectangle(cornerRadius: 4)
              .fill(Color.primary.opacity(0.08))
          )
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
  }

  private func copySummary(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }

  private func sourceBadge(for source: SummarySource) -> String {
    switch source {
    case .vision: return "Vision"
    case .naturalLanguage: return "NL"
    case .foundationModels: return "FM"
    }
  }

  @ViewBuilder
  private func header(for item: ClipItem) -> some View {
    HStack(spacing: 8) {
      HStack(spacing: 4) {
        Image(systemName: kindIcon(for: item.kind))
          .font(.system(size: 10, weight: .semibold))
        Text(kindLabel(for: item.kind))
          .font(.system(size: 10, weight: .semibold))
      }
      .foregroundStyle(kindTint(for: item.kind))
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(Capsule().fill(kindTint(for: item.kind).opacity(0.15)))

      if let bundle = item.sourceBundleID {
        Text(bundle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer(minLength: 4)
      if item.pinned {
        Image(systemName: "pin.fill")
          .font(.caption2)
          .foregroundStyle(.orange)
      }
      if item.sensitive {
        Image(systemName: "lock.fill")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      Text(
        Self.relativeFormatter.localizedString(
          for: item.createdAt, relativeTo: Date()
        )
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 12)
    .frame(height: 64)
  }

  private static let relativeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f
  }()

  private func kindIcon(for kind: ClipKind) -> String {
    switch kind {
    case .text: return "text.alignleft"
    case .rtf: return "doc.richtext"
    case .image: return "photo"
    case .file: return "doc"
    case .mixed: return "square.stack"
    }
  }

  private func kindLabel(for kind: ClipKind) -> LocalizedStringKey {
    switch kind {
    case .text: return "Text"
    case .rtf: return "Rich Text"
    case .image: return "Image"
    case .file: return "File"
    case .mixed: return "Mixed"
    }
  }

  private func kindTint(for kind: ClipKind) -> Color {
    switch kind {
    case .text: return .blue
    case .rtf: return .purple
    case .image: return .green
    case .file: return .orange
    case .mixed: return .gray
    }
  }

  private var empty: some View {
    VStack(spacing: 8) {
      Image(systemName: "doc.text.magnifyingglass")
        .font(.system(size: 32))
        .foregroundStyle(.secondary)
      Text("Select an item to preview")
        .foregroundStyle(.secondary)
        .font(.caption)
    }
  }

  private func masked(_ item: ClipItem) -> some View {
    VStack(spacing: 12) {
      Image(systemName: "lock.fill").font(.system(size: 32))
      Text("Sensitive content from \(item.sourceBundleID ?? "unknown")")
        .font(.caption)
        .foregroundStyle(.secondary)
      Button("Reveal for this session") { revealed = true }
    }
    .padding()
  }

  @ViewBuilder
  private func content(for item: ClipItem) -> some View {
    switch item.kind {
    case .text, .rtf, .mixed:
      textView(item)
    case .image:
      imageView(item)
    case .file:
      fileView(item)
    }
  }

  private func textView(_ item: ClipItem) -> some View {
    ScrollView {
      Text(resolveFullText(for: item) ?? item.preview)
        .textSelection(.enabled)
        .font(.system(size: 13))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }
  }

  private func imageView(_ item: ClipItem) -> some View {
    VStack {
      if let previewImage, loadedImageForID == item.id {
        Image(nsImage: previewImage)
          .resizable()
          .interpolation(.high)
          .aspectRatio(contentMode: .fit)
          .onHover { hovering in
            isHoveringImage = hovering
            updatePeek(hovering: hovering)
          }
          .popover(isPresented: $showPeek, arrowEdge: .leading) {
            Image(nsImage: previewImage)
              .resizable()
              .interpolation(.high)
              .aspectRatio(contentMode: .fit)
              .frame(
                maxWidth: min(previewImage.size.width, 600),
                maxHeight: min(previewImage.size.height, 600)
              )
              .padding(8)
          }
      } else {
        ProgressView()
          .onAppear { loadImage(item) }
      }
    }
    .padding()
    .onChange(of: item.id) { _ in
      // Selection changed while preview is visible — discard the
      // previously-loaded image and refetch for the new item. Without
      // this the preview keeps rendering whichever picture was
      // resolved first.
      previewImage = nil
      loadedImageForID = nil
      loadImage(item)
      // Any active peek refers to the previous item; close it.
      showPeek = false
      isHoveringImage = false
      peekHideTask?.cancel()
    }
  }

  /// Open the peek popover on hover-in; close with a short delay on
  /// hover-out so the popover's own appearance animation doesn't
  /// momentarily pull the cursor off the anchor and flicker the
  /// whole thing closed.
  private func updatePeek(hovering: Bool) {
    peekHideTask?.cancel()
    if hovering {
      showPeek = true
    } else {
      peekHideTask = Task {
        try? await Task.sleep(nanoseconds: 250_000_000)
        if Task.isCancelled { return }
        await MainActor.run {
          if !self.isHoveringImage {
            self.showPeek = false
          }
        }
      }
    }
  }

  private func fileView(_ item: ClipItem) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(resolveFileURLs(for: item), id: \.self) { url in
        HStack {
          Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .frame(width: 24, height: 24)
          Text(url.lastPathComponent)
        }
      }
    }
    .padding()
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func resolveFullText(for item: ClipItem) -> String? {
    guard let resolver else { return nil }
    for type in ["public.utf8-plain-text", "public.plain-text", "public.string"] {
      if let payload = item.payloads.first(where: { $0.pasteboardType == type }),
        let data = try? resolver.data(for: payload),
        let text = String(data: data, encoding: .utf8)
      {
        return text
      }
    }
    if let rtf = item.payloads.first(where: { $0.pasteboardType == "public.rtf" }),
      let data = try? resolver.data(for: rtf),
      let attrib = try? NSAttributedString(
        data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
        documentAttributes: nil
      )
    {
      return attrib.string
    }
    return nil
  }

  private func resolveFileURLs(for item: ClipItem) -> [URL] {
    guard let resolver else { return [] }
    return item.payloads
      .filter { $0.pasteboardType == "public.file-url" }
      .compactMap { payload -> URL? in
        guard let data = try? resolver.data(for: payload),
          let urlString = String(data: data, encoding: .utf8),
          let url = URL(string: urlString)
        else { return nil }
        return url
      }
  }

  private func loadImage(_ item: ClipItem) {
    // Epoch-guarded load. Every call bumps loadEpoch and captures
    // the value; the main-queue completion only applies its result
    // if the epoch is still current. This prevents a slow earlier
    // load from overwriting a fresher one (which in turn produced
    // the "stuck Loading" symptom when users switched items
    // mid-load).
    guard let resolver else { return }
    guard
      let payload = item.payloads.first(where: {
        ["public.png", "public.tiff", "public.jpeg", "public.image"]
          .contains($0.pasteboardType)
      })
    else { return }
    loadEpoch &+= 1
    let epoch = loadEpoch
    let targetID = item.id
    DispatchQueue.global(qos: .userInitiated).async {
      guard let data = try? resolver.data(for: payload) else { return }
      guard let image = Self.preDecode(data: data) else { return }
      DispatchQueue.main.async {
        guard epoch == loadEpoch else { return }
        previewImage = image
        loadedImageForID = targetID
      }
    }
  }

  /// Decodes `data` into a bitmap NSImage off the main thread using
  /// ImageIO. Scales the longer edge down to `maxPixel` points so
  /// the preview pane is fast to render even when the clipboard
  /// contains a 6K screenshot.
  private static func preDecode(data: Data, maxPixel: Int = 1024) -> NSImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
      return nil
    }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    guard
      let cgImage = CGImageSourceCreateThumbnailAtIndex(
        source,
        0,
        options as CFDictionary
      )
    else { return nil }
    return NSImage(
      cgImage: cgImage,
      size: NSSize(width: cgImage.width, height: cgImage.height)
    )
  }
}
