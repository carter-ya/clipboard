#!/usr/bin/env swift
// Renders the DMG installer-window background used by `just package`.
// Layout: 540x380 canvas, soft blue gradient, two rounded slots where
// create-dmg drops the .app and /Applications symlink, plus an arrow
// between them. The create-dmg icon coordinates must match the slot
// centers (leftCenterX / rightCenterX, iconCenterY).
//
//   swift tools/dmg-background.swift tools/dmg-background.png

import AppKit
import Foundation

let dst =
  CommandLine.arguments.count > 1
  ? CommandLine.arguments[1]
  : "tools/dmg-background.png"

let width: CGFloat = 540
let height: CGFloat = 380

// Geometry shared with Justfile's create-dmg invocation.
let iconCenterY: CGFloat = 200  // visual top-down coordinate
let leftCenterX: CGFloat = 140
let rightCenterX: CGFloat = 400
let iconSlotSide: CGFloat = 150

let rep = NSBitmapImageRep(
  bitmapDataPlanes: nil,
  pixelsWide: Int(width),
  pixelsHigh: Int(height),
  bitsPerSample: 8,
  samplesPerPixel: 4,
  hasAlpha: true,
  isPlanar: false,
  colorSpaceName: .calibratedRGB,
  bytesPerRow: 0,
  bitsPerPixel: 0
)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Pale vertical gradient — light enough that dark icons read against it.
let gradient = NSGradient(colors: [
  NSColor(calibratedRed: 0.97, green: 0.98, blue: 1.00, alpha: 1),
  NSColor(calibratedRed: 0.87, green: 0.91, blue: 0.96, alpha: 1),
])!
gradient.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -90)

// NSGraphicsContext uses bottom-left origin; helper translates a
// top-down visual center to bottom-up rect.
func visualRect(centerX: CGFloat, centerY: CGFloat, side: CGFloat) -> NSRect {
  NSRect(
    x: centerX - side / 2,
    y: height - centerY - side / 2,
    width: side,
    height: side
  )
}

// Two translucent rounded slots — hint to the eye where the real icons
// will land. Very faint so the actual icons dominate.
NSColor(calibratedWhite: 1.0, alpha: 0.45).setFill()
for cx in [leftCenterX, rightCenterX] {
  NSBezierPath(
    roundedRect: visualRect(centerX: cx, centerY: iconCenterY, side: iconSlotSide),
    xRadius: 26,
    yRadius: 26
  ).fill()
}

// Arrow between slots (bottom-origin y).
let arrowY = height - iconCenterY
let arrowStartX = leftCenterX + iconSlotSide / 2 + 18
let arrowEndX = rightCenterX - iconSlotSide / 2 - 18

NSColor(calibratedRed: 0.30, green: 0.45, blue: 0.78, alpha: 0.75).setStroke()

let shaft = NSBezierPath()
shaft.move(to: NSPoint(x: arrowStartX, y: arrowY))
shaft.line(to: NSPoint(x: arrowEndX, y: arrowY))
shaft.lineWidth = 3
shaft.lineCapStyle = .round
shaft.stroke()

let head = NSBezierPath()
head.move(to: NSPoint(x: arrowEndX - 14, y: arrowY + 10))
head.line(to: NSPoint(x: arrowEndX, y: arrowY))
head.line(to: NSPoint(x: arrowEndX - 14, y: arrowY - 10))
head.lineWidth = 3
head.lineCapStyle = .round
head.lineJoinStyle = .round
head.stroke()

// Title — kept English-only; the arrow carries the meaning universally.
let title = "Drag Clipboard to the Applications folder"
let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
let attrs: [NSAttributedString.Key: Any] = [
  .font: NSFont.systemFont(ofSize: 16, weight: .medium),
  .foregroundColor: NSColor(calibratedWhite: 0.22, alpha: 1),
  .paragraphStyle: paragraph,
]
let titleHeight: CGFloat = 22
let titleY = height - 56 - titleHeight / 2  // ~56px visual from top
title.draw(
  in: NSRect(x: 0, y: titleY, width: width, height: titleHeight),
  withAttributes: attrs
)

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else {
  FileHandle.standardError.write(Data("Failed to encode PNG\n".utf8))
  exit(1)
}
try data.write(to: URL(fileURLWithPath: dst))
print("wrote \(dst) \(Int(width))x\(Int(height))")
