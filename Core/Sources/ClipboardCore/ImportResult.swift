import Foundation

public struct ImportResult: Sendable, Equatable {
  public let added: Int
  public let skipped: Int
  public let blobsMissing: Int

  public init(added: Int, skipped: Int, blobsMissing: Int) {
    self.added = added
    self.skipped = skipped
    self.blobsMissing = blobsMissing
  }
}
