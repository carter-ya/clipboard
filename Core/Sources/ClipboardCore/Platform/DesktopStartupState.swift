/// Keeps passive system reads separate from explicit startup mutations. UI
/// consumers can refresh on native lifecycle events without rebuilding drafts.
@MainActor public final class DesktopStartupState {
  public private(set) var enabled = false
  public private(set) var busy = false
  private let backend: any DesktopStartupControlling
  private let changed: @MainActor (Bool, Bool) -> Void
  private var revision: UInt64 = 0
  private var refreshPending = false
  private var stopped = false

  public init(
    backend: any DesktopStartupControlling,
    changed: @escaping @MainActor (Bool, Bool) -> Void
  ) {
    self.backend = backend
    self.changed = changed
  }

  public func refresh() async throws {
    guard !stopped else { return }
    if busy {
      refreshPending = true
      return
    }
    revision &+= 1
    let request = revision
    do {
      let value = try await backend.isEnabled()
      guard !stopped, request == revision, !busy else { return }
      if value != enabled {
        enabled = value
        changed(enabled, busy)
      }
    } catch {
      guard !stopped, request == revision, !busy else { return }
      throw error
    }
  }

  /// The desired value comes from the visible control, preserving user intent
  /// even if the system changes between its last refresh and the click.
  @discardableResult public func apply(_ desired: Bool) async throws -> Bool {
    guard !stopped, !busy else { return false }
    revision &+= 1
    busy = true
    changed(enabled, busy)
    do {
      try await backend.setEnabled(desired)
      let value = try await backend.isEnabled()
      guard !stopped else { return false }
      enabled = value
    } catch {
      guard !stopped else { return false }
      busy = false
      refreshPending = false
      changed(enabled, busy)
      throw error
    }
    busy = false
    changed(enabled, busy)
    let needsRefresh = refreshPending
    refreshPending = false
    if needsRefresh { try await refresh() }
    return !stopped
  }

  public func stop() {
    stopped = true
    revision &+= 1
    refreshPending = false
    busy = false
  }
}
