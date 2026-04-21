import Foundation

public enum StoreEvent: Sendable, Equatable {
  case inserted(ClipItem)
  case updated(ClipItem)
  case deleted(UUID)
  case cleared
  case corrupted(path: String, renamedTo: String?)
  case reconciled(orphansDeleted: Int)
  case evicted(id: UUID, sha256: String, blobDeleted: Bool)
}
