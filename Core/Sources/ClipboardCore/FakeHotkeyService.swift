import Foundation
import KeyboardShortcuts

public final class FakeHotkeyService: HotkeyService, @unchecked Sendable {
  public let events: AsyncStream<Void>
  public let bindingStatus: AsyncStream<BindingStatus>

  private let eventsContinuation: AsyncStream<Void>.Continuation
  private let statusContinuation: AsyncStream<BindingStatus>.Continuation
  public private(set) var boundName: KeyboardShortcuts.Name?

  public init() {
    let (eventsStream, eventsContinuation) = AsyncStream.makeStream(of: Void.self)
    self.events = eventsStream
    self.eventsContinuation = eventsContinuation

    let (statusStream, statusContinuation) = AsyncStream.makeStream(
      of: BindingStatus.self
    )
    self.bindingStatus = statusStream
    self.statusContinuation = statusContinuation
  }

  public func bind(_ name: KeyboardShortcuts.Name) {
    boundName = name
    statusContinuation.yield(.ok)
  }

  public func unbind() {
    boundName = nil
    statusContinuation.yield(.unbound)
  }

  public func fire() {
    eventsContinuation.yield(())
  }

  public func simulateConflict(reason: String) {
    statusContinuation.yield(.conflict(reason))
  }
}
