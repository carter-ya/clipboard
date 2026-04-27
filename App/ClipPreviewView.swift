import ClipboardCore
import ImageIO
import SwiftUI

struct ClipPreviewView: View {
  let item: ClipItem?
  let thumbnailLoader: ThumbnailLoader?
  let resolver: PayloadResolver?
  /// Per-clip ephemeral summary state from `HistoryPanelViewModel`.
  /// When the selected item has no summary yet but is mid-flight or
  /// failed, the preview pane renders a small placeholder instead
  /// of leaving a silent gap above the content.
  var summaryProgress: [UUID: SummaryProgress] = [:]
  /// Async closure invoked when the user clicks the Retry button on
  /// a failed summary. The VM dispatches into the coordinator's
  /// `retry(_:)`, which re-runs the engine waterfall.
  var onRetry: (ClipItem) async -> Void = { _ in }

  // 64KB UTF-8 byte cap; pasteboard write still uses full payload
  private static let textDisplayLimit = 64 * 1024

  /// Terminal state for an off-main text load. Storing `displayCount` avoids
  /// recomputing `body.count` (O(N) graphemes) on the main thread per render.
  private struct LoadedText: Equatable {
    let id: UUID
    let body: String
    let truncated: Bool
    let displayCount: Int
  }

  @State private var previewImage: NSImage?
  @State private var loadedImageForID: UUID?
  @State private var loadEpoch: Int = 0
  @State private var revealed: Bool = false
  @State private var isHoveringImage = false
  @State private var showPeek = false
  @State private var peekHideTask: Task<Void, Never>?
  @State private var loadedText: LoadedText?

  var body: some View {
    VStack(spacing: 0) {
      if let item {
        header(for: item)
        Divider()
        if let summary = item.summary, !summary.isEmpty, !item.sensitive {
          summarySection(summary: summary, source: item.summarySource)
          Divider()
        } else if !item.sensitive, let progress = summaryProgress[item.id] {
          summaryProgressSection(progress: progress, item: item)
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

  @ViewBuilder
  private func summaryProgressSection(progress: SummaryProgress, item: ClipItem)
    -> some View
  {
    HStack(spacing: 8) {
      switch progress {
      case .inProgress(let engine):
        ProgressView()
          .controlSize(.small)
        Text("summary.state.generating")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Text(sourceBadge(for: engine))
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 5)
          .padding(.vertical, 1.5)
          .background(
            RoundedRectangle(cornerRadius: 4)
              .fill(Color.primary.opacity(0.08))
          )
      case .failed:
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
        Text("summary.state.failed")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button {
          Task { await onRetry(item) }
        } label: {
          Text("summary.state.retry")
            .font(.caption2)
        }
        .buttonStyle(.borderless)
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
    case .remoteOpenAI: return NSLocalizedString("remoteAI.badge.remote", comment: "")
    }
  }

  @ViewBuilder
  private func header(for item: ClipItem) -> some View {
    let tint = ClipKindFormatting.tint(for: item.kind)
    HStack(spacing: 8) {
      HStack(spacing: 4) {
        Image(systemName: ClipKindFormatting.icon(for: item.kind))
          .font(.system(size: 10, weight: .semibold))
        Text(ClipKindFormatting.label(for: item.kind))
          .font(.system(size: 10, weight: .semibold))
      }
      .foregroundStyle(tint)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(Capsule().fill(tint.opacity(0.15)))

      if let bundle = item.sourceBundleID {
        Text(BundleNameResolver.shared.displayName(for: bundle))
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
      // SwiftUI's native `.relative` style mirrors what `ClipRowView`
      // already uses; it keeps the string fresh without us owning a
      // RelativeDateTimeFormatter instance.
      Text(item.createdAt, style: .relative)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 12)
    .frame(height: 64)
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
      Text(
        "Sensitive content from \(item.sourceBundleID.map { BundleNameResolver.shared.displayName(for: $0) } ?? "unknown")"
      )
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
      VStack(alignment: .leading, spacing: 6) {
        if let loaded = loadedText, loaded.id == item.id {
          if !loaded.body.isEmpty {
            Text(loaded.body)
            if loaded.truncated {
              Text(Self.truncatedNotice(charCount: loaded.displayCount))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          } else {
            Text(item.preview)
          }
        } else {
          Text(item.preview)
          ProgressView()
            .controlSize(.small)
        }
      }
      .textSelection(.enabled)
      .font(.system(size: 13))
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding()
    }
    .task(id: item.id) {
      await loadText(for: item)
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

  private static func resolveFullTextOffMain(payloads: [Payload], resolver: PayloadResolver)
    -> String?
  {
    for type in ["public.utf8-plain-text", "public.plain-text", "public.string"] {
      if let payload = payloads.first(where: { $0.pasteboardType == type }),
        let data = try? resolver.data(for: payload),
        let text = String(data: data, encoding: .utf8)
      {
        return text
      }
    }
    if let rtf = payloads.first(where: { $0.pasteboardType == "public.rtf" }),
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

  @MainActor
  private func loadText(for item: ClipItem) async {
    // SwiftUI's .task(id:) cancels and re-launches on id change, so no manual
    // epoch is needed. Reset previous state synchronously so the spinner shows
    // while the new resolution is in flight.
    if loadedText?.id != item.id {
      loadedText = nil
    }
    guard let resolver else {
      loadedText = LoadedText(id: item.id, body: "", truncated: false, displayCount: 0)
      return
    }
    let payloads = item.payloads
    let limit = Self.textDisplayLimit
    let targetID = item.id
    let result: LoadedText = await Task.detached(priority: .userInitiated) {
      guard
        let full = ClipPreviewView.resolveFullTextOffMain(
          payloads: payloads, resolver: resolver)
      else {
        return LoadedText(id: targetID, body: "", truncated: false, displayCount: 0)
      }
      let utf8Count = full.utf8.count
      let truncated = utf8Count > limit
      let body: String
      let displayCount: Int
      if truncated {
        body = String(decoding: full.utf8.prefix(limit), as: UTF8.self)
        displayCount = body.count
      } else {
        body = full
        displayCount = full.count
      }
      return LoadedText(id: targetID, body: body, truncated: truncated, displayCount: displayCount)
    }.value
    if Task.isCancelled { return }
    loadedText = result
  }

  private static func truncatedNotice(charCount: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    let formatted = formatter.string(from: NSNumber(value: charCount)) ?? String(charCount)
    return String(
      format: NSLocalizedString("preview.text.truncated.format", comment: ""),
      formatted
    )
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
        ClipKind.imagePayloadTypes.contains($0.pasteboardType)
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
