import Foundation

/// Serializes automatic work without retaining clipboard payloads in the queue.
@MainActor
public final class DesktopAnalysisScheduler {
  public struct Request: Equatable, Sendable {
    public let id: UUID
    public let remote: Bool
    public let automatic: Bool
    public init(id: UUID, remote: Bool, automatic: Bool) {
      self.id = id
      self.remote = remote
      self.automatic = automatic
    }

    /// Evaluate against the current item and preferences when work begins.
    public func isAllowed(item: ClipItem, settings: DesktopSettings) -> Bool {
      guard item.id == id, !item.sensitive,
        !item.payloads.contains(where: { $0.pasteboardType == SensitivityFilter.concealedType })
      else { return false }
      if remote && !settings.ai.allowsSummary(of: item.kind) { return false }
      if !remote && item.kind != .image {
        if item.kind == .file {
          guard settings.localFileSummariesEnabled else { return false }
        } else {
          guard settings.localTextSummariesEnabled, [.text, .rtf, .mixed].contains(item.kind)
          else { return false }
        }
      }
      guard automatic else { return true }
      guard item.summary == nil else { return false }
      if remote {
        return settings.automaticSummaries
      }
      if item.kind == .file { return settings.automaticLocalFileSummaries }
      return item.kind == .image ? settings.automaticOCR : settings.automaticLocalSummaries
    }
    public func localFallback(item: ClipItem, settings: DesktopSettings) -> Request? {
      guard remote, isAllowed(item: item, settings: settings) else { return nil }
      let local = Request(id: id, remote: false, automatic: automatic)
      return local.isAllowed(item: item, settings: settings) ? local : nil
    }
  }
  public enum Submission: Equatable { case started, queued, duplicate, full, busy, stopped }
  public private(set) var isBusy = false
  public var pendingCount: Int { pending.count }
  public var currentRequest: Request? { current }
  private let capacity: Int
  private let perform: @MainActor (Request) async -> Void
  private let busyChanged: @MainActor (Bool) -> Void
  private var pending: [Request] = []
  private var current: Request?
  private var task: Task<Void, Never>?
  private var stopped = false

  public init(
    capacity: Int = 64,
    busyChanged: @escaping @MainActor (Bool) -> Void = { _ in },
    perform: @escaping @MainActor (Request) async -> Void
  ) {
    precondition(capacity > 0)
    self.capacity = capacity
    self.busyChanged = busyChanged
    self.perform = perform
  }

  @discardableResult
  public func submit(_ request: Request) -> Submission {
    guard !stopped else { return .stopped }
    if !request.automatic && isBusy { return .busy }
    guard current?.id != request.id, !pending.contains(where: { $0.id == request.id }) else {
      return .duplicate
    }
    if isBusy {
      guard pending.count < capacity else { return .full }
      pending.append(request)
      return .queued
    }
    start(request)
    return .started
  }

  public func cancel(id: UUID) {
    pending.removeAll { $0.id == id }
    if current?.id == id { task?.cancel() }
  }
  public func beginLocalFallback(item: ClipItem, settings: DesktopSettings) -> Request? {
    guard !stopped, !Task.isCancelled,
      let fallback = current?.localFallback(item: item, settings: settings)
    else { return nil }
    current = fallback
    return fallback
  }
  public func cancelAll() {
    pending.removeAll()
    task?.cancel()
  }
  @discardableResult public func recheckCurrent(
    id: UUID, item: ClipItem?, settings: DesktopSettings
  ) -> Bool {
    guard let request = current, request.id == id else { return false }
    if let item, request.isAllowed(item: item, settings: settings) { return false }
    task?.cancel()
    return true
  }

  public func stop() {
    stopped = true
    pending.removeAll()
    task?.cancel()
  }

  private func start(_ request: Request) {
    current = request
    if !isBusy {
      isBusy = true
      busyChanged(true)
    }
    task = Task { [weak self] in
      guard let self else { return }
      await self.perform(request)
      if !self.stopped && !self.pending.isEmpty {
        self.start(self.pending.removeFirst())
      } else {
        self.current = nil
        self.task = nil
        self.isBusy = false
        self.busyChanged(false)
      }
    }
  }

  deinit { task?.cancel() }
}
