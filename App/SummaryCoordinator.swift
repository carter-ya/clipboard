import AppKit
import ClipboardCore
import Foundation

/// Listens to ClipStore.inserted events and kicks off on-device
/// summary generation for fresh clips, gated on the user's AI
/// preferences and the clip's sensitivity flag. Each kind (image /
/// text / file) maps to a different engine; S64 wires up Vision for
/// image clips. Writing Tools (S65) and Foundation Models (S66) will
/// slot into the same dispatcher with the same gating rules.
@MainActor
final class SummaryCoordinator {
  private let store: any ClipStore
  private let resolver: PayloadResolver
  private let prefsStore: PreferencesStore
  private let imageSummarizer: any ImageSummarizer
  private let textSummarizer: any TextSummarizer
  private var task: Task<Void, Never>?

  init(
    store: any ClipStore,
    resolver: PayloadResolver,
    prefsStore: PreferencesStore,
    imageSummarizer: any ImageSummarizer = VisionImageSummarizer(),
    textSummarizer: any TextSummarizer = NaturalLanguageTextSummarizer()
  ) {
    self.store = store
    self.resolver = resolver
    self.prefsStore = prefsStore
    self.imageSummarizer = imageSummarizer
    self.textSummarizer = textSummarizer
  }

  func start() {
    stop()
    Log.ui.info("summary.coordinator.start")
    task = Task { [weak self] in
      guard let self else { return }
      for await event in self.store.events {
        if Task.isCancelled { break }
        if case .inserted(let item) = event {
          Log.ui.info(
            "summary.event.inserted id=\(item.id.uuidString, privacy: .public) kind=\(item.kind.rawValue, privacy: .public)"
          )
          await self.handle(item)
        }
      }
    }
  }

  func stop() {
    task?.cancel()
    task = nil
  }

  private func handle(_ item: ClipItem) async {
    let prefs = prefsStore.current
    guard prefs.summariesEnabled, !item.sensitive, item.summary == nil else {
      Log.ui.info(
        "summary.skip id=\(item.id.uuidString, privacy: .public) reason=gated kind=\(item.kind.rawValue, privacy: .public) enabled=\(prefs.summariesEnabled) sensitive=\(item.sensitive) hasSummary=\(item.summary != nil)"
      )
      return
    }

    switch item.kind {
    case .image:
      guard prefs.allowImageSummaries, AICapability.isVisionAvailable else {
        Log.ui.info(
          "summary.skip id=\(item.id.uuidString, privacy: .public) reason=image-disabled allow=\(prefs.allowImageSummaries) vision=\(AICapability.isVisionAvailable)"
        )
        return
      }
      await summarizeImage(item)
    case .text, .rtf, .mixed:
      guard prefs.allowTextSummaries else {
        Log.ui.info(
          "summary.skip id=\(item.id.uuidString, privacy: .public) reason=text-disabled"
        )
        return
      }
      await summarizeText(item)
    case .file:
      guard prefs.allowFileSummaries, AICapability.isFoundationModelsAvailable else {
        Log.ui.info(
          "summary.skip id=\(item.id.uuidString, privacy: .public) reason=file-disabled allow=\(prefs.allowFileSummaries) fm=\(AICapability.isFoundationModelsAvailable)"
        )
        return
      }
      await summarizeFile(item)
    }
  }

  private func summarizeImage(_ item: ClipItem) async {
    guard
      let payload = item.payloads.first(where: {
        ClipKind.imagePayloadTypes.contains($0.pasteboardType)
      })
    else {
      let types = item.payloads.map(\.pasteboardType).joined(separator: ",")
      Log.ui.info(
        "summary.image.noPayload id=\(item.id.uuidString, privacy: .public) types=\(types, privacy: .public)"
      )
      return
    }
    guard let data = try? resolver.data(for: payload) else {
      Log.ui.error(
        "summary.image.loadFailed id=\(item.id.uuidString, privacy: .public) type=\(payload.pasteboardType, privacy: .public)"
      )
      return
    }
    Log.ui.info(
      "summary.image.start id=\(item.id.uuidString, privacy: .public) bytes=\(data.count)"
    )
    guard let summary = await imageSummarizer.summarize(imageData: data),
      !summary.isEmpty
    else {
      Log.ui.info(
        "summary.image.empty id=\(item.id.uuidString, privacy: .public)"
      )
      return
    }
    Log.ui.info(
      "summary.image.done id=\(item.id.uuidString, privacy: .public) len=\(summary.count)"
    )
    await store.updateSummary(id: item.id, summary: summary, source: .vision)
  }

  private func summarizeText(_ item: ClipItem) async {
    guard let text = extractPlainText(from: item) else {
      Log.ui.info(
        "summary.text.noPayload id=\(item.id.uuidString, privacy: .public)"
      )
      return
    }
    Log.ui.info(
      "summary.text.start id=\(item.id.uuidString, privacy: .public) chars=\(text.count)"
    )
    // Prefer Foundation Models when available — the LLM produces a
    // real sentence, while NaturalLanguage can only list entities.
    // The FM symbol only exists on SDKs that ship FoundationModels
    // (Xcode 26+); older SDKs fall straight through to NaturalLanguage.
    #if canImport(FoundationModels)
      if #available(macOS 26.0, *), AICapability.isFoundationModelsAvailable {
        let fm = FoundationModelsSummarizer()
        if let summary = await fm.summarize(text: text), !summary.isEmpty {
          Log.ui.info(
            "summary.text.fm id=\(item.id.uuidString, privacy: .public) len=\(summary.count)"
          )
          await store.updateSummary(
            id: item.id, summary: summary, source: .foundationModels)
          return
        }
      }
    #endif
    // Fallback: baseline NaturalLanguage — available on macOS 13+.
    guard AICapability.isNaturalLanguageAvailable,
      let summary = await textSummarizer.summarize(text: text),
      !summary.isEmpty
    else {
      Log.ui.info("summary.text.empty id=\(item.id.uuidString, privacy: .public)")
      return
    }
    Log.ui.info(
      "summary.text.nl id=\(item.id.uuidString, privacy: .public) len=\(summary.count)"
    )
    await store.updateSummary(id: item.id, summary: summary, source: .naturalLanguage)
  }

  private func summarizeFile(_ item: ClipItem) async {
    #if canImport(FoundationModels)
      guard #available(macOS 26.0, *) else { return }
      guard let url = extractFileURL(from: item) else { return }
      let fm = FoundationModelsSummarizer()
      guard let summary = await fm.summarizeFile(url: url), !summary.isEmpty else {
        return
      }
      await store.updateSummary(
        id: item.id, summary: summary, source: .foundationModels)
    #endif
  }

  /// Pick the first `public.file-url` payload and decode it. Clips
  /// can carry multiple URLs but we only summarise the first for S66.
  private func extractFileURL(from item: ClipItem) -> URL? {
    guard
      let payload = item.payloads.first(where: { $0.pasteboardType == "public.file-url" }),
      let data = try? resolver.data(for: payload),
      let string = String(data: data, encoding: .utf8),
      let url = URL(string: string)
    else { return nil }
    return url
  }

  /// Resolve a text payload to a usable String. Tries plain-text
  /// slots first, then falls back to RTF's attributed-string plain
  /// projection so rich text clips produce a meaningful summary.
  private func extractPlainText(from item: ClipItem) -> String? {
    let textTypes = [
      "public.utf8-plain-text", "public.plain-text", "public.string",
      "NSStringPboardType",
    ]
    for type in textTypes {
      if let payload = item.payloads.first(where: { $0.pasteboardType == type }),
        let data = try? resolver.data(for: payload),
        let text = String(data: data, encoding: .utf8),
        !text.isEmpty
      {
        return text
      }
    }
    if let payload = item.payloads.first(where: { $0.pasteboardType == "public.rtf" }),
      let data = try? resolver.data(for: payload),
      let attrib = try? NSAttributedString(
        data: data,
        options: [.documentType: NSAttributedString.DocumentType.rtf],
        documentAttributes: nil
      )
    {
      let plain = attrib.string
      return plain.isEmpty ? nil : plain
    }
    return nil
  }
}
