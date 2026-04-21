import Foundation

/// Non-persistent ClipStore for tests and scenarios.
public actor InMemoryClipStore: ClipStore {
  private var items: [ClipItem] = []
  private let cap: Int
  private let eventsContinuation: AsyncStream<StoreEvent>.Continuation

  public nonisolated let events: AsyncStream<StoreEvent>

  public init(cap: Int = 100) {
    self.cap = cap
    let (stream, continuation) = AsyncStream.makeStream(of: StoreEvent.self)
    self.events = stream
    self.eventsContinuation = continuation
  }

  public func insert(_ raw: RawClipItem) async {
    let sha = Hashing.sha256(of: raw.payloads)
    if let idx = items.firstIndex(where: { $0.sha256 == sha }) {
      var updated = items.remove(at: idx)
      updated.createdAt = Date()
      items.insert(updated, at: 0)
      eventsContinuation.yield(.updated(updated))
      return
    }
    let item = ClipItem(
      createdAt: raw.timestamp,
      kind: ClipKind.infer(from: raw.payloads.map(\.pasteboardType)),
      preview: PreviewBuilder.build(for: raw.payloads),
      sha256: sha,
      sizeBytes: raw.totalBytes,
      pinned: false,
      sensitive: raw.isSensitive,
      sensitivityReason: raw.sensitivityReason,
      sourceBundleID: raw.bundleID,
      payloads: raw.payloads.map { Payload(pasteboardType: $0.pasteboardType, inlineData: $0.data) }
    )
    items.insert(item, at: 0)
    while items.filter({ !$0.pinned }).count > cap {
      if let victim = items.enumerated().reversed().first(where: { !$0.element.pinned }) {
        let removed = items.remove(at: victim.offset)
        eventsContinuation.yield(
          .evicted(id: removed.id, sha256: removed.sha256, blobDeleted: false))
      } else {
        break
      }
    }
    eventsContinuation.yield(.inserted(item))
  }

  public func all() async -> [ClipItem] { items }

  public func search(query: String, filters: SearchFilters) async -> [ClipItem] {
    let lower = query.lowercased()
    return items.filter { item in
      if !query.isEmpty, !item.preview.lowercased().contains(lower) { return false }
      if filters.pinnedOnly, !item.pinned { return false }
      if !filters.includeSensitive, item.sensitive { return false }
      if let kinds = filters.kinds, !kinds.contains(item.kind) { return false }
      if let bundle = filters.sourceBundleID, item.sourceBundleID != bundle { return false }
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
  }

  public func unpin(id: UUID) async {
    guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
    items[idx].pinned = false
    eventsContinuation.yield(.updated(items[idx]))
  }

  public func togglePin(id: UUID) async {
    guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
    items[idx].pinned.toggle()
    eventsContinuation.yield(.updated(items[idx]))
  }

  public func delete(id: UUID) async {
    guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
    items.remove(at: idx)
    eventsContinuation.yield(.deleted(id))
  }

  public func bumpToTop(id: UUID) async {
    guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
    var item = items.remove(at: idx)
    item.createdAt = Date()
    items.insert(item, at: 0)
    eventsContinuation.yield(.updated(item))
  }

  public func clearAll() async {
    items.removeAll()
    eventsContinuation.yield(.cleared)
  }

  public func flush() async {}
}
