import AppKit
import ClipboardCore
import SwiftUI

@MainActor
enum AppearanceController {
  static func apply(_ appearance: AppAppearance) {
    switch appearance {
    case .system: NSApp.appearance = nil
    case .light: NSApp.appearance = NSAppearance(named: .aqua)
    case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
    }
  }
}

enum HistoryPanelLayout {
  static let width: CGFloat = 760
  static let height: CGFloat = 520
  static let listWidth: CGFloat = 440
  static let cornerRadius: CGFloat = 20

  static func size(fitting visibleSize: NSSize) -> NSSize {
    NSSize(width: min(width, visibleSize.width), height: min(height, visibleSize.height))
  }
}

enum PreferencesLayout {
  static let width: CGFloat = 560
  static let height: CGFloat = 440
}

/// Search controls sit on the window's single native backdrop. Adding
/// another glass here would sample the panel instead of the desktop.
private struct SearchSurface: ViewModifier {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast

  private let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

  @ViewBuilder
  func body(content: Content) -> some View {
    if reduceTransparency || contrast == .increased {
      content
        .background(Color(nsColor: .controlBackgroundColor), in: shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.35), lineWidth: 1))
    } else {
      content
        .background(Color.primary.opacity(0.035), in: shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
    }
  }
}

extension View {
  func clipboardSearchSurface() -> some View {
    modifier(SearchSurface())
  }
}
