import Foundation

public struct RawPayload: Sendable, Equatable {
  public let pasteboardType: String
  public let data: Data

  public init(pasteboardType: String, data: Data) {
    self.pasteboardType = pasteboardType
    self.data = data
  }
}

public struct RawClipItem: Sendable, Equatable {
  public var payloads: [RawPayload]
  public var bundleID: String?
  public var changeCount: Int
  public var totalBytes: Int
  public var timestamp: Date
  public var isSensitive: Bool
  public var sensitivityReason: String?

  public init(
    payloads: [RawPayload] = [],
    bundleID: String? = nil,
    changeCount: Int = 0,
    totalBytes: Int = 0,
    timestamp: Date = Date(),
    isSensitive: Bool = false,
    sensitivityReason: String? = nil
  ) {
    self.payloads = payloads
    self.bundleID = bundleID
    self.changeCount = changeCount
    self.totalBytes = totalBytes
    self.timestamp = timestamp
    self.isSensitive = isSensitive
    self.sensitivityReason = sensitivityReason
  }

  public var types: [String] {
    payloads.map(\.pasteboardType)
  }
}
