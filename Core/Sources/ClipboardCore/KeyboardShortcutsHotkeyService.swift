import Foundation
import KeyboardShortcuts

public final class KeyboardShortcutsHotkeyService: HotkeyService, @unchecked Sendable {
  public let events: AsyncStream<Void>
  public let bindingStatus: AsyncStream<BindingStatus>

  private let eventsContinuation: AsyncStream<Void>.Continuation
  private let statusContinuation: AsyncStream<BindingStatus>.Continuation
  private var boundName: KeyboardShortcuts.Name?

  public init() {
    let (eventsStream, eventsContinuation) = AsyncStream.makeStream(of: Void.self)
    self.events = eventsStream
    self.eventsContinuation = eventsContinuation

    let (statusStream, statusContinuation) = AsyncStream.makeStream(
      of: BindingStatus.self
    )
    self.bindingStatus = statusStream
    self.statusContinuation = statusContinuation
    statusContinuation.yield(.unbound)
  }

  public func bind(_ name: KeyboardShortcuts.Name) {
    unbind()
    boundName = name
    KeyboardShortcuts.onKeyUp(for: name) { [weak self] in
      self?.eventsContinuation.yield(())
    }
    Log.hotkey.info(
      "hotkey.bound name=\(name.rawValue, privacy: .public)"
    )
    statusContinuation.yield(.ok)
  }

  public func unbind() {
    if let name = boundName {
      KeyboardShortcuts.disable(name)
      boundName = nil
      statusContinuation.yield(.unbound)
    }
  }

  deinit {
    eventsContinuation.finish()
    statusContinuation.finish()
  }
}
