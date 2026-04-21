import AppKit
import SwiftUI

/// Small SwiftUI wrapper around an NSButton so we can hand the
/// underlying NSView to NSMenu.popUpContextMenu as the anchor.
struct OverflowMenuButton: NSViewRepresentable {
  let onShowMenu: (NSView) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onShowMenu: onShowMenu)
  }

  func makeNSView(context: Context) -> NSButton {
    let button = NSButton()
    button.bezelStyle = .accessoryBar
    button.isBordered = false
    button.image = NSImage(
      systemSymbolName: "ellipsis.circle",
      accessibilityDescription: "More actions"
    )
    button.imagePosition = .imageOnly
    button.target = context.coordinator
    button.action = #selector(Coordinator.tapped(_:))
    button.setAccessibilityLabel("More actions")
    return button
  }

  func updateNSView(_ nsView: NSButton, context: Context) {
    context.coordinator.onShowMenu = onShowMenu
  }

  final class Coordinator: NSObject {
    var onShowMenu: (NSView) -> Void

    init(onShowMenu: @escaping (NSView) -> Void) {
      self.onShowMenu = onShowMenu
    }

    @objc func tapped(_ sender: NSButton) {
      onShowMenu(sender)
    }
  }
}
