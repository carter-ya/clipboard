import Foundation

public protocol ClipboardMonitoring {
  var changes: AsyncStream<RawClipItem> { get }
  func start()
  func stop()
}
