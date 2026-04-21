import Foundation

public protocol ClipboardMonitoring {
  var changes: AsyncStream<RawClipItem> { get }
  /// Events emitted whenever a clip is rejected by the filter chain
  /// (currently: SizeFilter tooLarge). The UI uses this to surface
  /// feedback like "skipped 18 MB image from Finder".
  var skips: AsyncStream<SkipEvent> { get }
  func start()
  func stop()
}
