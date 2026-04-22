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
    // fullSizeContentView + titlebarAppearsTransparent let the SwiftUI
    // material extend under the title bar for unified glass. The body
    // itself is bounded to the safe area (below the title bar) via
    // .frame(maxWidth/maxHeight: .infinity), so scrolling content
    // can't bleed up into the title bar.
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true
    window.titlebarAppearsTransparent = true
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
    // Drop the auto-picked first responder so the Language Picker (or
    // any other control in tab order) doesn't show a focus ring on
    // first open. The user can still click or tab into any control.
    window?.makeFirstResponder(nil)
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
      onApplyLanguage: { [weak self] code in
        self?.applyLanguageOverride(code)
      },
      hotkeyMissing: hotkeyMissing
    )
    let hosting = NSHostingController(rootView: view)
    // Opt out of SwiftUI-driven sizing. macOS 14+ defaults to
    // .standardBounds (which reads intrinsicContentSize from the
    // SwiftUI root). If the root uses .frame(maxWidth/maxHeight:
    // .infinity), intrinsic is zero and AppKit collapses the window.
    hosting.sizingOptions = []
    window?.contentViewController = hosting
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
