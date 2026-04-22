#!/usr/bin/env swift
// Rasterize tools/icon-source.png into the ten AppIcon sizes.
//
//   swift tools/resize-icon.swift \
//     tools/icon-source.png \
//     App/Assets.xcassets/AppIcon.appiconset
//
// Steps per size:
//   1. Detect the alpha bounding box of the source and expand it to
//      a centered square — the source artwork comes with ~15-17%
//      transparent padding on every edge which otherwise leaves the
//      final icon looking small at 16/32/64px.
//   2. Crop to that square so the content fills the whole canvas.
//   3. CILanczosScaleTransform to the target pixel size.
//   4. CIUnsharpMask at small sizes (≤128px) to recover edge contrast
//      that Lanczos softens — makes the icon legible in Activity
//      Monitor and Finder list views.

import AppKit
import CoreImage
import Foundation

let args = CommandLine.arguments
let src = args.count > 1 ? args[1] : "tools/icon-source.png"
let dst = args.count > 2 ? args[2] : "App/Assets.xcassets/AppIcon.appiconset"

guard let srcData = try? Data(contentsOf: URL(fileURLWithPath: src)),
  let srcImage = CIImage(data: srcData),
  let bmpRep = NSBitmapImageRep(data: srcData)
else {
  FileHandle.standardError.write(Data("Cannot load \(src)\n".utf8))
  exit(1)
}

let srcW = bmpRep.pixelsWide
let srcH = bmpRep.pixelsHigh

// Find the alpha bounding box in top-left origin bitmap coordinates.
// Reading raw bitmap data is ~100x faster than colorAt(x:y:).
var minX = srcW, minY = srcH, maxX = -1, maxY = -1
if let data = bmpRep.bitmapData,
  bmpRep.bitsPerSample == 8,
  bmpRep.samplesPerPixel >= 4
{
  let bpr = bmpRep.bytesPerRow
  let spp = bmpRep.samplesPerPixel
  for y in 0..<srcH {
    for x in 0..<srcW {
      let alpha = data[y * bpr + x * spp + 3]
      if alpha > 8 {
        if x < minX { minX = x }
        if x > maxX { maxX = x }
        if y < minY { minY = y }
        if y > maxY { maxY = y }
      }
    }
  }
}
if maxX < minX {
  // Fallback: no alpha info, use the whole canvas.
  minX = 0
  minY = 0
  maxX = srcW - 1
  maxY = srcH - 1
}

// Square crop centered on the bbox center so the longer dimension
// fills the canvas at every target size.
let contentWidth = maxX - minX + 1
let contentHeight = maxY - minY + 1
let side = max(contentWidth, contentHeight)
let centerX = (minX + maxX) / 2
let centerY = (minY + maxY) / 2
let cropXTopLeft = max(0, centerX - side / 2)
let cropYTopLeft = max(0, centerY - side / 2)
let cropSide = min(side, min(srcW - cropXTopLeft, srcH - cropYTopLeft))

// CIImage uses bottom-left origin; convert.
let cropYBottomLeft = srcH - cropYTopLeft - cropSide
let cropRect = CGRect(
  x: CGFloat(cropXTopLeft),
  y: CGFloat(cropYBottomLeft),
  width: CGFloat(cropSide),
  height: CGFloat(cropSide)
)

// Cropped, then translated so its extent origin is (0, 0) — makes
// the Lanczos → translate → composite chain below easier to reason
// about.
let croppedAtOrigin = srcImage
  .cropped(to: cropRect)
  .transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))

print(
  "source \(srcW)x\(srcH), content bbox (\(minX),\(minY))-(\(maxX),\(maxY)) "
    + "= \(contentWidth)x\(contentHeight), square crop \(cropSide)x\(cropSide)"
)

struct IconSize {
  let filename: String
  let pixels: Int
}

let sizes: [IconSize] = [
  IconSize(filename: "icon_16x16.png", pixels: 16),
  IconSize(filename: "icon_16x16@2x.png", pixels: 32),
  IconSize(filename: "icon_32x32.png", pixels: 32),
  IconSize(filename: "icon_32x32@2x.png", pixels: 64),
  IconSize(filename: "icon_128x128.png", pixels: 128),
  IconSize(filename: "icon_128x128@2x.png", pixels: 256),
  IconSize(filename: "icon_256x256.png", pixels: 256),
  IconSize(filename: "icon_256x256@2x.png", pixels: 512),
  IconSize(filename: "icon_512x512.png", pixels: 512),
  IconSize(filename: "icon_512x512@2x.png", pixels: 1024),
]

let context = CIContext()

for size in sizes {
  let targetPx = CGFloat(size.pixels)
  let scale = targetPx / CGFloat(cropSide)

  // Lanczos downscale. Output extent: (0, 0, targetPx, targetPx).
  guard let lanczos = CIFilter(name: "CILanczosScaleTransform") else { continue }
  lanczos.setValue(croppedAtOrigin, forKey: kCIInputImageKey)
  lanczos.setValue(scale, forKey: kCIInputScaleKey)
  lanczos.setValue(1.0, forKey: kCIInputAspectRatioKey)
  guard var output = lanczos.outputImage else { continue }

  // UnsharpMask at small sizes to recover edges lost during downscale.
  if size.pixels <= 128 {
    if let sharpen = CIFilter(name: "CIUnsharpMask") {
      sharpen.setValue(output, forKey: kCIInputImageKey)
      sharpen.setValue(0.6, forKey: kCIInputRadiusKey)
      sharpen.setValue(size.pixels <= 32 ? 0.85 : 0.5, forKey: kCIInputIntensityKey)
      if let sharpened = sharpen.outputImage {
        output = sharpened
      }
    }
  }

  let targetRect = CGRect(x: 0, y: 0, width: targetPx, height: targetPx)
  guard let cgImage = context.createCGImage(output, from: targetRect) else {
    FileHandle.standardError.write(Data("Failed to render \(size.filename)\n".utf8))
    continue
  }

  let rep = NSBitmapImageRep(cgImage: cgImage)
  rep.size = targetRect.size
  guard let data = rep.representation(using: .png, properties: [:]) else { continue }

  let outURL = URL(fileURLWithPath: "\(dst)/\(size.filename)")
  try data.write(to: outURL)
  print("wrote \(size.filename) (\(size.pixels)px)")
}
