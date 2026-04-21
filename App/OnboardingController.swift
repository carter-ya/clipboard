import AppKit
import SwiftUI

@MainActor
final class OnboardingController {
  private static let defaultsKey = "hasSeenOnboarding"
  private var window: NSWindow?

  func showIfFirstRun() {
    if UserDefaults.standard.bool(forKey: Self.defaultsKey) { return }
    show()
  }

  func show() {
    let view = OnboardingView { [weak self] in
      UserDefaults.standard.set(true, forKey: Self.defaultsKey)
      self?.window?.orderOut(nil)
      self?.window = nil
    }
    let hosting = NSHostingController(rootView: view)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = "Welcome"
    window.contentViewController = hosting
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    self.window = window
  }
}
