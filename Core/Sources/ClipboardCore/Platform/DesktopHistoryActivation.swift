/// A native history activation may dismiss only the presentation which started
/// its successful copy. Late completions cannot close a newer page or session.
@MainActor public final class DesktopHistoryActivationState {
  public private(set) var busy = false
  private var revision: UInt64 = 0
  private var stopped = false
  public init() {}
  public func invalidatePresentation() { revision &+= 1 }
  public func stop() {
    stopped = true
    invalidatePresentation()
  }
  public func activate(copy: @MainActor () async -> Bool) async -> Bool {
    guard !busy, !stopped, !Task.isCancelled else { return false }
    let expected = revision
    busy = true
    defer { busy = false }
    let succeeded = await copy()
    return succeeded && !stopped && !Task.isCancelled && revision == expected
  }
}
