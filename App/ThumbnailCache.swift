import AppKit
import Foundation

/// Minimal LRU cache keyed by blob sha256. S3 creates the scaffold;
/// S6 populates it from real image payloads. Thread-safe via a
/// dedicated serial queue — calls can come from any thread.
final class ThumbnailCache: @unchecked Sendable {
  static let shared = ThumbnailCache()

  private let queue = DispatchQueue(label: "com.clipboard.thumbnail")
  private var cache: [String: NSImage] = [:]
  private var accessOrder: [String] = []
  private let maxItems: Int

  init(maxItems: Int = 64) {
    self.maxItems = maxItems
  }

  func get(key: String) -> NSImage? {
    queue.sync {
      guard let image = cache[key] else { return nil }
      accessOrder.removeAll(where: { $0 == key })
      accessOrder.append(key)
      return image
    }
  }

  func set(key: String, image: NSImage) {
    queue.sync {
      if cache[key] == nil, cache.count >= maxItems, !accessOrder.isEmpty {
        let evict = accessOrder.removeFirst()
        cache.removeValue(forKey: evict)
      }
      cache[key] = image
      accessOrder.removeAll(where: { $0 == key })
      accessOrder.append(key)
    }
  }

  func clear() {
    queue.sync {
      cache.removeAll()
      accessOrder.removeAll()
    }
  }
}
