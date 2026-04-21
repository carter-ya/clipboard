import AppKit
import ClipboardCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var statusItem: NSStatusItem?
  private var panel: HistoryPanel?
  private var wiring: AppWiring?

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
      button.action = #selector(togglePanel)
    }
    statusItem = item

    let wiring = AppWiring()
    self.wiring = wiring
    Task { @MainActor in
      await wiring.start()
      self.installPanelIfReady()
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
  @objc private func togglePanel() {
    installPanelIfReady()
    panel?.toggle(anchoredTo: statusItem)
  }

  @MainActor
  private func installPanelIfReady() {
    guard panel == nil, let vm = wiring?.viewModel else { return }
    let root = HistoryPanelView(viewModel: vm) { [weak self] in
      self?.panel?.orderOut(nil)
    }
    panel = HistoryPanel(rootView: root)
  }
}
