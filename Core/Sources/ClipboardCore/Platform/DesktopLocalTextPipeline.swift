import Foundation

/// Fixed fallback order; each phase needs its own explicit permission. Installing
/// a model grants no content-processing permission and never changes this order.
public enum DesktopLocalTextEngine: String, CaseIterable, Equatable, Sendable {
  case generative
  case language
  case excerpt

  public func isAllowed(item: ClipItem, settings: DesktopSettings, automatic: Bool) -> Bool {
    guard !item.sensitive,
      !item.payloads.contains(where: { $0.pasteboardType == SensitivityFilter.concealedType }),
      [.text, .rtf, .mixed, .file].contains(item.kind),
      !automatic || item.summary == nil
    else { return false }
    if item.kind == .file {
      guard settings.localFileSummariesEnabled,
        !automatic || settings.automaticLocalFileSummaries
      else { return false }
    }
    switch self {
    case .generative:
      return settings.localGenerativeSummariesEnabled
        && (!automatic || settings.automaticLocalGenerativeSummaries)
    case .language:
      return settings.localLanguageSummariesEnabled
        && (!automatic || settings.automaticLocalLanguageSummaries)
    case .excerpt:
      return item.kind == .file
        || (settings.localTextSummariesEnabled && (!automatic || settings.automaticLocalSummaries))
    }
  }
}

/// Runs in the caller's owned task. Reads fresh item/permission metadata before
/// model resolution, before payload access and after inference. It never writes
/// history or downloads assets; the caller remains the single summary write site.
@MainActor public enum DesktopLocalTextPipeline {
  public struct Context: Sendable {
    public let item: ClipItem
    public let settings: DesktopSettings
    public init(item: ClipItem, settings: DesktopSettings) {
      self.item = item
      self.settings = settings
    }
  }
  public struct Result: Equatable, Sendable {
    public let text: String
    public let engine: DesktopLocalTextEngine
    public let inputTruncated: Bool
  }
  public static func run(
    id: UUID, automatic: Bool, language: String? = nil,
    context: @MainActor () async -> Context?,
    service: @MainActor (DesktopLocalTextEngine) async throws -> DesktopAnalysis,
    began: @MainActor (DesktopLocalTextEngine) -> Void = { _ in }
  ) async throws -> Result {
    var lastError: any Error = DesktopServiceError.disabled
    func allowed(_ value: Context?, _ engine: DesktopLocalTextEngine) -> ClipItem? {
      guard let value, value.item.id == id,
        engine.isAllowed(item: value.item, settings: value.settings, automatic: automatic)
      else { return nil }
      return value.item
    }
    for engine in DesktopLocalTextEngine.allCases {
      try Task.checkCancellation()
      guard allowed(await context(), engine) != nil else { continue }
      try Task.checkCancellation()
      do {
        let analyzer = try await service(engine)
        try Task.checkCancellation()
        guard let item = allowed(await context(), engine) else { continue }
        try Task.checkCancellation()
        began(engine)
        let text: String
        let truncated: Bool
        switch engine {
        case .generative, .language:
          let result = try await analyzer.analyzeLanguageLocally(
            item, task: engine == .generative ? .summary : .enrichment, language: language)
          text = result.text
          truncated = result.inputTruncated
        case .excerpt:
          text = try await analyzer.summarizeLocally(item)
          truncated = false
        }
        try Task.checkCancellation()
        guard allowed(await context(), engine) != nil else { continue }
        try Task.checkCancellation()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          throw DesktopServiceError.invalidValue
        }
        return Result(text: text, engine: engine, inputTruncated: truncated)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        try Task.checkCancellation()
        lastError = error
      }
    }
    try Task.checkCancellation()
    throw lastError
  }
}
