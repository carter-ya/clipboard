import ClipboardCore
import Foundation

@MainActor
final class AppWiring {
  let monitor: any ClipboardMonitoring
  private(set) var store: (any ClipStore)?
  private var consumerTask: Task<Void, Never>?
  private let maxClipSizeBytes: Int
  private let cap: Int

  init(maxClipSizeBytes: Int = 10 * 1024 * 1024, cap: Int = 100) {
    self.maxClipSizeBytes = maxClipSizeBytes
    self.cap = cap
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

  func start() async {
    do {
      let root = try AppPaths.defaultStoreRoot()
      let store = try await JSONSnapshotClipStore(root: root, cap: cap)
      self.store = store
      consumerTask = Task { [monitor, store] in
        for await raw in monitor.changes {
          await store.insert(raw)
        }
      }
      monitor.start()
      Log.ui.info("app.launched{root:\(root.path, privacy: .public)}")
    } catch {
      Log.ui.error(
        "app.launchFailed err=\(String(describing: error), privacy: .public)"
      )
    }
  }

  func stop() async {
    monitor.stop()
    consumerTask?.cancel()
    consumerTask = nil
    await store?.flush()
  }
}
