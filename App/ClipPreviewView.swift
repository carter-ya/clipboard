import ClipboardCore
import ImageIO
import SwiftUI

struct ClipPreviewView: View {
  let item: ClipItem?
  let thumbnailLoader: ThumbnailLoader?
  let resolver: PayloadResolver?

  @State private var previewImage: NSImage?
  @State private var loadedImageForID: UUID?
  @State private var revealed: Bool = false

  var body: some View {
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
    // Load a full-resolution preview image in the background and
    // pre-decode it via ImageIO so the main thread only has to paint
    // — not decompress — when the View is re-rendered.
    //
    // NSImage(data:) is lazy; its first draw would happen on the
    // main queue, which is exactly where SwiftUI is trying to render
    // and where the user perceives "loading" delay even for tiny
    // screenshots. CGImageSourceCreateThumbnailAtIndex forces decode
    // up-front on the background queue.
    guard let resolver else { return }
    guard
      let payload = item.payloads.first(where: {
        ["public.png", "public.tiff", "public.jpeg", "public.image"]
          .contains($0.pasteboardType)
      })
    else { return }
    let targetID = item.id
    DispatchQueue.global(qos: .userInitiated).async {
      guard let data = try? resolver.data(for: payload) else { return }
      guard let image = Self.preDecode(data: data) else { return }
      DispatchQueue.main.async {
        guard loadedImageForID != targetID else { return }
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
