import Foundation

/// Pure `.accept`-emitting filter kept for tests that need an
/// always-accept passthrough independent of the real
/// SensitivityFilter / BlocklistFilter config.
public struct AlwaysAcceptFilter: ClipFilter {
  public init() {}

  public func evaluate(_ item: RawClipItem, context: ClipContext) -> FilterDecision {
    .accept
  }
}
