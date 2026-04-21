import AppKit
import ClipboardCore
import SwiftUI

@MainActor
final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
  private let store: PreferencesStore
  private let onChange: (Preferences) -> Void
  private let onClearHistory: () -> Void
  private let onExportHistory: () -> Void

  init(
    store: PreferencesStore,
    onChange: @escaping (Preferences) -> Void,
    onClearHistory: @escaping () -> Void,
    onExportHistory: @escaping () -> Void
  ) {
    self.store = store
    self.onChange = onChange
    self.onClearHistory = onClearHistory
    self.onExportHistory = onExportHistory

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

  func show() {
    rebuildContent()
    // LSUIElement apps can't normally get keyboard focus; temporarily
    // promote activation so KeyboardShortcuts.Recorder etc. work.
    NSApp.setActivationPolicy(.regular)
    window?.center()
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func windowWillClose(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
  }

  private func rebuildContent() {
    let view = PreferencesView(
      prefs: store.current,
      onSave: { [weak self] prefs in
        self?.store.save(prefs)
        self?.onChange(prefs)
      },
      onClearHistory: { [weak self] in self?.onClearHistory() },
      onExportHistory: { [weak self] in self?.onExportHistory() }
    )
    window?.contentViewController = NSHostingController(rootView: view)
  }
}
