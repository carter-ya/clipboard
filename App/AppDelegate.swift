import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var statusItem: NSStatusItem?

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
  }
}
