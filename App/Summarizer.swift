import Foundation

/// Produces a one-line natural-language summary for a clipboard text
/// snippet. Conformers live in the App layer because the concrete
/// engines (Foundation Models, NaturalLanguage) are UI-side concerns
/// that stay out of ClipboardCore. `SummaryCoordinator` dispatches
/// through this protocol so it can swap engines without knowing which
/// framework is actually doing the work.
protocol TextSummarizer: Sendable {
  /// Returns nil when the input is too short / empty, or when the
  /// underlying engine declined to produce a summary. Callers treat
  /// nil as "try the next engine".
  func summarize(text: String) async -> String?
}

/// Produces a one-line natural-language summary for an image clip's
/// raw bytes. Vision is the only conformer today; Writing Tools or a
/// future multimodal Foundation Models call would slot in the same
/// way.
protocol ImageSummarizer: Sendable {
  /// Returns nil when decoding failed outright. Engines are expected
  /// to fall back to a placeholder ("Image (w×h)") rather than nil
  /// whenever they can still produce *something* for the preview
  /// pane.
  func summarize(imageData: Data) async -> String?
}
