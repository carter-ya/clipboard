import Foundation

public struct FilterChain: ClipFilter {
  public let filters: [any ClipFilter]

  public init(filters: [any ClipFilter]) {
    self.filters = filters
  }

  public func evaluate(_ item: RawClipItem, context: ClipContext) -> FilterDecision {
    for filter in filters {
      let decision = filter.evaluate(item, context: context)
      switch decision {
      case .accept:
        continue
      case .reject, .markSensitive:
        return decision
      }
    }
    return .accept
  }
}
