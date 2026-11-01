import Foundation

/// Explicit model operations, independent of history and analysis. Construction
/// and state observation never create files or start a transfer.
public actor DesktopModelStore {
  private enum Action: Sendable {
    case download
    case copy(URL)
    case refresh, remove
  }
  private struct Operation {
    let id: UUID
    let kind: DesktopModelKind
    let gate: DesktopModelCommitGate
    let task: Task<Void, Error>
  }
  private let root: URL
  private let downloader: any DesktopModelAssetDownloading
  private let catalog: [DesktopModelKind: DesktopModelAsset]
  private var statuses: [DesktopModelKind: DesktopModelAssetStatus] = [:]
  private var installed: [DesktopModelKind: URL] = [:]
  private var observers:
    [UUID: AsyncStream<[DesktopModelKind: DesktopModelAssetState]>.Continuation] = [:]
  private var operation: Operation?
  private var closed = false

  public init(root: URL, downloader: any DesktopModelAssetDownloading) throws {
    try self.init(
      root: root, downloader: downloader,
      catalog: DesktopModelKind.allCases.map {
        try DesktopModelAsset.bundled($0)
      })
  }
  init(root: URL, downloader: any DesktopModelAssetDownloading, catalog: [DesktopModelAsset]) throws
  {
    guard DesktopModelFiles.local(root), ![".", "..", ""].contains(root.lastPathComponent),
      root.path != "/"
    else {
      throw DesktopModelAssetError.invalidLocation
    }
    // Resolve trusted parent aliases, retaining the final component so its
    // directory/symlink ownership check cannot be bypassed by normalization.
    self.root = root.deletingLastPathComponent().resolvingSymlinksInPath()
      .appendingPathComponent(root.lastPathComponent, isDirectory: true)
    self.downloader = downloader
    self.catalog = Dictionary(uniqueKeysWithValues: catalog.map { ($0.kind, $0) })
  }
  public func asset(_ kind: DesktopModelKind) -> DesktopModelAsset? { catalog[kind] }
  public func state(_ kind: DesktopModelKind) -> DesktopModelAssetState {
    .init(status: statuses[kind] ?? .missing, installed: installed[kind] != nil)
  }
  public func installedURL(_ kind: DesktopModelKind) -> URL? { installed[kind] }
  public func changes() -> AsyncStream<[DesktopModelKind: DesktopModelAssetState]> {
    let id = UUID()
    let pair = AsyncStream<[DesktopModelKind: DesktopModelAssetState]>.makeStream(
      bufferingPolicy: .bufferingNewest(1))
    if closed {
      pair.continuation.finish()
      return pair.stream
    }
    observers[id] = pair.continuation
    pair.continuation.yield(snapshot())
    pair.continuation.onTermination = { [weak self] _ in Task { await self?.forget(id) } }
    return pair.stream
  }
  private func forget(_ id: UUID) { observers[id] = nil }
  private func snapshot() -> [DesktopModelKind: DesktopModelAssetState] {
    Dictionary(uniqueKeysWithValues: DesktopModelKind.allCases.map { ($0, state($0)) })
  }
  private func set(_ kind: DesktopModelKind, _ status: DesktopModelAssetStatus) {
    statuses[kind] = status
    let value = snapshot()
    for observer in observers.values { observer.yield(value) }
  }

  public func refresh(_ kind: DesktopModelKind) async throws {
    try await perform(kind, action: .refresh, accepted: false)
  }
  public func install(_ kind: DesktopModelKind, licenseAccepted: Bool = false) async throws {
    try await perform(kind, action: .download, accepted: licenseAccepted)
  }
  public func importFile(_ kind: DesktopModelKind, from source: URL, licenseAccepted: Bool = false)
    async throws
  {
    try await perform(kind, action: .copy(source), accepted: licenseAccepted)
  }
  /// The caller must first drain any analysis using this model. Windows may
  /// refuse removal while another process holds it; failure preserves ownership.
  public func remove(_ kind: DesktopModelKind) async throws {
    try await perform(kind, action: .remove, accepted: false)
  }
  public func cancel(_ kind: DesktopModelKind) async {
    guard let active = operation, active.kind == kind else { return }
    if active.gate.cancel() {
      set(kind, .cancelling)
      active.task.cancel()
    }
    _ = await active.task.result
  }
  public func shutdown() async {
    closed = true
    if let active = operation { await cancel(active.kind) }
    for observer in observers.values { observer.finish() }
    observers.removeAll()
  }
  private func perform(_ kind: DesktopModelKind, action: Action, accepted: Bool) async throws {
    try Task.checkCancellation()
    guard !closed else { throw DesktopModelAssetError.unavailable }
    guard operation == nil else { throw DesktopModelAssetError.busy }
    guard let asset = catalog[kind] else { throw DesktopModelAssetError.unavailable }
    switch action {
    case .download, .copy:
      guard !asset.licenseAcceptanceRequired || accepted else {
        throw DesktopModelAssetError.licenseNotAccepted
      }
    default: break
    }
    let id = UUID()
    let gate = DesktopModelCommitGate()
    let task = Task {
      try await self.run(asset, action: action, accepted: accepted, id: id, gate: gate)
    }
    operation = Operation(id: id, kind: kind, gate: gate, task: task)
    try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      if gate.cancel() { task.cancel() }
    }
  }
  private func offActor(_ body: @escaping @Sendable () throws -> Void) async throws {
    let task = Task.detached(priority: .utility, operation: body)
    try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }
  private func progress(_ kind: DesktopModelKind, id: UUID, received: Int64, total: Int64) {
    guard operation?.id == id, received >= 0, received <= total,
      case .downloading(let previous, _) = statuses[kind], received >= previous
    else { return }
    set(kind, .downloading(received: received, total: total))
  }
  private func run(
    _ asset: DesktopModelAsset, action: Action, accepted: Bool, id: UUID,
    gate: DesktopModelCommitGate
  ) async throws {
    let kind = asset.kind
    var pending: URL?
    defer {
      if let pending { try? FileManager.default.removeItem(at: pending) }
      if operation?.id == id { operation = nil }
    }
    do {
      try gate.check()
      let directory = root.appendingPathComponent(kind.rawValue, isDirectory: true)
      switch action {
      case .refresh:
        set(kind, .checking)
        installed[kind] = nil
        guard try DesktopModelFiles.root(root, create: false),
          try DesktopModelFiles.directory(directory, create: false),
          let record = try DesktopModelFiles.record(
            directory.appendingPathComponent("current.json"), kind: kind),
          record.matches(asset),
          let owner = try DesktopModelFiles.record(ownedRecord(record, in: directory), kind: kind),
          owner.matches(asset)
        else {
          set(kind, .missing)
          return
        }
        let file = directory.appendingPathComponent(record.filename)
        try await offActor { try DesktopModelFiles.verify(file, asset: asset, gate: gate) }
        try gate.commit {
          installed[kind] = file
          set(kind, .ready)
        }
      case .remove:
        set(kind, .removing)
        guard try DesktopModelFiles.root(root, create: false),
          try DesktopModelFiles.directory(directory, create: false)
        else {
          installed[kind] = nil
          set(kind, .missing)
          return
        }
        let records = try removalRecords(in: directory, kind: kind)
        try gate.commit {
          installed[kind] = nil
          for record in records {
            let file = directory.appendingPathComponent(record.filename)
            if try DesktopModelFiles.regular(file) { try FileManager.default.removeItem(at: file) }
          }
          let current = directory.appendingPathComponent("current.json")
          if try DesktopModelFiles.regular(current) {
            try FileManager.default.removeItem(at: current)
          }
          // Keep all ownership records until every model deletion succeeds.
          // A Windows file-in-use failure can then be retried safely.
          for record in records {
            try FileManager.default.removeItem(at: ownedRecord(record, in: directory))
          }
          set(kind, .missing)
        }
      case .download, .copy:
        _ = try DesktopModelFiles.root(root, create: true)
        _ = try DesktopModelFiles.directory(directory, create: true)
        if let free = try FileManager.default.attributesOfFileSystem(forPath: root.path)[
          .systemFreeSize] as? NSNumber,
          free.int64Value < asset.size + 64 * 1024 * 1024
        {
          throw DesktopModelAssetError.insufficientSpace
        }
        let file = directory.appendingPathComponent(".pending-" + id.uuidString)
        try Data().write(to: file, options: .withoutOverwriting)
        pending = file
        set(kind, .downloading(received: 0, total: asset.size))
        switch action {
        case .download:
          try await downloader.download(asset, to: file) { [weak self] count in
            Task { await self?.progress(kind, id: id, received: count, total: asset.size) }
          }
        case .copy(let source):
          try await offActor {
            try DesktopModelFiles.copy(source, to: file, asset: asset, gate: gate)
          }
        default: break
        }
        try gate.check()
        set(kind, .verifying)
        try await offActor { try DesktopModelFiles.verify(file, asset: asset, gate: gate) }
        try gate.commit {
          let target = try publish(file, asset: asset, accepted: accepted, directory: directory)
          installed[kind] = target
          set(kind, .ready)
        }
      }
    } catch {
      if error is CancellationError {
        set(kind, installed[kind] == nil ? .missing : .ready)
        throw CancellationError()
      }
      let failure = (error as? DesktopModelAssetError) ?? .unavailable
      set(kind, .failed(failure))
      throw failure
    }
  }
  private func ownedRecord(_ record: DesktopModelFileRecord, in directory: URL) -> URL {
    directory.appendingPathComponent(".owned-" + record.sha256 + ".json")
  }
  private func publish(_ pending: URL, asset: DesktopModelAsset, accepted: Bool, directory: URL)
    throws -> URL
  {
    let record = DesktopModelFileRecord(asset, accepted: accepted)
    let target = directory.appendingPathComponent(record.filename)
    let owner = ownedRecord(record, in: directory)
    let current = directory.appendingPathComponent("current.json")
    let priorOwner = try DesktopModelFiles.record(owner, kind: asset.kind)
    if let priorOwner, !priorOwner.matches(asset) {
      throw DesktopModelAssetError.invalidLocation
    }
    if let old = try DesktopModelFiles.record(current, kind: asset.kind) {
      guard
        let prior = try DesktopModelFiles.record(ownedRecord(old, in: directory), kind: asset.kind),
        old == prior
      else { throw DesktopModelAssetError.invalidLocation }
    }
    let exists = try DesktopModelFiles.regular(target)
    guard !exists || priorOwner != nil else { throw DesktopModelAssetError.invalidLocation }
    // Record ownership before creating a new content-addressed target. A crash
    // at any later step leaves a removable/retryable owned file. Reuse an
    // existing record so metadata failure cannot change its consent history.
    if priorOwner == nil { try DesktopModelFiles.writeRecord(record, to: owner) }
    // One same-directory native rename replaces the target without first
    // unpublishing it. Both files have the same verified content digest, so a
    // failure writing current.json never requires rolling the target back.
    try DesktopModelFiles.replace(pending, to: target)
    try DesktopModelFiles.writeRecord(priorOwner ?? record, to: current)
    return target
  }
  private func removalRecords(in directory: URL, kind: DesktopModelKind) throws
    -> [DesktopModelFileRecord]
  {
    let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    let owned = entries.filter { $0.hasPrefix(".owned-") && $0.hasSuffix(".json") }
    guard owned.count <= 128 else { throw DesktopModelAssetError.invalidLocation }
    let records = try owned.map { name -> DesktopModelFileRecord in
      guard
        let record = try DesktopModelFiles.record(
          directory.appendingPathComponent(name), kind: kind),
        ownedRecord(record, in: directory).lastPathComponent == name
      else { throw DesktopModelAssetError.invalidLocation }
      _ = try DesktopModelFiles.regular(directory.appendingPathComponent(record.filename))
      return record
    }
    if let current = try DesktopModelFiles.record(
      directory.appendingPathComponent("current.json"), kind: kind)
    {
      guard records.contains(where: { $0.sha256 == current.sha256 }) else {
        throw DesktopModelAssetError.invalidLocation
      }
    }
    return records
  }
}
