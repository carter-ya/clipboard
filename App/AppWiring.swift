import ClipboardCore
import Foundation
import KeyboardShortcuts

@MainActor
final class AppWiring {
  let monitor: any ClipboardMonitoring
  let hotkey: any HotkeyService
  private(set) var store: (any ClipStore)?
  private(set) var viewModel: HistoryPanelViewModel?
  private(set) var pasteboardWriter: (any PasteboardWriting)?

  private var consumerTask: Task<Void, Never>?
  private var hotkeyTask: Task<Void, Never>?

  private let maxClipSizeBytes: Int
  private let cap: Int
  var onHotkey: (() -> Void)?

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
    self.hotkey = KeyboardShortcutsHotkeyService()
  }

  func start() async {
    do {
      let root = try AppPaths.defaultStoreRoot()
      let store = try await JSONSnapshotClipStore(root: root, cap: cap)
      self.store = store
      self.pasteboardWriter = NSPasteboardWriter(
        blobRoot: root.appendingPathComponent("blobs")
      )

      let vm = HistoryPanelViewModel(store: store)
      vm.start()
      self.viewModel = vm

      consumerTask = Task { [monitor, store] in
        for await raw in monitor.changes {
          await store.insert(raw)
        }
      }
      monitor.start()

      hotkey.bind(.toggleHistoryPanel)
      hotkeyTask = Task { [hotkey] in
        for await _ in hotkey.events {
          await MainActor.run {
            self.onHotkey?()
          }
        }
      }

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
    hotkey.unbind()
    hotkeyTask?.cancel()
    hotkeyTask = nil
    viewModel?.stop()
    await store?.flush()
  }

  func activate(_ item: ClipItem) {
    guard let writer = pasteboardWriter else { return }
    do {
      try writer.write(item)
    } catch {
      Log.paste.error(
        "paste.failed err=\(String(describing: error), privacy: .public)"
      )
    }
  }
}
