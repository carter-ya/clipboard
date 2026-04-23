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
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 408),
      styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.title = String(localized: "Clipboard Preferences")
    // fullSizeContentView + titlebarAppearsTransparent let the
    // SwiftUI body's regularMaterial flow under the title bar, so the
    // whole window reads as one continuous glass pane. The title bar
    // still carries traffic lights and the window title on top. The
    // SwiftUI view reserves the top 28pt manually via a VStack spacer
    // so body content can't scroll up into the title bar region.
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true
    window.titlebarAppearsTransparent = true
    // Don't let macOS auto-restore last-known frame — the state
    // machine otherwise wrestles with our setFrameOrigin in show()
    // and the window drifts (it ends up parked in the upper-right
    // corner every second open).
    window.isRestorable = false
    super.init(window: window)
    window.delegate = self
    rebuildContent()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("Unavailable")
  }

  func show() {
    // Refresh the persisted prefs view against the OS's real login-item
    // state so we don't lie if the user disabled us in System Settings.
    reconcileLaunchAtLogin()
    rebuildContent()
    // LSUIElement apps can't normally get keyboard focus; temporarily
    // promote activation so KeyboardShortcuts.Recorder etc. work.
    NSApp.setActivationPolicy(.regular)
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    // Position AFTER orderFront so AppKit's own cascading / state
    // restoration has already run; our setFrameOrigin is the last
    // word on placement.
    if let window {
      centerOnCursorScreen(window)
    }
    // Drop the auto-picked first responder so the Language Picker (or
    // any other control in tab order) doesn't show a focus ring on
    // first open. The user can still click or tab into any control.
    window?.makeFirstResponder(nil)
  }

  /// Center the window on the visibleFrame of the screen under the
  /// cursor — matches HistoryPanel's own positioning convention and
  /// gives a predictable placement regardless of where any other
  /// window happened to be last.
  private func centerOnCursorScreen(_ window: NSWindow) {
    let mouse = NSEvent.mouseLocation
    let screen =
      NSScreen.screens.first(where: { $0.frame.contains(mouse) })
      ?? NSScreen.main
      ?? NSScreen.screens.first!
    let visible = screen.visibleFrame
    let size = window.frame.size
    let origin = NSPoint(
      x: visible.midX - size.width / 2,
      y: visible.midY - size.height / 2
    )
    window.setFrameOrigin(origin)
    Log.ui.info(
      "prefs.center screen=\(visible.debugDescription, privacy: .public) mouse=(\(mouse.x),\(mouse.y)) size=(\(size.width),\(size.height)) origin=(\(origin.x),\(origin.y))"
    )
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
      onApplyLanguage: { [weak self] code in
        self?.applyLanguageOverride(code)
      },
      hotkeyMissing: hotkeyMissing
    )
    window?.contentViewController = NSHostingController(rootView: view)
  }

  private func applyLanguageOverride(_ code: String?) {
    if let code {
      UserDefaults.standard.set([code], forKey: "AppleLanguages")
    } else {
      UserDefaults.standard.removeObject(forKey: "AppleLanguages")
    }
  }

  private func showLaunchAtLoginFailure(error: Error) {
    let alert = NSAlert()
    alert.messageText = String(localized: "Could not update Start at Login")
    alert.informativeText =
      (error as? LocalizedError)?.errorDescription
      ?? String(describing: error)
    alert.alertStyle = .warning
    alert.addButton(withTitle: String(localized: "OK"))
    alert.runModal()
  }
}
