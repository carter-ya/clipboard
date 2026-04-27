import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Downscale an image so its encoded representation fits within
/// `maxBytes`. Tries PNG at progressively smaller pixel limits, then
/// falls back to JPEG with two quality steps. Returns nil for empty
/// input, undecodable data, or animated GIFs (the remote summary
/// path can't usefully describe a still frame from a multi-frame
/// asset).
public func downscaleImageForRemote(
  data: Data,
  maxBytes: Int
) -> (data: Data, mime: String)? {
  guard !data.isEmpty, maxBytes > 0 else { return nil }
  guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
  if isAnimatedGIF(source: source) { return nil }

  let pngLadder: [Int] = [2048, 1536, 1024, 768]
  for limit in pngLadder {
    if let encoded = encodeThumbnail(
      source: source,
      pixelLimit: limit,
      utType: UTType.png.identifier as CFString,
      properties: nil
    ), encoded.count <= maxBytes {
      return (encoded, "image/png")
    }
  }

  let jpegQualities: [Double] = [0.85, 0.7]
  for quality in jpegQualities {
    let smallest = pngLadder.last ?? 768
    let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
    if let encoded = encodeThumbnail(
      source: source,
      pixelLimit: smallest,
      utType: UTType.jpeg.identifier as CFString,
      properties: props as CFDictionary
    ), encoded.count <= maxBytes {
      return (encoded, "image/jpeg")
    }
  }
  return nil
}

private func encodeThumbnail(
  source: CGImageSource,
  pixelLimit: Int,
  utType: CFString,
  properties: CFDictionary?
) -> Data? {
  let opts: [CFString: Any] = [
    kCGImageSourceCreateThumbnailFromImageAlways: true,
    kCGImageSourceCreateThumbnailWithTransform: true,
    kCGImageSourceShouldCacheImmediately: true,
    kCGImageSourceThumbnailMaxPixelSize: pixelLimit,
  ]
  guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary)
  else { return nil }
  guard let mutable = CFDataCreateMutable(nil, 0) else { return nil }
  guard let dest = CGImageDestinationCreateWithData(mutable, utType, 1, nil) else {
    return nil
  }
  CGImageDestinationAddImage(dest, image, properties)
  guard CGImageDestinationFinalize(dest) else { return nil }
  return mutable as Data
}

private func isAnimatedGIF(source: CGImageSource) -> Bool {
  guard CGImageSourceGetCount(source) > 1 else { return false }
  guard let typeID = CGImageSourceGetType(source) as String? else { return false }
  if let gifType = UTType.gif.identifier as String? {
    if typeID.lowercased() != gifType.lowercased() { return false }
  }
  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
  return props?[kCGImagePropertyGIFDictionary] != nil
}
