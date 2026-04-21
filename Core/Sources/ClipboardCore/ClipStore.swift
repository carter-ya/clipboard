import Foundation

public struct ClipItem: Sendable, Identifiable {
  public let id: UUID

  public init(id: UUID = UUID()) {
    self.id = id
  }
}

public protocol ClipStore {
}
