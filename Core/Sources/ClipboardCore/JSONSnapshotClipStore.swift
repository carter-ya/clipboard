import Foundation

/// Disk-backed, dedup-aware in-memory clip store.
///
/// All mutations run serially on the actor. Non-sensitive items are
/// persisted to `<root>/history.json` via a debounced atomic write;
/// sensitive items (filter returned `.markSensitive`) stay in memory
/// only — never written to disk, never in blobs, never in exports.
public actor JSONSnapshotClipStore: ClipStore {
  private struct Envelope: Codable {
    var version: Int
    var items: [ClipItem]
  }

  private let root: URL
  private let historyURL: URL
  private let historyBackupURL: URL
  private let blobStore: BlobStore
  private let cap: Int
  private let inlineThresholdBytes: Int
  private let debounceNanos: UInt64
  private let fileManager: FileManager

  private var items: [ClipItem] = []
  private var debounceTask: Task<Void, Never>?
  private var pendingFlushContinuations: [CheckedContinuation<Void, Never>] = []
  private let eventsContinuation: AsyncStream<StoreEvent>.Continuation

  public nonisolated let events: AsyncStream<StoreEvent>

  public init(
    root: URL,
    cap: Int = 100,
    inlineThresholdBytes: Int = 16 * 1024,
    debounceInterval: TimeInterval = 0.5,
    fileManager: FileManager = .default
  ) async throws {
    self.root = root
    self.historyURL = root.appendingPathComponent("history.json")
    self.historyBackupURL = root.appendingPathComponent("history.json.bak")
    self.cap = cap
    self.inlineThresholdBytes = inlineThresholdBytes
    self.debounceNanos = UInt64(debounceInterval * 1_000_000_000)
    self.fileManager = fileManager
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    self.blobStore = try BlobStore(
      root: root.appendingPathComponent("blobs"),
      fileManager: fileManager
    )

    let (stream, continuation) = AsyncStream.makeStream(of: StoreEvent.self)
    self.events = stream
    self.eventsContinuation = continuation

    await self.bootstrap()
  }

  // MARK: - ClipStore

  public func insert(_ raw: RawClipItem) async {
    let sha = Hashing.sha256(of: raw.payloads)

    if let existing = items.first(where: { $0.sha256 == sha }) {
      await bump(existing: existing)
      return
    }

    let preview = PreviewBuilder.build(for: raw.payloads, limit: PreviewBuilder.limit)
    let kind = ClipKind.infer(from: raw.payloads.map(\.pasteboardType))
    let payloads = await persistPayloads(raw: raw, sensitive: raw.isSensitive)

    let item = ClipItem(
      createdAt: raw.timestamp,
      kind: kind,
      preview: preview,
      sha256: sha,
      sizeBytes: raw.totalBytes,
      pinned: false,
      sensitive: raw.isSensitive,
      sensitivityReason: raw.sensitivityReason,
      sourceBundleID: raw.bundleID,
      payloads: payloads
    )

    items.insert(item, at: 0)
    await enforceCapacity()
    Log.store.info(
      """
      store.insert{id:\(item.id.uuidString, privacy: .public), \
      kind:\(item.kind.rawValue, privacy: .public), \
      size:\(item.sizeBytes, privacy: .public), \
      sensitive:\(item.sensitive, privacy: .public)}
      """
    )
    eventsContinuation.yield(.inserted(item))
    if !item.sensitive {
      scheduleWrite()
    }
  }

  public func all() async -> [ClipItem] { items }

  public func search(query: String, filters: SearchFilters) async -> [ClipItem] {
    let lower = query.lowercased()
    return items.filter { item in
      if !query.isEmpty, !item.preview.lowercased().contains(lower) {
        return false
      }
      if filters.pinnedOnly, !item.pinned { return false }
      if !filters.includeSensitive, item.sensitive { return false }
      if let kinds = filters.kinds, !kinds.contains(item.kind) { return false }
      if let bundle = filters.sourceBundleID, item.sourceBundleID != bundle {
        return false
      }
      return true
    }
  }

  public func item(id: UUID) async -> ClipItem? {
    items.first(where: { $0.id == id })
  }

  public func pin(id: UUID) async {
    guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
    items[idx].pinned = true
    eventsContinuation.yield(.updated(items[idx]))
    if !items[idx].sensitive { scheduleWrite() }
  }

  public func unpin(id: UUID) async {
    guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
    items[idx].pinned = false
    eventsContinuation.yield(.updated(items[idx]))
    if !items[idx].sensitive { scheduleWrite() }
  }

  public func togglePin(id: UUID) async {
    guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
    items[idx].pinned.toggle()
    eventsContinuation.yield(.updated(items[idx]))
    if !items[idx].sensitive { scheduleWrite() }
  }

  public func delete(id: UUID) async {
    guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
    let removed = items.remove(at: idx)
    await releaseBlobs(for: removed)
    eventsContinuation.yield(.deleted(id))
    if !removed.sensitive { scheduleWrite() }
  }

  public func bumpToTop(id: UUID) async {
    guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
    var item = items.remove(at: idx)
    item.createdAt = Date()
    items.insert(item, at: 0)
    eventsContinuation.yield(.updated(item))
    if !item.sensitive { scheduleWrite() }
  }

  public func clearAll() async {
    for item in items {
      await releaseBlobs(for: item)
    }
    items.removeAll()
    eventsContinuation.yield(.cleared)
    scheduleWrite()
  }

  public func flush() async {
    debounceTask?.cancel()
    debounceTask = nil
    await writeSnapshotNow()
  }

  // MARK: - Bootstrap / persistence

  private func bootstrap() async {
    do {
      let data = try Data(contentsOf: historyURL)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      do {
        let envelope = try decoder.decode(Envelope.self, from: data)
        self.items = envelope.items
      } catch {
        try? fileManager.removeItem(at: historyBackupURL)
        try? fileManager.moveItem(at: historyURL, to: historyBackupURL)
        self.items = []
        Log.store.error("store.corrupted path=\(self.historyURL.path, privacy: .public)")
        eventsContinuation.yield(
          .corrupted(path: historyURL.path, renamedTo: historyBackupURL.path)
        )
      }
    } catch {
      self.items = []
    }
    await blobStore.rebuildRefCounts(from: items)
    if let count = try? await blobStore.reconcile(), count > 0 {
      Log.store.info(
        "store.reconcile{orphansDeleted:\(count, privacy: .public)}"
      )
      eventsContinuation.yield(.reconciled(orphansDeleted: count))
    }
  }

  private func persistPayloads(raw: RawClipItem, sensitive: Bool) async -> [Payload] {
    if sensitive {
      // Always inline in-memory; no disk writes for sensitive items.
      return raw.payloads.map {
        Payload(pasteboardType: $0.pasteboardType, inlineData: $0.data)
      }
    }
    var result: [Payload] = []
    for rawPayload in raw.payloads {
      if rawPayload.data.count <= inlineThresholdBytes {
        result.append(
          Payload(pasteboardType: rawPayload.pasteboardType, inlineData: rawPayload.data)
        )
      } else {
        let blobSHA = Hashing.sha256(of: rawPayload.data)
        do {
          let path = try await blobStore.store(
            data: rawPayload.data,
            sha256: blobSHA,
            ext: rawPayload.pasteboardType.blobExtension
          )
          result.append(
            Payload(pasteboardType: rawPayload.pasteboardType, blobPath: path)
          )
        } catch {
          Log.store.error(
            "store.blobWriteFailed sha=\(blobSHA, privacy: .public) err=\(String(describing: error), privacy: .public)"
          )
          result.append(
            Payload(pasteboardType: rawPayload.pasteboardType, inlineData: rawPayload.data)
          )
        }
      }
    }
    return result
  }

  private func bump(existing: ClipItem) async {
    guard let idx = items.firstIndex(where: { $0.id == existing.id }) else { return }
    var updated = items.remove(at: idx)
    updated.createdAt = Date()
    items.insert(updated, at: 0)
    eventsContinuation.yield(.updated(updated))
    if !updated.sensitive {
      scheduleWrite()
    }
  }

  private func enforceCapacity() async {
    while items.filter({ !$0.pinned }).count > cap {
      if let victim = items.enumerated().reversed().first(where: { !$0.element.pinned }) {
        let removed = items.remove(at: victim.offset)
        await releaseBlobs(for: removed)
        Log.store.info(
          """
          store.evict{id:\(removed.id.uuidString, privacy: .public), \
          sha:\(removed.sha256, privacy: .public)}
          """
        )
        eventsContinuation.yield(
          .evicted(id: removed.id, sha256: removed.sha256, blobDeleted: true)
        )
      } else {
        break
      }
    }
  }

  private func releaseBlobs(for item: ClipItem) async {
    for payload in item.payloads {
      if let sha = payload.blobSHA256 {
        _ = await blobStore.release(sha256: sha)
      }
    }
  }

  // MARK: - Debounced write

  private func scheduleWrite() {
    debounceTask?.cancel()
    debounceTask = Task { [debounceNanos] in
      try? await Task.sleep(nanoseconds: debounceNanos)
      if Task.isCancelled { return }
      await self.writeSnapshotNow()
    }
  }

  private func writeSnapshotNow() async {
    let nonSensitive = items.filter { !$0.sensitive }
    let envelope = Envelope(version: 1, items: nonSensitive)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
      let data = try encoder.encode(envelope)
      let tmpURL = historyURL.appendingPathExtension("tmp")
      try data.write(to: tmpURL, options: .atomic)
      _ = try? fileManager.removeItem(at: historyURL)
      try fileManager.moveItem(at: tmpURL, to: historyURL)
    } catch {
      Log.store.error(
        "store.writeFailed err=\(String(describing: error), privacy: .public)"
      )
    }
    drainFlushContinuations()
  }

  private func drainFlushContinuations() {
    let pending = pendingFlushContinuations
    pendingFlushContinuations.removeAll()
    for c in pending { c.resume() }
  }

  // MARK: - Test helpers

  /// Access to the internal blob store for tests.
  public var blobs: BlobStore { blobStore }
}
