import Foundation

/// Fanout dispatcher for ClipStore events: each call to `subscribe()`
/// returns its own AsyncStream that receives every yielded event.
/// The stores' mutation paths call `yield(_:)` to deliver to all
/// current subscribers.
///
/// The previous design handed out one shared AsyncStream, which made
/// observers compete — whichever task awaited first consumed the
/// event, so SummaryCoordinator (added in S64) ended up missing
/// inserts the ViewModel's refresh loop had already swallowed.
/// Multi-subscriber broadcast is the cleanest fix.
public final class StoreEventBroadcaster: @unchecked Sendable {
  private var subscribers: [UUID: AsyncStream<StoreEvent>.Continuation] = [:]
  private let lock = NSLock()

  public init() {}

  public func subscribe() -> AsyncStream<StoreEvent> {
    AsyncStream { continuation in
      let id = UUID()
      self.lock.lock()
      self.subscribers[id] = continuation
      self.lock.unlock()
      continuation.onTermination = { [weak self] _ in
        guard let self else { return }
        self.lock.lock()
        self.subscribers.removeValue(forKey: id)
        self.lock.unlock()
      }
    }
  }

  public func yield(_ event: StoreEvent) {
    lock.lock()
    let conts = Array(subscribers.values)
    lock.unlock()
    for cont in conts {
      cont.yield(event)
    }
  }

  public func finish() {
    lock.lock()
    let conts = Array(subscribers.values)
    subscribers.removeAll()
    lock.unlock()
    for cont in conts {
      cont.finish()
    }
  }
}
