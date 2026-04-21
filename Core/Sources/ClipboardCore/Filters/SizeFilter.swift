import Foundation

public struct SizeFilter: ClipFilter {
  public let maxClipSizeBytes: Int

  public init(maxClipSizeBytes: Int) {
    self.maxClipSizeBytes = maxClipSizeBytes
  }

  public func evaluate(_ item: RawClipItem, context: ClipContext) -> FilterDecision {
    guard maxClipSizeBytes > 0 else { return .accept }
    if item.totalBytes > maxClipSizeBytes {
      return .reject("tooLarge")
    }
    return .accept
  }
}
