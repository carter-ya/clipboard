import Foundation

/// Serializes automatic work without retaining clipboard payloads in the queue.
@MainActor
public final class DesktopAnalysisScheduler {
  public struct Request: Equatable, Sendable {
    public let id: UUID
    public let remote: Bool
    public let automatic: Bool
    public let imageSummary: Bool
    public let localTextEngine: DesktopLocalTextEngine?
    public let localTextModel: DesktopModelKind?
    public init(
      id: UUID, remote: Bool, automatic: Bool, imageSummary: Bool = false,
      localTextEngine: DesktopLocalTextEngine? = nil, localTextModel: DesktopModelKind? = nil
    ) {
      self.id = id
      self.remote = remote
      self.automatic = automatic
      self.imageSummary = imageSummary
      self.localTextEngine = localTextEngine
      self.localTextModel = localTextModel
    }

    /// Evaluate against the current item and preferences when work begins.
    public func isAllowed(item: ClipItem, settings: DesktopSettings) -> Bool {
      guard !(remote && imageSummary), !imageSummary || item.kind == .image,
        item.id == id, !item.sensitive,
        !item.payloads.contains(where: { $0.pasteboardType == SensitivityFilter.concealedType })
      else { return false }
      if remote && !settings.ai.allowsSummary(of: item.kind) { return false }
      if !remote && item.kind != .image {
        return (localTextEngine.map { [$0] } ?? DesktopLocalTextEngine.allCases).contains {
          $0.isAllowed(item: item, settings: settings, automatic: automatic)
        }
      }
      guard automatic else { return true }
      guard item.summary == nil else { return false }
      if remote {
        return settings.automaticSummaries
      }
      if item.kind == .file { return settings.automaticLocalFileSummaries }
      if imageSummary { return settings.automaticOCR && settings.automaticLocalImageSummaries }
      return item.kind == .image ? settings.automaticOCR : settings.automaticLocalSummaries
    }
    public func usesOptionalModel(_ kind: DesktopModelKind) -> Bool {
      guard !remote, !imageSummary else { return false }
      return localTextModel == kind
    }
    public func localFallback(item: ClipItem, settings: DesktopSettings) -> Request? {
      guard remote, isAllowed(item: item, settings: settings) else { return nil }
      let local = Request(id: id, remote: false, automatic: automatic)
      return local.isAllowed(item: item, settings: settings) ? local : nil
    }
  }
  public enum Submission: Equatable { case started, queued, duplicate, full, busy, stopped }
  /// A pause owns the exclusion until its specific lease is resumed. Callers
  /// must use defer to resume even if their model operation fails or is cancelled.
  public struct Pause: Equatable, Sendable { fileprivate let id: UUID }
  private var pauses: Set<UUID> = []
  public var isPaused: Bool { !pauses.isEmpty }
  var pauseCount: Int { pauses.count }
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
    guard !isPaused else { return .busy }
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
  /// The pipeline calls this immediately before the selected phase accesses
  /// content, so live settings revocation cancels the exact owned engine.
  public func beginLocalTextPhase(
    _ engine: DesktopLocalTextEngine, id: UUID, model: DesktopModelKind?
  ) -> Bool {
    let validModel: Bool
    switch engine {
    case .generative: validModel = model == .generative
    case .language: validModel = model == nil || model == .entities
    case .excerpt: validModel = model == nil
    }
    guard validModel, !stopped, !isPaused, !Task.isCancelled, let active = current,
      active.id == id, !active.remote, !active.imageSummary
    else { return false }
    current = .init(
      id: id, remote: false, automatic: active.automatic, localTextEngine: engine,
      localTextModel: model)
    return true
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

  /// Exclude new work before awaiting a selected active task. By default discard
  /// pending work and cancel everything. Model maintenance can retain the queue
  /// and unrelated engines. A selected dependency must release its file/process
  /// even if it ignores cancellation; overlapping callers own separate leases.
  public func pauseAndDrain(
    preservingPending: Bool = false,
    cancelCurrent: @MainActor (Request) -> Bool = { _ in true }
  ) async -> Pause {
    let pause = Pause(id: UUID())
    pauses.insert(pause.id)
    if !preservingPending { pending.removeAll() }
    if let current, cancelCurrent(current) {
      task?.cancel()
      let active = task
      await active?.value
    }
    return pause
  }
  public func resume(_ pause: Pause) {
    guard pauses.remove(pause.id) != nil, !isPaused, !stopped, !isBusy, !pending.isEmpty
    else { return }
    start(pending.removeFirst())
  }
  public func stopAndDrain() async {
    stop()
    let active = task
    await active?.value
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
      if !self.stopped && !self.isPaused && !self.pending.isEmpty {
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
