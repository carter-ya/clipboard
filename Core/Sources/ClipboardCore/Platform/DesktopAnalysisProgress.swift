import Foundation

public enum DesktopItemAnalysisProgress: Equatable, Sendable {
  case running(remote: Bool)
  case failed(remote: Bool)
}

/// Ephemeral ID/engine metadata only. Deletion, retry and shutdown invalidate
/// prior tickets, including dependencies which ignore task cancellation.
@MainActor public final class DesktopAnalysisProgressState {
  public struct Ticket: Equatable, Sendable {
    public let id: UUID
    public let remote: Bool
    fileprivate let revision: UInt64
  }
  private var entries: [UUID: (Ticket, DesktopItemAnalysisProgress)] = [:]
  private var revision: UInt64 = 0
  private var stopped = false
  private let capacity: Int
  private let changed: @MainActor ([UUID: DesktopItemAnalysisProgress]) -> Void
  public init(
    capacity: Int = 5000,
    changed: @escaping @MainActor ([UUID: DesktopItemAnalysisProgress]) -> Void
  ) {
    precondition(capacity > 0)
    self.capacity = capacity
    self.changed = changed
  }
  public func begin(id: UUID, remote: Bool) -> Ticket? {
    guard !stopped else { return nil }
    if case .running? = entries[id]?.1 { return nil }
    if entries[id] == nil && entries.count >= capacity {
      guard
        let old = entries.first(where: {
          if case .failed = $0.value.1 { return true }
          return false
        })?.key
      else { return nil }
      entries.removeValue(forKey: old)
    }
    revision &+= 1
    let ticket = Ticket(id: id, remote: remote, revision: revision)
    entries[id] = (ticket, .running(remote: remote))
    publish()
    return ticket
  }
  public func isCurrent(_ ticket: Ticket) -> Bool {
    guard !stopped, entries[ticket.id]?.0 == ticket,
      case .running? = entries[ticket.id]?.1
    else { return false }
    return true
  }
  public func finish(_ ticket: Ticket, succeeded: Bool) {
    guard isCurrent(ticket) else { return }
    if succeeded {
      entries.removeValue(forKey: ticket.id)
    } else {
      entries[ticket.id] = (ticket, .failed(remote: ticket.remote))
    }
    publish()
  }
  public func useLocalFallback(_ ticket: Ticket) {
    guard isCurrent(ticket), ticket.remote else { return }
    // Keep the original retry engine, but show the engine currently running.
    entries[ticket.id] = (ticket, .running(remote: false))
    publish()
  }
  public func remove(id: UUID) {
    if entries.removeValue(forKey: id) != nil { publish() }
  }
  public func clear() {
    entries.removeAll()
    publish()
  }
  public func stop() {
    stopped = true
    clear()
  }
  private func publish() { changed(entries.mapValues { $0.1 }) }
}
