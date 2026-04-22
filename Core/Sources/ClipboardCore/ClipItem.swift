import Foundation

/// Which on-device engine produced a clip's `summary`. Used by the UI
/// to label the summary with a small badge so users know how it was
/// generated. See AICapability for how availability is detected.
public enum SummarySource: String, Sendable, Codable, Equatable {
  case vision
  case writingTools
  case foundationModels
}

public struct ClipItem: Sendable, Codable, Equatable, Identifiable {
  public var id: UUID
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
  /// On-device generated description/summary of the clip. nil until a
  /// summarizer has run; sensitive items are never summarized.
  public var summary: String?
  /// Which engine produced `summary`. nil iff `summary` is nil.
  public var summarySource: SummarySource?

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
    payloads: [Payload] = [],
    summary: String? = nil,
    summarySource: SummarySource? = nil
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
    self.summary = summary
    self.summarySource = summarySource
  }
}
