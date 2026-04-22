#!/usr/bin/env swift
// Rasterize tools/icon-source.png into the ten AppIcon sizes with
// Core Image's CILanczosScaleTransform — a much better resampler
// than sips -Z for complex artwork — and a mild CIUnsharpMask at
// small sizes so the 16/32/64/128px variants don't look blurry in
// places like Activity Monitor or Finder list views.
//
//   swift tools/resize-icon.swift \
//     tools/icon-source.png \
//     App/Assets.xcassets/AppIcon.appiconset

import AppKit
import CoreImage
import Foundation

let args = CommandLine.arguments
let src = args.count > 1 ? args[1] : "tools/icon-source.png"
let dst = args.count > 2 ? args[2] : "App/Assets.xcassets/AppIcon.appiconset"

guard let srcImage = CIImage(contentsOf: URL(fileURLWithPath: src)) else {
  FileHandle.standardError.write(Data("Cannot load \(src)\n".utf8))
  exit(1)
}

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
let srcExtent = srcImage.extent

for size in sizes {
  let scale = CGFloat(size.pixels) / srcExtent.width

  // 1. Lanczos downscale.
  guard let lanczos = CIFilter(name: "CILanczosScaleTransform") else { continue }
  lanczos.setValue(srcImage, forKey: kCIInputImageKey)
  lanczos.setValue(scale, forKey: kCIInputScaleKey)
  lanczos.setValue(1.0, forKey: kCIInputAspectRatioKey)
  guard var output = lanczos.outputImage else { continue }

  // 2. Unsharp mask at small sizes to recover edge contrast that
  // Lanczos softens.
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

  let targetRect = CGRect(x: 0, y: 0, width: size.pixels, height: size.pixels)
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
