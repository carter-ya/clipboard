import Foundation

#if canImport(FoundationModels)
  import FoundationModels
#endif

/// Runtime feature gates for the on-device summary engines.
///
/// The original plan had three tiers — Vision / Writing Tools /
/// Foundation Models. Writing Tools turned out to be UI-only
/// (`WritingToolsCoordinator` wants an NSTextView and a user action),
/// so it can't power background summarization. The "baseline text"
/// role moved to the NaturalLanguage framework, which is always
/// available on our macOS 13 floor. Foundation Models (macOS 26 +
/// Apple Silicon) stands in as the "richer" layer when available and
/// Apple Intelligence is set up.
enum AICapability {
  /// Vision framework — image OCR + classification. Always available
  /// on macOS 13+.
  static var isVisionAvailable: Bool { true }

  /// NaturalLanguage framework — language detection + named entity
  /// extraction. Always available on macOS 13+.
  static var isNaturalLanguageAvailable: Bool { true }

  /// Foundation Models — on-device ~3B LLM. Requires macOS 26+ on an
  /// Apple Silicon device with Apple Intelligence enabled. The real
  /// availability check lives inside a @available-gated helper so the
  /// FoundationModels symbols never load on older systems.
  static var isFoundationModelsAvailable: Bool {
    #if arch(arm64)
      if #available(macOS 26.0, *) {
        return FoundationModelsAvailability.isActive
      }
    #endif
    return false
  }
}

@available(macOS 26.0, *)
private enum FoundationModelsAvailability {
  static var isActive: Bool {
    switch SystemLanguageModel.default.availability {
    case .available:
      return true
    case .unavailable:
      return false
    }
  }
}
