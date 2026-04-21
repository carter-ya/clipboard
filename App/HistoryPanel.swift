import AppKit
import ClipboardCore
import SwiftUI

@MainActor
final class HistoryPanel: NSPanel {
  /// Called just before the panel is hidden via any close path
  /// (Esc, outside click, X button, re-toggle). The implementation
  /// is expected to consult the view model's current selection and
  /// activate (write-to-pasteboard) it. Set
  /// `suppressNextCloseCommit` immediately before a known-to-be-
  /// already-committed close path (e.g., the explicit ↵ handler) to
  /// avoid double-firing.
  var onWillCloseCommit: (() -> Void)?

  /// One-shot flag: the next close path will skip onWillCloseCommit.
  var suppressNextCloseCommit = false

  private var outsideClickMonitor: Any?

  init(rootView: some View) {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
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
    close()
  }

  func toggle(anchoredTo statusItem: NSStatusItem?) {
    if isVisible {
      close()
      return
    }
    positionNear(statusItem: statusItem)
    makeKeyAndOrderFront(nil)
    startOutsideClickMonitor()
  }

  override func close() {
    commitBeforeCloseIfNeeded()
    stopOutsideClickMonitor()
    super.close()
  }

  override func orderOut(_ sender: Any?) {
    commitBeforeCloseIfNeeded()
    stopOutsideClickMonitor()
    super.orderOut(sender)
  }

  private func commitBeforeCloseIfNeeded() {
    guard isVisible else { return }
    if suppressNextCloseCommit {
      suppressNextCloseCommit = false
      return
    }
    onWillCloseCommit?()
  }

  private func startOutsideClickMonitor() {
    stopOutsideClickMonitor()
    outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown]
    ) { [weak self] _ in
      guard let self else { return }
      MainActor.assumeIsolated {
        if self.isVisible { self.close() }
      }
    }
  }

  private func stopOutsideClickMonitor() {
    if let monitor = outsideClickMonitor {
      NSEvent.removeMonitor(monitor)
      outsideClickMonitor = nil
    }
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

  deinit {
    if let monitor = outsideClickMonitor {
      NSEvent.removeMonitor(monitor)
    }
  }
}
