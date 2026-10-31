import Foundation

/// Serializes settings snapshots across asynchronous persistence without dropping clicks.
@MainActor
public final class DesktopSettingsSaveGate {
  private var held = false
  private var waiting: [CheckedContinuation<Void, Never>] = []
  public init() {}

  /// Pair every acquired lease with `defer { release() }` on the same actor.
  public func acquire() async {
    if !held {
      held = true
      return
    }
    await withCheckedContinuation { waiting.append($0) }
  }

  public func release() {
    precondition(held)
    if waiting.isEmpty {
      held = false
    } else {
      waiting.removeFirst().resume()
    }
  }
}
