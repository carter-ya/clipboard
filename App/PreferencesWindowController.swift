import AppKit
import ClipboardCore
import KeyboardShortcuts
import SwiftUI

@MainActor
final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
  private let store: PreferencesStore
  private let onChange: (Preferences) -> Void
  private let onClearHistory: () -> Void
  private let onExportHistory: () -> Void
  private let onImportHistory: () -> Void

  init(
    store: PreferencesStore,
    onChange: @escaping (Preferences) -> Void,
    onClearHistory: @escaping () -> Void,
    onExportHistory: @escaping () -> Void,
    onImportHistory: @escaping () -> Void
  ) {
    self.store = store
    self.onChange = onChange
    self.onClearHistory = onClearHistory
    self.onExportHistory = onExportHistory
    self.onImportHistory = onImportHistory

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Clipboard Preferences"
    super.init(window: window)
    window.delegate = self
    rebuildContent()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("Unavailable")
  }

  func show(anchorRect: NSRect? = nil) {
    // Refresh the persisted prefs view against the OS's real login-item
    // state so we don't lie if the user disabled us in System Settings.
    reconcileLaunchAtLogin()
    rebuildContent()
    // LSUIElement apps can't normally get keyboard focus; temporarily
    // promote activation so KeyboardShortcuts.Recorder etc. work.
    NSApp.setActivationPolicy(.regular)
    if let anchorRect, let window {
      positionWindow(window, centeredOn: anchorRect)
    } else {
      window?.center()
    }
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  /// Place `window` so its center matches the center of `anchor`,
  /// then clamp into the visibleFrame of the screen that contains
  /// the anchor's center (with an 8pt margin so the window never
  /// kisses the menu bar or an edge).
  private func positionWindow(_ window: NSWindow, centeredOn anchor: NSRect) {
    let size = window.frame.size
    let center = NSPoint(x: anchor.midX, y: anchor.midY)
    var origin = NSPoint(
      x: center.x - size.width / 2,
      y: center.y - size.height / 2
    )
    let screen =
      NSScreen.screens.first(where: { $0.frame.contains(center) })
      ?? NSScreen.main
    if let screen {
      let visible = screen.visibleFrame
      origin.x = max(
        visible.minX + 8,
        min(visible.maxX - size.width - 8, origin.x)
      )
      origin.y = max(
        visible.minY + 8,
        min(visible.maxY - size.height - 8, origin.y)
      )
    }
    window.setFrameOrigin(origin)
  }

  private func reconcileLaunchAtLogin() {
    var prefs = store.current
    let systemEnabled = LoginItemController.isEnabled
    if prefs.launchAtLogin != systemEnabled {
      prefs.launchAtLogin = systemEnabled
      store.save(prefs)
    }
  }

  func windowWillClose(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
  }

  private func rebuildContent() {
    let hotkeyMissing = KeyboardShortcuts.getShortcut(for: .toggleHistoryPanel) == nil
    let view = PreferencesView(
      prefs: store.current,
      onSave: { [weak self] prefs in
        self?.store.save(prefs)
        self?.onChange(prefs)
      },
      onClearHistory: { [weak self] in self?.onClearHistory() },
      onExportHistory: { [weak self] in self?.onExportHistory() },
      onImportHistory: { [weak self] in self?.onImportHistory() },
      onApplyLaunchAtLogin: { [weak self] desired in
        guard let self else { return true }
        do {
          try LoginItemController.apply(desired)
          return true
        } catch {
          self.showLaunchAtLoginFailure(error: error)
          return false
        }
      },
      hotkeyMissing: hotkeyMissing
    )
    window?.contentViewController = NSHostingController(rootView: view)
  }

  private func showLaunchAtLoginFailure(error: Error) {
    let alert = NSAlert()
    alert.messageText = "Could not update Start at Login"
    alert.informativeText =
      (error as? LocalizedError)?.errorDescription
      ?? String(describing: error)
    alert.alertStyle = .warning
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }
}
