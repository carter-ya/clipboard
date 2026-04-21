import Foundation

public struct NoOpSensitivityFilter: ClipFilter {
  public init() {}

  public func evaluate(_ item: RawClipItem, context: ClipContext) -> FilterDecision {
    .accept
  }
}

public struct NoOpBlocklistFilter: ClipFilter {
  public init() {}

  public func evaluate(_ item: RawClipItem, context: ClipContext) -> FilterDecision {
    .accept
  }
}
