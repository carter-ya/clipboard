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
  private let remoteFactory: @Sendable (Preferences) -> RemoteOpenAISummarizer?
  private var task: Task<Void, Never>?

  /// Stream of per-clip progress transitions the UI subscribes to.
  /// Single-consumer (the panel VM) — a plain `AsyncStream` is
  /// sufficient; no broadcaster needed. Events emitted after
  /// `stop()` finishes the continuation are dropped silently;
  /// acceptable because `stop()` is only called at app teardown.
  let progressEvents: AsyncStream<SummaryProgressEvent>
  private let progressContinuation: AsyncStream<SummaryProgressEvent>.Continuation

  /// Tracks clip ids whose summarisation is mid-flight. Prevents a
  /// Retry click from firing a second remote network request while
  /// the first attempt is still running ("bail-not-queue": the
  /// second invocation is a silent no-op and the existing spinner
  /// persists).
  private var inFlight: Set<UUID> = []

  init(
    store: any ClipStore,
    resolver: PayloadResolver,
    prefsStore: PreferencesStore,
    imageSummarizer: any ImageSummarizer = VisionImageSummarizer(),
    textSummarizer: any TextSummarizer = NaturalLanguageTextSummarizer(),
    remoteFactory: @escaping @Sendable (Preferences) -> RemoteOpenAISummarizer? = { _ in nil }
  ) {
    self.store = store
    self.resolver = resolver
    self.prefsStore = prefsStore
    self.imageSummarizer = imageSummarizer
    self.textSummarizer = textSummarizer
    self.remoteFactory = remoteFactory
    var continuation: AsyncStream<SummaryProgressEvent>.Continuation!
    self.progressEvents = AsyncStream { continuation = $0 }
    self.progressContinuation = continuation
  }

  /// Hard gate: clips whose pasteboard advertised
  /// `org.nspasteboard.ConcealedType` (the cross-app convention used
  /// by 1Password, Bitwarden, etc.) must never leave the device,
  /// regardless of `prefs.skipSensitive` / `item.sensitive`. This is
  /// the second filter on top of the sensitivity gate the coordinator
  /// already applies in `handle(_:)`.
  private func isConcealed(_ item: ClipItem) -> Bool {
    item.payloads.contains { $0.pasteboardType == SensitivityFilter.concealedType }
  }

  func start() {
    // Cancel any prior observer task but do NOT finish the progress
    // stream's continuation here — that would kill the VM subscriber
    // loop on every `start()`. The continuation is intentionally only
    // finished by `stop()`, which runs at app teardown.
    task?.cancel()
    task = nil
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
    progressContinuation.finish()
  }

  // MARK: - Progress tracking helpers

  /// Returns true if the attempt was newly registered. False means
  /// another attempt for the same clip id is still in flight; the
  /// caller should bail (no event emitted, no work scheduled).
  private func beginAttempt(_ id: UUID, engine: SummarySource) -> Bool {
    guard !inFlight.contains(id) else { return false }
    inFlight.insert(id)
    progressContinuation.yield(.started(id: id, engine: engine))
    return true
  }

  /// Mirror of `beginAttempt`: clear the in-flight flag and emit
  /// either `.finished` (engine wrote a summary) or `.failed`
  /// (waterfall exhausted). Always called from a `defer` paired
  /// with a `var succeeded` set just before the success return.
  private func endAttempt(_ id: UUID, succeeded: Bool) {
    inFlight.remove(id)
    progressContinuation.yield(succeeded ? .finished(id: id) : .failed(id: id))
  }

  /// The engine the waterfall will try first for `kind`, given the
  /// current prefs and remote-summarizer availability. Used solely
  /// to label the `.started` event so the preview pane can show the
  /// right badge (Remote / FM / NL / Vision) while the request is
  /// in flight.
  private func firstAttemptedEngine(
    for kind: ClipKind,
    prefs: Preferences,
    remote: RemoteOpenAISummarizer?
  ) -> SummarySource {
    switch kind {
    case .image:
      if remote != nil, prefs.remoteAIAllowImages { return .remoteOpenAI }
      return .vision
    case .text, .rtf, .mixed:
      if remote != nil { return .remoteOpenAI }
      if AICapability.isFoundationModelsAvailable { return .foundationModels }
      return .naturalLanguage
    case .file:
      if remote != nil { return .remoteOpenAI }
      return .foundationModels
    }
  }

  /// Re-run the engine waterfall for a clip whose previous attempt
  /// failed. The `beginAttempt` guard inside `summarize*` is the
  /// in-flight protection: clicking Retry while the original
  /// attempt is still running is a silent no-op (the existing
  /// spinner persists).
  func retry(_ item: ClipItem) async {
    let prefs = prefsStore.current
    guard prefs.summariesEnabled, !item.sensitive else { return }
    let remote = remoteFactory(prefs)
    switch item.kind {
    case .image:
      guard prefs.allowImageSummaries else { return }
      await summarizeImage(item, prefs: prefs, remote: remote)
    case .text, .rtf, .mixed:
      guard prefs.allowTextSummaries else { return }
      await summarizeText(item, prefs: prefs, remote: remote)
    case .file:
      guard prefs.allowFileSummaries else { return }
      await summarizeFile(item, prefs: prefs, remote: remote)
    }
  }

  private func handle(_ item: ClipItem) async {
    let prefs = prefsStore.current
    guard prefs.summariesEnabled, !item.sensitive, item.summary == nil else {
      Log.ui.info(
        "summary.skip id=\(item.id.uuidString, privacy: .public) reason=gated kind=\(item.kind.rawValue, privacy: .public) enabled=\(prefs.summariesEnabled) sensitive=\(item.sensitive) hasSummary=\(item.summary != nil)"
      )
      return
    }

    // Build the remote summarizer once per clip; passed into all three
    // kind-specific helpers so we don't re-read prefs / re-construct
    // the summarizer twice on the file path's gate + waterfall.
    let remote = remoteFactory(prefs)

    switch item.kind {
    case .image:
      guard prefs.allowImageSummaries, AICapability.isVisionAvailable else {
        Log.ui.info(
          "summary.skip id=\(item.id.uuidString, privacy: .public) reason=image-disabled allow=\(prefs.allowImageSummaries) vision=\(AICapability.isVisionAvailable)"
        )
        return
      }
      await summarizeImage(item, prefs: prefs, remote: remote)
    case .text, .rtf, .mixed:
      guard prefs.allowTextSummaries else {
        Log.ui.info(
          "summary.skip id=\(item.id.uuidString, privacy: .public) reason=text-disabled"
        )
        return
      }
      await summarizeText(item, prefs: prefs, remote: remote)
    case .file:
      guard prefs.allowFileSummaries else {
        Log.ui.info(
          "summary.skip id=\(item.id.uuidString, privacy: .public) reason=file-disabled allow=\(prefs.allowFileSummaries)"
        )
        return
      }
      guard AICapability.isFoundationModelsAvailable || remote != nil else {
        Log.ui.info(
          "summary.skip id=\(item.id.uuidString, privacy: .public) reason=file-no-engine fm=\(AICapability.isFoundationModelsAvailable) remote=\(remote != nil)"
        )
        return
      }
      await summarizeFile(item, prefs: prefs, remote: remote)
    }
  }

  private func summarizeImage(
    _ item: ClipItem,
    prefs: Preferences,
    remote: RemoteOpenAISummarizer?
  ) async {
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
    let engine = firstAttemptedEngine(for: item.kind, prefs: prefs, remote: remote)
    guard beginAttempt(item.id, engine: engine) else { return }
    var succeeded = false
    defer { endAttempt(item.id, succeeded: succeeded) }
    Log.ui.info(
      "summary.image.start id=\(item.id.uuidString, privacy: .public) bytes=\(data.count)"
    )
    // Remote leg: only fires when the user explicitly enabled image
    // sharing AND the clip is not concealed. Failure (or skipped
    // remote) falls through to the on-device Vision path below.
    if isConcealed(item) {
      Log.ui.info(
        "summary.remote.skip reason=concealed id=\(item.id.uuidString, privacy: .public)"
      )
    } else if prefs.remoteAIAllowImages, let remote {
      Log.ui.info(
        "summary.remote.image.attempt id=\(item.id.uuidString, privacy: .public)"
      )
      if let summary = await remote.summarize(imageData: data), !summary.isEmpty {
        Log.ui.info(
          "summary.image.remote id=\(item.id.uuidString, privacy: .public) len=\(summary.count)"
        )
        await store.updateSummary(id: item.id, summary: summary, source: .remoteOpenAI)
        succeeded = true
        return
      }
    }
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
    succeeded = true
  }

  private func summarizeText(
    _ item: ClipItem,
    prefs: Preferences,
    remote: RemoteOpenAISummarizer?
  ) async {
    guard let text = extractPlainText(from: item) else {
      Log.ui.info(
        "summary.text.noPayload id=\(item.id.uuidString, privacy: .public)"
      )
      return
    }
    let engine = firstAttemptedEngine(for: item.kind, prefs: prefs, remote: remote)
    guard beginAttempt(item.id, engine: engine) else { return }
    var succeeded = false
    defer { endAttempt(item.id, succeeded: succeeded) }
    Log.ui.info(
      "summary.text.start id=\(item.id.uuidString, privacy: .public) chars=\(text.count)"
    )
    // Remote leg of the fixed remote → FM → NL waterfall. Concealed
    // pasteboard items skip the remote hop entirely. Remote failure
    // (nil / empty) falls through to the on-device chain below; the
    // local code paths are untouched.
    if isConcealed(item) {
      Log.ui.info(
        "summary.remote.skip reason=concealed id=\(item.id.uuidString, privacy: .public)"
      )
    } else if let remote {
      Log.ui.info(
        "summary.remote.text.attempt id=\(item.id.uuidString, privacy: .public)"
      )
      if let summary = await remote.summarize(text: text), !summary.isEmpty {
        Log.ui.info(
          "summary.text.remote id=\(item.id.uuidString, privacy: .public) len=\(summary.count)"
        )
        await store.updateSummary(
          id: item.id, summary: summary, source: .remoteOpenAI)
        succeeded = true
        return
      }
      // fall through on remote failure
    }
    // Prefer Foundation Models when available — the LLM produces a
    // real sentence, while NaturalLanguage can only list entities.
    if #available(macOS 26.0, *), AICapability.isFoundationModelsAvailable {
      let fm = FoundationModelsSummarizer(responseLanguage: resolvedLanguage(prefs))
      if let summary = await fm.summarize(text: text), !summary.isEmpty {
        Log.ui.info(
          "summary.text.fm id=\(item.id.uuidString, privacy: .public) len=\(summary.count)"
        )
        await store.updateSummary(
          id: item.id, summary: summary, source: .foundationModels)
        succeeded = true
        return
      }
    }
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
    succeeded = true
  }

  private func summarizeFile(
    _ item: ClipItem,
    prefs: Preferences,
    remote: RemoteOpenAISummarizer?
  ) async {
    guard let url = extractFileURL(from: item) else {
      let types = item.payloads.map(\.pasteboardType).joined(separator: ",")
      Log.ui.info(
        "summary.file.noURL id=\(item.id.uuidString, privacy: .public) types=\(types, privacy: .public)"
      )
      return
    }
    let engine = firstAttemptedEngine(for: item.kind, prefs: prefs, remote: remote)
    guard beginAttempt(item.id, engine: engine) else { return }
    var succeeded = false
    defer { endAttempt(item.id, succeeded: succeeded) }
    Log.ui.info(
      "summary.file.start id=\(item.id.uuidString, privacy: .public) ext=\(url.pathExtension.lowercased(), privacy: .public)"
    )

    // Remote first when available and the clip isn't concealed.
    // Concealed clips never go remote — FM-only fallback below.
    if !isConcealed(item), let remote {
      Log.ui.info(
        "summary.remote.file.attempt id=\(item.id.uuidString, privacy: .public)"
      )
      if let summary = await remote.summarize(
        fileURL: url, maxBodyBytes: prefs.maxClipSizeBytes),
        !summary.isEmpty
      {
        Log.ui.info(
          "summary.file.remote id=\(item.id.uuidString, privacy: .public) len=\(summary.count)"
        )
        await store.updateSummary(
          id: item.id, summary: summary, source: .remoteOpenAI)
        succeeded = true
        return
      }
    }

    if #available(macOS 26.0, *), AICapability.isFoundationModelsAvailable {
      let fm = FoundationModelsSummarizer(responseLanguage: resolvedLanguage(prefs))
      if let summary = await fm.summarizeFile(url: url), !summary.isEmpty {
        Log.ui.info(
          "summary.file.fm id=\(item.id.uuidString, privacy: .public) len=\(summary.count)"
        )
        await store.updateSummary(
          id: item.id, summary: summary, source: .foundationModels)
        succeeded = true
        return
      }
    }

    Log.ui.info(
      "summary.file.empty engine=none id=\(item.id.uuidString, privacy: .public)"
    )
  }

  private func resolvedLanguage(_ prefs: Preferences) -> String? {
    remoteAIResponseLanguageName(for: prefs.languageOverride)
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
