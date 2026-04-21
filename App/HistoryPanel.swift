import AppKit
import ClipboardCore
import SwiftUI

@MainActor
final class HistoryPanel: NSPanel {
  var onWillCloseCommit: (() -> Void)?
  var onArrowDown: (() -> Void)?
  var onArrowUp: (() -> Void)?
  /// Fired just before the panel is hidden, carrying the screen the
  /// panel was last on so callers (e.g., AppDelegate) can remember it
  /// as the anchor for auxiliary windows like Preferences.
  var onBeforeClose: ((NSScreen?) -> Void)?
  var suppressNextCloseCommit = false

  private var outsideClickMonitor: Any?
  private var keyMonitor: Any?

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

  func toggle() {
    if isVisible {
      close()
      return
    }
    positionAtCursorScreen()
    makeKeyAndOrderFront(nil)
    startOutsideClickMonitor()
    startKeyMonitor()
  }

  override func close() {
    notifyBeforeCloseIfVisible()
    commitBeforeCloseIfNeeded()
    stopOutsideClickMonitor()
    stopKeyMonitor()
    super.close()
  }

  override func orderOut(_ sender: Any?) {
    notifyBeforeCloseIfVisible()
    commitBeforeCloseIfNeeded()
    stopOutsideClickMonitor()
    stopKeyMonitor()
    super.orderOut(sender)
  }

  private func notifyBeforeCloseIfVisible() {
    guard isVisible else { return }
    onBeforeClose?(screen)
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
      // `.nonactivatingPanel` never activates our app, so AppKit
      // forwards even our own chrome clicks (title bar, close/resize
      // widgets) to the global monitor as "other app" events.
      // Gate on frame containment to keep self-clicks from closing us.
      let location = NSEvent.mouseLocation
      MainActor.assumeIsolated {
        guard self.isVisible else { return }
        if !self.frame.contains(location) {
          self.close()
        }
      }
    }
  }

  private func stopOutsideClickMonitor() {
    if let monitor = outsideClickMonitor {
      NSEvent.removeMonitor(monitor)
      outsideClickMonitor = nil
    }
  }

  private func startKeyMonitor() {
    stopKeyMonitor()
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
      [weak self] event in
      guard let self else { return event }
      // Only intercept events targeting our panel window.
      guard event.window === self else { return event }
      switch event.keyCode {
      case 125:  // down arrow
        MainActor.assumeIsolated { self.onArrowDown?() }
        return nil
      case 126:  // up arrow
        MainActor.assumeIsolated { self.onArrowUp?() }
        return nil
      default:
        return event
      }
    }
  }

  private func stopKeyMonitor() {
    if let monitor = keyMonitor {
      NSEvent.removeMonitor(monitor)
      keyMonitor = nil
    }
  }

  private func positionAtCursorScreen() {
    let panelSize = frame.size
    let mouseLocation = NSEvent.mouseLocation
    let screen =
      NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
      ?? NSScreen.main
      ?? NSScreen.screens.first!
    let visibleFrame = screen.visibleFrame
    let origin = NSPoint(
      x: visibleFrame.midX - panelSize.width / 2,
      y: visibleFrame.midY - panelSize.height / 2
    )
    setFrameOrigin(origin)
  }

  deinit {
    if let monitor = outsideClickMonitor {
      NSEvent.removeMonitor(monitor)
    }
    if let monitor = keyMonitor {
      NSEvent.removeMonitor(monitor)
    }
  }
}
