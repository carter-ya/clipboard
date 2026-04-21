import AppKit
import SwiftUI

@MainActor
final class HistoryPanel: NSPanel {
  init(rootView: some View) {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
      styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    title = "Clipboard"
    isFloatingPanel = true
    isReleasedWhenClosed = false
    hidesOnDeactivate = false
    becomesKeyOnlyIfNeeded = true
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

    let hosting = NSHostingController(rootView: rootView)
    contentViewController = hosting
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  override func cancelOperation(_ sender: Any?) {
    orderOut(nil)
  }

  func toggle(anchoredTo statusItem: NSStatusItem?) {
    if isVisible {
      orderOut(nil)
      return
    }
    positionNear(statusItem: statusItem)
    makeKeyAndOrderFront(nil)
  }

  private func positionNear(statusItem: NSStatusItem?) {
    guard let button = statusItem?.button,
      let buttonWindow = button.window
    else {
      center()
      return
    }
    let buttonRectInScreen = buttonWindow.convertToScreen(
      button.convert(button.bounds, to: nil)
    )
    let panelSize = frame.size
    let screen = screen(for: buttonRectInScreen) ?? NSScreen.main ?? NSScreen.screens.first!
    let visibleFrame = screen.visibleFrame
    var origin = NSPoint(
      x: buttonRectInScreen.midX - panelSize.width / 2,
      y: buttonRectInScreen.minY - panelSize.height - 6
    )
    origin.x = max(visibleFrame.minX + 8, min(visibleFrame.maxX - panelSize.width - 8, origin.x))
    origin.y = max(visibleFrame.minY + 8, origin.y)
    setFrameOrigin(origin)
  }

  private func screen(for rect: NSRect) -> NSScreen? {
    NSScreen.screens.first { $0.frame.intersects(rect) }
  }
}
