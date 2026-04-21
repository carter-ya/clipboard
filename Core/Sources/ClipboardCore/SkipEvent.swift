import Foundation

/// Published by `ClipboardMonitoring.skips` whenever a clip is
/// `.reject`-ed by the filter chain. The UI uses the latest event
/// to tell the user why their copy never made it into the history.
public struct SkipEvent: Sendable, Equatable {
  public let reason: String
  public let bytes: Int
  public let limit: Int
  public let types: [String]
  public let bundleID: String?
  public let timestamp: Date

  public init(
    reason: String,
    bytes: Int,
    limit: Int,
    types: [String],
    bundleID: String?,
    timestamp: Date = Date()
  ) {
    self.reason = reason
    self.bytes = bytes
    self.limit = limit
    self.types = types
    self.bundleID = bundleID
    self.timestamp = timestamp
  }
}
