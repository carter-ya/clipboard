import Foundation

/// Runtime feature gates for the three on-device summary engines.
/// Each generator slice (S64 Vision / S65 Writing Tools / S66
/// Foundation Models) will call into these flags so the preference
/// toggles can surface accurate enabled/disabled state for the user.
///
/// Vision is treated as always available on our macOS 13 minimum.
/// Writing Tools need macOS 15.1 and the user's Apple Intelligence
/// entitlement. Foundation Models need macOS 26 and Apple Silicon;
/// the actual framework import stays out of this file until S66 so
/// build-time requirements don't leak ahead of when they're needed.
enum AICapability {
  static var isVisionAvailable: Bool { true }

  static var isWritingToolsAvailable: Bool {
    if #available(macOS 15.1, *) {
      return true
    }
    return false
  }

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
