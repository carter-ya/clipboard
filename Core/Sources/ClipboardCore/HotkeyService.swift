import Foundation
import KeyboardShortcuts

public enum BindingStatus: Sendable, Equatable {
  case ok
  case conflict(String)
  case unbound
}

public protocol HotkeyService {
  var events: AsyncStream<Void> { get }
  var bindingStatus: AsyncStream<BindingStatus> { get }
  func bind(_ name: KeyboardShortcuts.Name)
  func unbind()
}

extension KeyboardShortcuts.Name {
  public static let toggleHistoryPanel = Self(
    "toggleHistoryPanel",
    default: .init(.v, modifiers: [.option, .command])
  )
}
