#!/usr/bin/env swift
// Draws the Clipboard app icon at every size AppKit needs, then
// emits them plus a Contents.json into an AppIcon.appiconset.
//
//   swift tools/generate-icon.swift App/Assets.xcassets/AppIcon.appiconset
//
// Design: a blue→purple vertical gradient squircle with a white
// clipboard card (rounded body + small clip tab + three text lines)
// centred on top. All shapes are drawn with CGContext so the output
// is reproducible without any raster source art.

import AppKit
import CoreGraphics
import Foundation

let outputDir: String = {
  if CommandLine.arguments.count > 1 { return CommandLine.arguments[1] }
  return "App/Assets.xcassets/AppIcon.appiconset"
}()

try FileManager.default.createDirectory(
  atPath: outputDir,
  withIntermediateDirectories: true
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

func renderIcon(pixels: Int) -> CGImage? {
  let colorSpace = CGColorSpaceCreateDeviceRGB()
  let bitmapInfo =
    CGBitmapInfo.byteOrder32Big.rawValue
    | CGImageAlphaInfo.premultipliedLast.rawValue

  guard
    let ctx = CGContext(
      data: nil,
      width: pixels,
      height: pixels,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: colorSpace,
      bitmapInfo: bitmapInfo
    )
  else { return nil }

  let s = CGFloat(pixels)
  let rect = CGRect(x: 0, y: 0, width: s, height: s)
  let corner = s * 0.225

  // Clip to rounded rect
  let bgPath = CGPath(
    roundedRect: rect,
    cornerWidth: corner,
    cornerHeight: corner,
    transform: nil
  )
  ctx.addPath(bgPath)
  ctx.clip()

  // Gradient background (top → bottom)
  let top = CGColor(red: 0.36, green: 0.55, blue: 0.94, alpha: 1.0)
  let bottom = CGColor(red: 0.54, green: 0.37, blue: 0.90, alpha: 1.0)
  if let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [top, bottom] as CFArray,
    locations: [0, 1]
  ) {
    ctx.drawLinearGradient(
      gradient,
      start: CGPoint(x: 0, y: s),
      end: CGPoint(x: 0, y: 0),
      options: []
    )
  }

  // Clipboard body (white rounded rect)
  let bodyW = s * 0.60
  let bodyH = s * 0.72
  let bodyX = (s - bodyW) / 2
  let bodyY = s * 0.11
  let bodyRect = CGRect(x: bodyX, y: bodyY, width: bodyW, height: bodyH)
  let bodyCorner = s * 0.06
  let bodyPath = CGPath(
    roundedRect: bodyRect,
    cornerWidth: bodyCorner,
    cornerHeight: bodyCorner,
    transform: nil
  )
  ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
  ctx.addPath(bodyPath)
  ctx.fillPath()

  // Clip tab (the metal bit at the top)
  let clipW = bodyW * 0.45
  let clipH = s * 0.125
  let clipX = (s - clipW) / 2
  let clipY = bodyY + bodyH - clipH * 0.5
  let clipRect = CGRect(x: clipX, y: clipY, width: clipW, height: clipH)
  let clipCorner = s * 0.03
  let clipPath = CGPath(
    roundedRect: clipRect,
    cornerWidth: clipCorner,
    cornerHeight: clipCorner,
    transform: nil
  )
  ctx.setFillColor(CGColor(red: 0.94, green: 0.94, blue: 0.96, alpha: 1))
  ctx.addPath(clipPath)
  ctx.fillPath()
  ctx.setStrokeColor(CGColor(red: 0.78, green: 0.78, blue: 0.83, alpha: 1))
  ctx.setLineWidth(max(1, s * 0.008))
  ctx.addPath(clipPath)
  ctx.strokePath()

  // Horizontal text lines inside the body (omit on tiny icons).
  if pixels >= 64 {
    ctx.setFillColor(
      CGColor(red: 0.46, green: 0.55, blue: 0.92, alpha: 0.55)
    )
    let lineCount = 3
    let lineH = s * 0.04
    let lineGap = s * 0.05
    let lineAreaTop = bodyY + bodyH * 0.48
    for i in 0..<lineCount {
      let widthFactor: CGFloat = [0.72, 0.58, 0.44][i]
      let lineW = bodyW * widthFactor
      let lineX = bodyX + (bodyW - lineW) / 2
      let lineY = lineAreaTop - CGFloat(i) * (lineH + lineGap)
      let lineRect = CGRect(x: lineX, y: lineY, width: lineW, height: lineH)
      let linePath = CGPath(
        roundedRect: lineRect,
        cornerWidth: lineH / 2,
        cornerHeight: lineH / 2,
        transform: nil
      )
      ctx.addPath(linePath)
      ctx.fillPath()
    }
  }

  return ctx.makeImage()
}

func writePNG(_ cgImage: CGImage, to url: URL) throws {
  let rep = NSBitmapImageRep(cgImage: cgImage)
  guard let data = rep.representation(using: .png, properties: [:]) else {
    throw NSError(
      domain: "generate-icon",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"]
    )
  }
  try data.write(to: url, options: .atomic)
}

for size in sizes {
  guard let img = renderIcon(pixels: size.pixels) else {
    fputs("failed at \(size.pixels)\n", stderr)
    exit(1)
  }
  let url = URL(fileURLWithPath: "\(outputDir)/\(size.filename)")
  try writePNG(img, to: url)
  print("  \(size.filename) (\(size.pixels)×\(size.pixels))")
}

let contentsJSON = """
{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""
try contentsJSON.write(
  toFile: "\(outputDir)/Contents.json",
  atomically: true,
  encoding: .utf8
)
print("  Contents.json")
