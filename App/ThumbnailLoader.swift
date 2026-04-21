import AppKit
import ClipboardCore
import Foundation

/// Loads and downscales image payloads into square thumbnails,
/// caching by blob sha256 (or inline sha256). Runs off the main
/// queue and posts the result back via the completion closure.
@MainActor
final class ThumbnailLoader {
  private let cache = ThumbnailCache.shared
  private let resolver: PayloadResolver
  private let queue = DispatchQueue(label: "com.clipboard.thumbnail.loader")
  private let thumbnailSize = NSSize(width: 64, height: 64)

  init(blobRoot: URL?) {
    self.resolver = PayloadResolver(blobRoot: blobRoot)
  }

  /// Returns a cached thumbnail synchronously if present; otherwise
  /// schedules async generation and calls `completion` on the main
  /// actor when it is ready.
  func thumbnail(for item: ClipItem, completion: @escaping @MainActor (NSImage) -> Void)
    -> NSImage?
  {
    guard let payload = item.payloads.first(where: { isImageType($0.pasteboardType) }) else {
      return nil
    }
    let key = cacheKey(for: payload, item: item)
    if let cached = cache.get(key: key) {
      return cached
    }
    let resolver = self.resolver
    let size = self.thumbnailSize
    queue.async { [weak self] in
      guard let data = try? resolver.data(for: payload),
        let image = NSImage(data: data),
        let scaled = Self.downscale(image, to: size)
      else { return }
      self?.cache.set(key: key, image: scaled)
      Task { @MainActor in completion(scaled) }
    }
    return nil
  }

  private func isImageType(_ type: String) -> Bool {
    ["public.png", "public.tiff", "public.jpeg", "public.image"].contains(type)
  }

  private func cacheKey(for payload: Payload, item: ClipItem) -> String {
    payload.blobSHA256 ?? "inline:\(item.id.uuidString)"
  }

  private static func downscale(_ image: NSImage, to target: NSSize) -> NSImage? {
    let source = image.size
    guard source.width > 0, source.height > 0 else { return nil }
    let thumb = NSImage(size: target)
    thumb.lockFocus()
    defer { thumb.unlockFocus() }
    NSGraphicsContext.current?.imageInterpolation = .high
    let aspect = min(target.width / source.width, target.height / source.height)
    let drawSize = NSSize(width: source.width * aspect, height: source.height * aspect)
    let origin = NSPoint(
      x: (target.width - drawSize.width) / 2,
      y: (target.height - drawSize.height) / 2
    )
    image.draw(in: NSRect(origin: origin, size: drawSize))
    return thumb
  }
}
