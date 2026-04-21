import AppKit
import ClipboardCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var statusItem: NSStatusItem?
  private var panel: HistoryPanel?
  private var wiring: AppWiring?
  private var preferencesController: PreferencesWindowController?
  private var onboarding: OnboardingController?
  private var pauseMenuItem: NSMenuItem?

  func applicationDidFinishLaunching(_ notification: Notification) {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = item.button {
      let image = NSImage(
        systemSymbolName: "doc.on.clipboard",
        accessibilityDescription: "Clipboard"
      )
      image?.isTemplate = true
      button.image = image
      button.toolTip = "Clipboard"
      button.target = self
      button.action = #selector(statusItemClicked(_:))
      button.sendAction(on: [.leftMouseDown, .rightMouseDown])
    }
    statusItem = item

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

  @MainActor
  @objc private func statusItemClicked(_ sender: Any?) {
    let event = NSApp.currentEvent
    if event?.type == .rightMouseDown {
      showStatusMenu()
    } else {
      togglePanel()
    }
  }

  @MainActor
  private func showStatusMenu() {
    guard let button = statusItem?.button else { return }
    let menu = buildMenu()
    // Pop up directly at the button — do NOT route through
    // statusItem.menu= + performClick. Setting menu inside an action
    // handler either drops the event or recurses into the same
    // action; popUp(positioning:at:in:) is the supported path.
    let origin = NSPoint(x: 0, y: button.bounds.height + 4)
    menu.popUp(positioning: nil, at: origin, in: button)
  }

  @MainActor
  @objc private func togglePanel() {
    preferencesController?.window?.orderOut(nil)
    installPanelIfReady()
    guard let panel else { return }
    guard let vm = wiring?.viewModel else {
      panel.toggle(anchoredTo: statusItem)
      return
    }
    if panel.isVisible {
      panel.close()
      return
    }
    vm.resetSelection()
    panel.toggle(anchoredTo: statusItem)
  }

  @MainActor
  @objc private func showHistory() {
    // Always open (not toggle) — menu entry intent is "bring it up".
    installPanelIfReady()
    guard let panel, let vm = wiring?.viewModel else { return }
    if panel.isVisible { return }
    vm.resetSelection()
    panel.toggle(anchoredTo: statusItem)
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
  @objc private func togglePauseMonitoring() {
    guard let wiring else { return }
    let willPause = !wiring.isMonitoringPaused
    wiring.setMonitoringPaused(willPause)
    updatePauseMenuItemState(paused: willPause)
    if let button = statusItem?.button {
      button.appearsDisabled = willPause
    }
  }

  @MainActor
  @objc private func showOnboarding() {
    if onboarding == nil { onboarding = OnboardingController() }
    onboarding?.show()
  }

  @MainActor
  @objc private func quit() {
    NSApplication.shared.terminate(nil)
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

  @MainActor
  private func buildMenu() -> NSMenu {
    let menu = NSMenu()
    menu.addItem(
      NSMenuItem(title: "Show History", action: #selector(showHistory), keyEquivalent: "")
    )
    menu.addItem(
      NSMenuItem(title: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
    )
    menu.addItem(NSMenuItem.separator())
    let pause = NSMenuItem(
      title: wiring?.isMonitoringPaused == true ? "Resume Monitoring" : "Pause Monitoring",
      action: #selector(togglePauseMonitoring),
      keyEquivalent: ""
    )
    pauseMenuItem = pause
    menu.addItem(pause)
    menu.addItem(
      NSMenuItem(title: "Clear History…", action: #selector(clearHistory), keyEquivalent: "")
    )
    menu.addItem(NSMenuItem.separator())
    menu.addItem(
      NSMenuItem(title: "About Clipboard…", action: #selector(showOnboarding), keyEquivalent: "")
    )
    menu.addItem(NSMenuItem(title: "Quit Clipboard", action: #selector(quit), keyEquivalent: "q"))
    return menu
  }

  @MainActor
  private func updatePauseMenuItemState(paused: Bool) {
    pauseMenuItem?.title = paused ? "Resume Monitoring" : "Pause Monitoring"
  }
}
