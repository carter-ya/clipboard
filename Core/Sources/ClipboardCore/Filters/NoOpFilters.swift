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

// Legacy names that S1 put into place — aliased here so tests and
// external callers that already wired through NoOp*Filter keep
// compiling during the S7 transition. New code should prefer
// `SensitivityFilter(skipSensitive: false)` / `BlocklistFilter(blockedBundleIDs: [])`
// (or `AlwaysAcceptFilter`) instead.
public typealias NoOpSensitivityFilter = AlwaysAcceptFilter
public typealias NoOpBlocklistFilter = AlwaysAcceptFilter
