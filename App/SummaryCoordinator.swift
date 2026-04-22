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
  private let imageSummarizer = VisionImageSummarizer()
  private var task: Task<Void, Never>?

  init(store: any ClipStore, resolver: PayloadResolver, prefsStore: PreferencesStore) {
    self.store = store
    self.resolver = resolver
    self.prefsStore = prefsStore
  }

  func start() {
    stop()
    task = Task { [weak self] in
      guard let self else { return }
      for await event in self.store.events {
        if Task.isCancelled { break }
        if case .inserted(let item) = event {
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
      return
    }

    switch item.kind {
    case .image:
      guard prefs.allowImageSummaries, AICapability.isVisionAvailable else { return }
      await summarizeImage(item)
    case .text, .rtf, .mixed, .file:
      // Text / RTF / Mixed: reserved for Writing Tools (S65) and
      // Foundation Models (S66). File: Foundation Models (S66).
      return
    }
  }

  private func summarizeImage(_ item: ClipItem) async {
    let imageTypes: Set<String> = [
      "public.png", "public.tiff", "public.jpeg", "public.image",
    ]
    guard
      let payload = item.payloads.first(where: { imageTypes.contains($0.pasteboardType) })
    else { return }
    guard let data = try? resolver.data(for: payload) else { return }
    guard let summary = await imageSummarizer.summarize(imageData: data),
      !summary.isEmpty
    else { return }
    await store.updateSummary(id: item.id, summary: summary, source: .vision)
  }
}
