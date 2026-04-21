import Foundation

public struct ClipItem: Sendable, Codable, Equatable, Identifiable {
  public let id: UUID
  public var createdAt: Date
  public var kind: ClipKind
  public var preview: String
  public var sha256: String
  public var sizeBytes: Int
  public var pinned: Bool
  public var sensitive: Bool
  public var sensitivityReason: String?
  public var sourceBundleID: String?
  public var payloads: [Payload]

  public init(
    id: UUID = UUID(),
    createdAt: Date,
    kind: ClipKind,
    preview: String,
    sha256: String,
    sizeBytes: Int,
    pinned: Bool = false,
    sensitive: Bool = false,
    sensitivityReason: String? = nil,
    sourceBundleID: String? = nil,
    payloads: [Payload] = []
  ) {
    self.id = id
    self.createdAt = createdAt
    self.kind = kind
    self.preview = preview
    self.sha256 = sha256
    self.sizeBytes = sizeBytes
    self.pinned = pinned
    self.sensitive = sensitive
    self.sensitivityReason = sensitivityReason
    self.sourceBundleID = sourceBundleID
    self.payloads = payloads
  }
}
