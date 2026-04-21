import Foundation

public struct RawClipItem: Sendable {
  public init() {}
}

public protocol ClipboardMonitoring {
  var changes: AsyncStream<RawClipItem> { get }
  func start()
  func stop()
}
