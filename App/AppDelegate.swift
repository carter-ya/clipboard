import AppKit
import ClipboardCore

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var statusItem: NSStatusItem?
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
    }
    statusItem = item

    let wiring = AppWiring()
    self.wiring = wiring
    Task { await wiring.start() }
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
}
