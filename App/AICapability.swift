import Foundation

/// Runtime feature gates for the on-device summary engines.
///
/// The original plan had three tiers — Vision / Writing Tools /
/// Foundation Models. Writing Tools turned out to be UI-only
/// (`WritingToolsCoordinator` wants an NSTextView and a user action),
/// so it can't power background summarization. The "baseline text"
/// role moved to the NaturalLanguage framework, which is always
/// available on our macOS 13 floor. Foundation Models (macOS 26 +
/// Apple Silicon) still stands in as the "richer" layer when
/// available.
enum AICapability {
  /// Vision framework — image OCR + classification. Always available
  /// on macOS 13+.
  static var isVisionAvailable: Bool { true }

  /// NaturalLanguage framework — language detection + named entity
  /// extraction. Always available on macOS 13+.
  static var isNaturalLanguageAvailable: Bool { true }

  /// Foundation Models — on-device ~3B LLM. Requires macOS 26+ and
  /// Apple Silicon. The actual framework import is deferred to S66.
  static var isFoundationModelsAvailable: Bool {
    #if arch(arm64)
      if #available(macOS 26.0, *) {
        // S66 will replace this placeholder with a real availability
        // check against SystemLanguageModel.default.availability once
        // the FoundationModels framework is linked.
        return true
      }
    #endif
    return false
  }
}
