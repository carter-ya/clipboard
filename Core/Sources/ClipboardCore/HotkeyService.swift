import Foundation

public enum BindingStatus: Sendable, Equatable {
  case ok
  case conflict(String)
}

public protocol HotkeyService {
  var events: AsyncStream<Void> { get }
  var bindingStatus: AsyncStream<BindingStatus> { get }
}
