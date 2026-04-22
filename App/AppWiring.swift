import ClipboardCore
import Foundation
import KeyboardShortcuts

@MainActor
final class AppWiring {
  let hotkey: any HotkeyService
  let preferencesStore: PreferencesStore
  private(set) var monitor: (any ClipboardMonitoring)?
  private(set) var store: (any ClipStore)?
  private(set) var viewModel: HistoryPanelViewModel?
  private(set) var pasteboardWriter: (any PasteboardWriting)?
  private(set) var thumbnailLoader: ThumbnailLoader?
  private(set) var payloadResolver: PayloadResolver?
  private(set) var summaryCoordinator: SummaryCoordinator?

  private var consumerTask: Task<Void, Never>?
  private var skipTask: Task<Void, Never>?
  private var hotkeyTask: Task<Void, Never>?
  private var storeEventsTask: Task<Void, Never>?
  private var blobRoot: URL?
  private(set) var isMonitoringPaused: Bool = false

  var onHotkey: (() -> Void)?
  var onStoreCorrupted: ((String) -> Void)?
  var onHotkeyUnbound: (() -> Void)?

  init() {
    self.preferencesStore = PreferencesStore.shared
    self.hotkey = KeyboardShortcutsHotkeyService()
  }

  func start() async {
    do {
      let root = try AppPaths.defaultStoreRoot()
      let prefs = preferencesStore.current
      let blobRoot = root.appendingPathComponent("blobs")
      self.blobRoot = blobRoot

      let store = try await JSONSnapshotClipStore(root: root, cap: prefs.cap)
      self.store = store

      self.pasteboardWriter = NSPasteboardWriter(blobRoot: blobRoot)
      self.thumbnailLoader = ThumbnailLoader(blobRoot: blobRoot)
      let payloadResolver = PayloadResolver(blobRoot: blobRoot)
      self.payloadResolver = payloadResolver

      let vm = HistoryPanelViewModel(store: store)
      vm.start()
      self.viewModel = vm

      installMonitor(prefs: prefs)
      startHotkey()
      startStoreEventObserver()
      reconcileLoginItem(desired: prefs.launchAtLogin)

      let summaryCoordinator = SummaryCoordinator(
        store: store,
        resolver: payloadResolver,
        prefsStore: preferencesStore
      )
      summaryCoordinator.start()
      self.summaryCoordinator = summaryCoordinator

      Log.ui.info("app.launched{root:\(root.path, privacy: .public)}")
    } catch {
      Log.ui.error(
        "app.launchFailed err=\(String(describing: error), privacy: .public)"
      )
    }
  }

  func stop() async {
    monitor?.stop()
    consumerTask?.cancel()
    consumerTask = nil
    skipTask?.cancel()
    skipTask = nil
    hotkey.unbind()
    hotkeyTask?.cancel()
    hotkeyTask = nil
    storeEventsTask?.cancel()
    storeEventsTask = nil
    summaryCoordinator?.stop()
    summaryCoordinator = nil
    viewModel?.stop()
    await store?.flush()
  }

  func setMonitoringPaused(_ paused: Bool) {
    isMonitoringPaused = paused
    if paused {
      monitor?.stop()
    } else {
      monitor?.start()
    }
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
    // Bump to top synchronously so the UI reflects the new order on
    // the next panel open without waiting for the monitor's poll
    // tick to re-observe the clipboard.
    if let store = self.store {
      Task { await store.bumpToTop(id: item.id) }
    }
  }

  /// Rebuild the monitor + filter chain using the current preferences.
  /// Called both on startup and when the user edits prefs.
  func applyPreferences(_ prefs: Preferences) {
    monitor?.stop()
    consumerTask?.cancel()
    installMonitor(prefs: prefs)
  }

  func clearHistory() async {
    await store?.clearAll()
  }

  private func installMonitor(prefs: Preferences) {
    let chain = FilterChain(filters: [
      SizeFilter(maxClipSizeBytes: prefs.maxClipSizeBytes),
      SensitivityFilter(skipSensitive: prefs.skipSensitive),
      BlocklistFilter(blockedBundleIDs: Set(prefs.blockedBundleIDs)),
    ])
    let monitor = NSPasteboardMonitor(
      filter: chain,
      maxClipSizeBytes: prefs.maxClipSizeBytes
    )
    self.monitor = monitor
    if let store = self.store {
      consumerTask = Task {
        for await raw in monitor.changes {
          await store.insert(raw)
        }
      }
    }
    skipTask = Task { [monitor] in
      for await skip in monitor.skips {
        await MainActor.run {
          self.viewModel?.recordSkip(skip)
        }
      }
    }
    monitor.start()
  }

  private func startHotkey() {
    if KeyboardShortcuts.getShortcut(for: .toggleHistoryPanel) == nil {
      Log.hotkey.info("hotkey.unbound user has no shortcut configured")
      onHotkeyUnbound?()
      return
    }
    hotkey.bind(.toggleHistoryPanel)
    hotkeyTask = Task { [hotkey] in
      for await _ in hotkey.events {
        await MainActor.run {
          self.onHotkey?()
        }
      }
    }
  }

  /// Nudge the OS to match the user's saved preference at launch.
  /// If the user toggled "Start at Login" off in System Settings,
  /// `LoginItemController.isEnabled` will be false and we'll write
  /// that back so the Preferences panel displays the real state
  /// next time it opens. Errors here are non-fatal (we just log).
  private func reconcileLoginItem(desired: Bool) {
    if LoginItemController.isEnabled == desired { return }
    do {
      try LoginItemController.apply(desired)
    } catch {
      Log.ui.info(
        "login_item.apply_failed err=\(String(describing: error), privacy: .public)"
      )
      var prefs = preferencesStore.current
      prefs.launchAtLogin = LoginItemController.isEnabled
      preferencesStore.save(prefs)
    }
  }

  private func startStoreEventObserver() {
    guard let store = self.store else { return }
    storeEventsTask = Task { [store] in
      for await event in store.events {
        switch event {
        case .corrupted(let path, _):
          await MainActor.run {
            self.onStoreCorrupted?(path)
          }
        default:
          break
        }
      }
    }
  }
}
