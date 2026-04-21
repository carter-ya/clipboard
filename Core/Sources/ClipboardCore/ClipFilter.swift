import Foundation

public struct ClipContext: Sendable {
  public let sourceBundleID: String?
  public let changeCount: Int
  public let timestamp: Date

  public init(sourceBundleID: String?, changeCount: Int, timestamp: Date) {
    self.sourceBundleID = sourceBundleID
    self.changeCount = changeCount
    self.timestamp = timestamp
  }
}

public enum FilterDecision: Sendable, Equatable {
  case accept
  case reject(String)
  case markSensitive(String)
}

public protocol ClipFilter {
  func evaluate(_ item: RawClipItem, context: ClipContext) -> FilterDecision
}
