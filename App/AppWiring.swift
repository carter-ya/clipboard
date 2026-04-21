import ClipboardCore
import Foundation

@MainActor
final class AppWiring {
  let monitor: any ClipboardMonitoring
  private var consumerTask: Task<Void, Never>?

  init(maxClipSizeBytes: Int = 10 * 1024 * 1024) {
    let chain = FilterChain(filters: [
      SizeFilter(maxClipSizeBytes: maxClipSizeBytes),
      NoOpSensitivityFilter(),
      NoOpBlocklistFilter(),
    ])
    self.monitor = NSPasteboardMonitor(
      filter: chain,
      maxClipSizeBytes: maxClipSizeBytes
    )
  }

  func start() {
    monitor.start()
    consumerTask = Task { [monitor] in
      for await item in monitor.changes {
        Log.ui.debug(
          "consumed item changeCount=\(item.changeCount, privacy: .public) sensitive=\(item.isSensitive, privacy: .public)"
        )
      }
    }
  }

  func stop() {
    monitor.stop()
    consumerTask?.cancel()
    consumerTask = nil
  }
}
