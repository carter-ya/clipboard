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
  private var cap: Int
  private let inlineThresholdBytes: Int
  private let debounceNanos: UInt64
  private let fileManager: FileManager
  private var sensitiveTextMasking: Bool

  private var items: [ClipItem] = []
  private struct SensitiveTransition {
    let original: ClipItem
    var materialized = false
    var committed = false
    var draining = false
    var blobReferences: [String]
  }
  private var sensitiveTransitions: [UUID: SensitiveTransition] = [:]
  /// Remains true across write/materialization failures until a later flush or
  /// ordinary snapshot successfully commits the sensitive removals.
  public var hasPendingSensitivePersistence: Bool { !sensitiveTransitions.isEmpty }
  private var debounceTask: Task<Void, Never>?
  private var pendingFlushContinuations: [CheckedContinuation<Void, Never>] = []
  private let broadcaster = StoreEventBroadcaster()

  public nonisolated var events: AsyncStream<StoreEvent> { broadcaster.subscribe() }

  public init(
    root: URL,
    cap: Int = 100,
    inlineThresholdBytes: Int = 16 * 1024,
    debounceInterval: TimeInterval = 0.5,
    fileManager: FileManager = .default,
    sensitiveTextMasking: Bool = true
  ) async throws {
    self.root = root
    self.historyURL = root.appendingPathComponent("history.json")
    self.historyBackupURL = root.appendingPathComponent("history.json.bak")
    self.cap = cap
    self.inlineThresholdBytes = inlineThresholdBytes
    self.debounceNanos = UInt64(debounceInterval * 1_000_000_000)
    self.fileManager = fileManager
    self.sensitiveTextMasking = sensitiveTextMasking
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    self.blobStore = try BlobStore(
      root: root.appendingPathComponent("blobs"),
      fileManager: fileManager
    )

    await self.bootstrap()
  }

  // MARK: - ClipStore

  public func insert(_ raw: RawClipItem) async {
    var raw = raw
    if !raw.isSensitive, let reason = sensitivityReason(for: raw.payloads) {
      raw.isSensitive = true
      raw.sensitivityReason = reason
    }
    let sha = Hashing.sha256(of: raw.payloads)

    if let index = items.firstIndex(where: { $0.sha256 == sha }) {
      let existing = items[index]
      if raw.isSensitive && !existing.sensitive {
        // A new sensitive classification takes precedence over an older plain
        // copy of the same content. Publish the memory-only state before any
        // suspension, preserving identity/pinning and the original Copy bytes.
        markSensitive(at: index, reason: raw.sensitivityReason)
      }
      if sensitiveTransitions[existing.id] != nil {
        scheduleWrite()
        await writeSnapshotNow()
      }
      await bump(existing: existing)
      return
    }

    let preview = PreviewBuilder.build(for: raw.payloads, limit: PreviewBuilder.limit)
    let kind = ClipKind.infer(from: raw.payloads)
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
    // A preference change can run while blob persistence suspends. Publish
    // only the current policy result, and retire any just-written references.
    if !item.sensitive, let reason = sensitivityReason(for: raw.payloads) {
      markSensitive(at: 0, reason: reason)
      scheduleWrite()
      await writeSnapshotNow()
    }
    await enforceCapacity()
    guard let published = items.first(where: { $0.id == item.id }) else { return }
    Log.store.info(
      """
      store.insert{id:\(item.id.uuidString, privacy: .public), \
      kind:\(item.kind.rawValue, privacy: .public), \
      size:\(item.sizeBytes, privacy: .public), \
      sensitive:\(published.sensitive, privacy: .public)}
      """
    )
    broadcaster.yield(.inserted(published))
    if !published.sensitive {
      scheduleWrite()
    }
  }

  /// Apply a user-selected limit without recreating the store or losing memory-only items.
  public func setCapacity(_ capacity: Int) async throws {
    guard (1...5000).contains(capacity) else { throw DesktopSettings.ValidationError.invalidValue }
    cap = capacity
    await enforceCapacity()
    scheduleWrite()
  }

  public func all() async -> [ClipItem] { items }

  public func search(query: String, filters: SearchFilters) async -> [ClipItem] {
    let lower = query.lowercased()
    return items.filter { item in
      if !query.isEmpty {
        let previewHit = item.preview.lowercased().contains(lower)
        let summaryHit = item.summary?.lowercased().contains(lower) ?? false
        if !previewHit, !summaryHit { return false }
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
    broadcaster.yield(.updated(items[idx]))
    if !items[idx].sensitive { scheduleWrite() }
  }

  public func unpin(id: UUID) async {
    guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
    items[idx].pinned = false
    broadcaster.yield(.updated(items[idx]))
    if !items[idx].sensitive { scheduleWrite() }
  }

  public func togglePin(id: UUID) async {
    guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
    items[idx].pinned.toggle()
    broadcaster.yield(.updated(items[idx]))
    if !items[idx].sensitive { scheduleWrite() }
  }

  public func updateSummary(id: UUID, summary: String, source: SummarySource) async {
    guard let idx = items.firstIndex(where: { $0.id == id }), !items[idx].sensitive else { return }
    items[idx].summary = summary
    items[idx].summarySource = source
    broadcaster.yield(.updated(items[idx]))
    if !items[idx].sensitive { scheduleWrite() }
  }

  public func delete(id: UUID) async {
    guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
    let removed = items.remove(at: idx)
    await releaseBlobs(for: removed)
    broadcaster.yield(.deleted(id))
    if !removed.sensitive || sensitiveTransitions[id] != nil { scheduleWrite() }
  }

  public func bumpToTop(id: UUID) async {
    guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
    var item = items.remove(at: idx)
    item.createdAt = Date()
    items.insert(item, at: 0)
    broadcaster.yield(.updated(item))
    if !item.sensitive { scheduleWrite() }
  }

  public func clearAll() async {
    for item in items {
      await releaseBlobs(for: item)
    }
    items.removeAll()
    broadcaster.yield(.cleared)
    scheduleWrite()
  }

  public func flush() async {
    debounceTask?.cancel()
    debounceTask = nil
    await writeSnapshotNow()
  }

  public func importItems(_ envelopeItems: [ClipItem], blobsRoot: URL?) async -> ImportResult {
    var added = 0
    var skipped = 0
    var blobsMissing = 0
    var changed = false

    for incoming in envelopeItems {
      if incoming.sensitive {
        skipped += 1
        continue
      }
      // Validate/materialize the entire item before creating any owned blobs.
      // Imported names, symlinks and digests use the same archive boundary.
      let payloads: [RawPayload]
      do {
        var total = 0
        payloads = try incoming.payloads.map { payload in
          let data = try DesktopZIPHistoryArchive.exportedBytes(payload, blobRoot: blobsRoot)
          guard data.count <= 16 * 1024 * 1024 - total else {
            throw DesktopHistoryArchive.ArchiveError.tooLarge
          }
          total += data.count
          return .init(pasteboardType: payload.pasteboardType, data: data)
        }
      } catch {
        blobsMissing += 1
        continue
      }
      let reason = sensitivityReason(for: payloads)
      let digest = Hashing.sha256(of: payloads)
      if let index = items.firstIndex(where: { $0.sha256 == digest }) {
        if let reason, !items[index].sensitive {
          markSensitive(at: index, reason: reason)
          changed = true
        }
        skipped += 1
        continue
      }
      var reindexed = incoming
      reindexed.id = UUID()
      reindexed.sha256 = digest
      reindexed.kind = ClipKind.infer(from: payloads)
      reindexed.preview = PreviewBuilder.build(for: payloads)
      reindexed.sizeBytes = payloads.reduce(0) { $0 + $1.data.count }
      reindexed.sensitive = reason != nil
      reindexed.sensitivityReason = reason
      if reason != nil {
        reindexed.summary = nil
        reindexed.summarySource = nil
      }
      reindexed.payloads = await persistPayloads(
        raw: RawClipItem(payloads: payloads), sensitive: reindexed.sensitive)
      items.insert(reindexed, at: 0)
      if !reindexed.sensitive, let reason = sensitivityReason(for: payloads) {
        markSensitive(at: 0, reason: reason)
        changed = true
      }
      broadcaster.yield(.inserted(items[0]))
      added += 1
    }
    await enforceCapacity()
    if added > 0 || changed {
      scheduleWrite()
      if changed { await writeSnapshotNow() }
    }
    return ImportResult(added: added, skipped: skipped, blobsMissing: blobsMissing)
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
        broadcaster.yield(
          .corrupted(path: historyURL.path, renamedTo: historyBackupURL.path)
        )
      }
    } catch {
      self.items = []
    }
    await blobStore.rebuildRefCounts(from: items)
    if sensitiveTextMasking { await reclassifySensitiveText() }
    if let count = try? await blobStore.reconcile(), count > 0 {
      Log.store.info(
        "store.reconcile{orphansDeleted:\(count, privacy: .public)}"
      )
      broadcaster.yield(.reconciled(orphansDeleted: count))
    }
  }

  /// Enabling the existing password preference also covers current/imported
  /// key text. Disabling it never declassifies an already sensitive record.
  @discardableResult
  public func setSensitiveTextMasking(_ enabled: Bool) async -> Bool {
    sensitiveTextMasking = enabled
    if enabled { await reclassifySensitiveText() }
    return !hasPendingSensitivePersistence
  }

  private func sensitivityReason(for payloads: [RawPayload]) -> String? {
    guard sensitiveTextMasking else { return nil }
    if payloads.contains(where: { $0.pasteboardType == SensitivityFilter.concealedType }) {
      return "concealedType"
    }
    return SecretPatternDetector.sensitivityReason(in: payloads)
  }

  private func markSensitive(at index: Int, reason: String?) {
    let original = items[index]
    guard !original.sensitive else { return }
    items[index].sensitive = true
    items[index].sensitivityReason = reason
    items[index].summary = nil
    items[index].summarySource = nil
    sensitiveTransitions[original.id] = SensitiveTransition(
      original: original, blobReferences: original.payloads.compactMap(\.blobSHA256))
    broadcaster.yield(.updated(items[index]))
  }

  private func reclassifySensitiveText() async {
    for index in items.indices where !items[index].sensitive {
      do {
        let inspected = try items[index].payloads.filter {
          SecretPatternDetector.isInspectableText($0.pasteboardType)
            || $0.pasteboardType == SensitivityFilter.concealedType
        }.map { payload in
          RawPayload(
            pasteboardType: payload.pasteboardType,
            data: try DesktopZIPHistoryArchive.exportedBytes(
              payload, blobRoot: root.appendingPathComponent("blobs"), maxBytes: Int.max - 1))
        }
        if let reason = sensitivityReason(for: inspected) {
          markSensitive(at: index, reason: reason)
        }
      } catch {
        // An unreadable/untrusted text reference cannot establish that the
        // visible preview is safe. Keep it masked and retain pending cleanup.
        markSensitive(at: index, reason: "sensitivityUnavailable")
      }
    }
    if hasPendingSensitivePersistence {
      scheduleWrite()
      await writeSnapshotNow()
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
    broadcaster.yield(.updated(updated))
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
        broadcaster.yield(
          .evicted(id: removed.id, sha256: removed.sha256, blobDeleted: true)
        )
      } else {
        break
      }
    }
  }

  private func releaseBlobs(for item: ClipItem) async {
    // A failed materialization can still expose the original blob references
    // in the live sensitive record. Its transition owns those until commit.
    guard sensitiveTransitions[item.id] == nil else { return }
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

  /// Primary-content dedup does not imply identical representations. Resolve
  /// the original record, never substitute the recapture's narrower payloads.
  private func materializeSensitiveTransitions() -> Bool {
    var complete = true
    for (id, transition) in sensitiveTransitions where !transition.materialized {
      guard let index = items.firstIndex(where: { $0.id == id }) else {
        sensitiveTransitions[id]?.materialized = true
        continue
      }
      do {
        let payloads = try transition.original.payloads.map { payload in
          let data: Data
          if let inline = payload.inlineData {
            data = inline
          } else {
            // Reuse owned-name, regular-file and digest checks. Do not impose
            // an archive export limit on an existing Mac Copy representation.
            data = try DesktopZIPHistoryArchive.exportedBytes(
              payload, blobRoot: root.appendingPathComponent("blobs"), maxBytes: Int.max - 1)
          }
          return Payload(pasteboardType: payload.pasteboardType, inlineData: data)
        }
        items[index].payloads = payloads
        sensitiveTransitions[id]?.materialized = true
        broadcaster.yield(.updated(items[index]))
      } catch {
        complete = false
        Log.store.error(
          "store.sensitiveMaterializationPending id=\(id.uuidString, privacy: .public)")
      }
    }
    return complete
  }

  @discardableResult
  private func writeSnapshotNow() async -> Bool {
    await drainCommittedSensitiveTransitions()
    guard materializeSensitiveTransitions() else {
      drainFlushContinuations()
      return false
    }
    let nonSensitive = items.filter { !$0.sensitive }
    let envelope = Envelope(version: 1, items: nonSensitive)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
      let data = try encoder.encode(envelope)
      // Let Foundation replace the destination atomically. Removing it before
      // moving a fixed temporary path creates a missing-file window and can
      // discard the previous snapshot when the subsequent move fails.
      try data.write(to: historyURL, options: .atomic)
    } catch {
      Log.store.error(
        "store.writeFailed err=\(String(describing: error), privacy: .public)"
      )
      drainFlushContinuations()
      return false
    }
    for id in Array(sensitiveTransitions.keys) { sensitiveTransitions[id]?.committed = true }
    await drainCommittedSensitiveTransitions()
    drainFlushContinuations()
    return !hasPendingSensitivePersistence
  }

  private func drainCommittedSensitiveTransitions() async {
    let pending = sensitiveTransitions.filter { $0.value.committed && !$0.value.draining }.map(
      \.key)
    for id in pending {
      // Another flush may acquire a later id while this loop awaits an earlier
      // blob release. Recheck the lease instead of trusting the initial list.
      guard let transition = sensitiveTransitions[id], transition.committed, !transition.draining
      else { continue }
      sensitiveTransitions[id]?.draining = true
      while let digest = sensitiveTransitions[id]?.blobReferences.first {
        guard await blobStore.releaseSensitiveReference(sha256: digest) else {
          Log.store.error("store.sensitiveBlobCleanupPending id=\(id.uuidString, privacy: .public)")
          break
        }
        sensitiveTransitions[id]?.blobReferences.removeFirst()
      }
      sensitiveTransitions[id]?.draining = false
      if sensitiveTransitions[id]?.blobReferences.isEmpty == true {
        sensitiveTransitions.removeValue(forKey: id)
      }
    }
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
