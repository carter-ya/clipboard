import Foundation

public protocol ClipStore: Sendable {
  /// Ingest a new raw clip item. Dedup, capacity eviction, persistence
  /// (for non-sensitive items) happen transparently.
  func insert(_ raw: RawClipItem) async

  /// Current ordered snapshot, most-recent-first, including sensitive
  /// items that are in-memory only.
  func all() async -> [ClipItem]

  /// Case-insensitive substring match over `preview`, with additional
  /// filters applied.
  func search(query: String, filters: SearchFilters) async -> [ClipItem]

  func item(id: UUID) async -> ClipItem?
  func pin(id: UUID) async
  func unpin(id: UUID) async
  /// Atomically flip the pinned flag on an item. Prefer this over
  /// reading item.pinned in the caller and then calling pin/unpin —
  /// the caller's copy may be stale if another event has already
  /// updated the store.
  func togglePin(id: UUID) async
  func delete(id: UUID) async
  func clearAll() async

  /// Move the item to the head of the list and refresh its createdAt.
  /// Used when the user activates an entry so the UI reflects the new
  /// order immediately, without waiting for the monitor's next poll
  /// tick to re-observe the clipboard and run dedup.
  func bumpToTop(id: UUID) async

  /// Forces any pending debounced write to complete. Should be called
  /// before app termination.
  func flush() async

  /// Bulk-import ClipItems (typically from a user-chosen export zip).
  /// De-dupes by sha256 against the current contents. When a target
  /// payload references a blob file, the source file is looked up
  /// under `blobsRoot/<sha>.<ext>`; missing blob files cause the
  /// whole item to be counted under `blobsMissing` and skipped.
  /// Sensitive items in the envelope are ignored (they shouldn't be
  /// in the envelope in the first place — S21 persistence_strategy
  /// guarantees that).
  func importItems(_ items: [ClipItem], blobsRoot: URL?) async -> ImportResult

  /// Event stream for UI layers to observe store mutations.
  var events: AsyncStream<StoreEvent> { get }
}
