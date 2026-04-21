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
  func delete(id: UUID) async
  func clearAll() async

  /// Forces any pending debounced write to complete. Should be called
  /// before app termination.
  func flush() async

  /// Event stream for UI layers to observe store mutations.
  var events: AsyncStream<StoreEvent> { get }
}
