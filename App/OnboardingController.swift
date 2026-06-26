import AppKit
import SwiftUI

@MainActor
final class OnboardingController {
  private static let defaultsKey = "hasSeenOnboarding"
  private let onDismiss: (() -> Void)?
  private var window: NSWindow?

  init(onDismiss: (() -> Void)? = nil) {
    self.onDismiss = onDismiss
  }

  func showIfFirstRun() -> Bool {
    if UserDefaults.standard.bool(forKey: Self.defaultsKey) { return false }
    show()
    return true
  }

  func show() {
    let view = OnboardingView { [weak self] in
      UserDefaults.standard.set(true, forKey: Self.defaultsKey)
      self?.window?.orderOut(nil)
      self?.window = nil
      self?.onDismiss?()
    }
    let hosting = NSHostingController(rootView: view)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = String(localized: "Welcome")
    window.contentViewController = hosting
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    self.window = window
  }
}
