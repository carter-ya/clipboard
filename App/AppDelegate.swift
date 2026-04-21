import AppKit
import ClipboardCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var panel: HistoryPanel?
  private var wiring: AppWiring?
  private var preferencesController: PreferencesWindowController?
  private var onboarding: OnboardingController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    let wiring = AppWiring()
    wiring.onHotkey = { [weak self] in
      MainActor.assumeIsolated {
        self?.togglePanel()
      }
    }
    wiring.onStoreCorrupted = { [weak self] path in
      MainActor.assumeIsolated {
        self?.notifyCorruptionRecovery(path: path)
      }
    }
    self.wiring = wiring
    Task { @MainActor in
      await wiring.start()
      self.installPanelIfReady()
      let onboarding = OnboardingController()
      self.onboarding = onboarding
      onboarding.showIfFirstRun()
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    guard let wiring else { return }
    let semaphore = DispatchSemaphore(value: 0)
    Task {
      await wiring.stop()
      semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 2.0)
  }

  /// Relaunching the app (double-click Clipboard.app from Finder /
  /// Dock / Spotlight) opens Preferences — the only fallback path
  /// we offer now that there is no menu bar icon.
  func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    openPreferences()
    return true
  }

  @MainActor
  @objc private func togglePanel() {
    preferencesController?.window?.orderOut(nil)
    installPanelIfReady()
    guard let panel else { return }
    if panel.isVisible {
      panel.close()
      return
    }
    wiring?.viewModel?.resetSelection()
    panel.toggle()
  }

  @MainActor
  @objc private func openPreferences() {
    panel?.close()
    installPreferencesIfReady()
    preferencesController?.show()
  }

  @MainActor
  @objc private func clearHistory() {
    let alert = NSAlert()
    alert.messageText = "Clear all clipboard history?"
    alert.informativeText = "Pinned items will also be removed. This cannot be undone."
    alert.addButton(withTitle: "Clear")
    alert.addButton(withTitle: "Cancel")
    alert.alertStyle = .warning
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    guard let wiring else { return }
    Task { await wiring.clearHistory() }
  }

  @MainActor
  private func notifyCorruptionRecovery(path: String) {
    let alert = NSAlert()
    alert.messageText = "History was recovered from a backup"
    alert.informativeText =
      "The original file appeared corrupted and has been renamed to history.json.bak. "
      + "Clipboard started with an empty history."
    alert.alertStyle = .informational
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }

  @MainActor
  private func installPanelIfReady() {
    guard panel == nil, let wiring = wiring, let vm = wiring.viewModel else { return }
    let root = HistoryPanelView(
      viewModel: vm,
      thumbnailLoader: wiring.thumbnailLoader,
      resolver: wiring.payloadResolver,
      onClose: { [weak self] in
        self?.panel?.close()
      },
      onActivate: { [weak self] item in
        self?.panel?.suppressNextCloseCommit = true
        wiring.activate(item)
        self?.panel?.close()
      },
      onTogglePin: { item in
        Task { await vm.togglePin(item) }
      },
      onDelete: { item in
        Task { await vm.delete(item) }
      },
      onShowPreferences: { [weak self] in
        MainActor.assumeIsolated {
          self?.panel?.suppressNextCloseCommit = true
          self?.openPreferences()
        }
      }
    )
    let panel = HistoryPanel(rootView: root)
    panel.onWillCloseCommit = { [weak self] in
      guard let self,
        let vm = self.wiring?.viewModel,
        let id = vm.selectedID,
        let item = vm.filteredItems.first(where: { $0.id == id })
      else { return }
      self.wiring?.activate(item)
    }
    panel.onArrowDown = { [weak vm] in vm?.selectNext() }
    panel.onArrowUp = { [weak vm] in vm?.selectPrevious() }
    self.panel = panel
  }

  @MainActor
  private func installPreferencesIfReady() {
    guard preferencesController == nil, let wiring else { return }
    preferencesController = PreferencesWindowController(
      store: wiring.preferencesStore,
      onChange: { prefs in wiring.applyPreferences(prefs) },
      onClearHistory: { [weak self] in self?.clearHistory() },
      onExportHistory: { [weak self] in self?.exportHistory() }
    )
  }

  @MainActor
  private func exportHistory() {
    let savePanel = NSSavePanel()
    savePanel.nameFieldStringValue = "clipboard-history.json"
    savePanel.allowedContentTypes = [.json]
    guard savePanel.runModal() == .OK, let url = savePanel.url else { return }
    do {
      let source = try AppPaths.defaultStoreRoot().appendingPathComponent("history.json")
      if FileManager.default.fileExists(atPath: source.path) {
        if FileManager.default.fileExists(atPath: url.path) {
          try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.copyItem(at: source, to: url)
      } else {
        try Data("{\"version\":1,\"items\":[]}".utf8).write(to: url)
      }
    } catch {
      Log.ui.error("export.failed err=\(String(describing: error), privacy: .public)")
    }
  }
}
