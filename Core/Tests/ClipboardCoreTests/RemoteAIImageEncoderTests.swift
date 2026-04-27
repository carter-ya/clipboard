import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import ClipboardCore

final class RemoteAIImageEncoderTests: XCTestCase {

  func testReturnsNilForEmptyData() {
    XCTAssertNil(downscaleImageForRemote(data: Data(), maxBytes: 1024))
  }

  func testReturnsNilForUndecodableData() {
    let junk = Data([0, 1, 2, 3, 4, 5, 6, 7])
    XCTAssertNil(downscaleImageForRemote(data: junk, maxBytes: 1024))
  }

  func testFitsPNGWithinBudget() throws {
    let png = try makePNG(width: 96, height: 96, fill: .solid)
    let result = downscaleImageForRemote(data: png, maxBytes: 16 * 1024)
    let unwrapped = try XCTUnwrap(result)
    XCTAssertLessThanOrEqual(unwrapped.data.count, 16 * 1024)
    XCTAssertEqual(unwrapped.mime, "image/png")
  }

  // High-entropy noise PNGs don't compress well; with a budget too
  // small for any PNG ladder step but large enough for a JPEG, the
  // encoder must fall back to JPEG.
  func testFallsBackToJPEG() throws {
    let png = try makePNG(width: 96, height: 96, fill: .gradient)
    XCTAssertGreaterThan(png.count, 16 * 1024)
    let result = downscaleImageForRemote(data: png, maxBytes: 14 * 1024)
    let unwrapped = try XCTUnwrap(result)
    XCTAssertLessThanOrEqual(unwrapped.data.count, 14 * 1024)
    XCTAssertEqual(unwrapped.mime, "image/jpeg")
  }

  func testReturnsNilWhenBudgetTooTightForBothCodecs() throws {
    let png = try makePNG(width: 96, height: 96, fill: .gradient)
    XCTAssertNil(downscaleImageForRemote(data: png, maxBytes: 100))
  }

  // MARK: - fixtures

  private enum Fill { case solid, gradient }

  private func makePNG(width: Int, height: Int, fill: Fill) throws -> Data {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard
      let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else {
      throw NSError(domain: "fixture", code: 1)
    }
    switch fill {
    case .solid:
      ctx.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1.0))
      ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    case .gradient:
      // High-entropy noise so PNG can't compress to a tiny payload.
      var rng = SystemRandomNumberGenerator()
      for y in 0..<height {
        for x in 0..<width {
          let r = CGFloat(UInt8.random(in: 0...255, using: &rng)) / 255.0
          let g = CGFloat(UInt8.random(in: 0...255, using: &rng)) / 255.0
          let b = CGFloat(UInt8.random(in: 0...255, using: &rng)) / 255.0
          ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1.0))
          ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
      }
    }
    guard let cg = ctx.makeImage() else { throw NSError(domain: "fixture", code: 2) }
    guard let mutable = CFDataCreateMutable(nil, 0) else {
      throw NSError(domain: "fixture", code: 3)
    }
    guard
      let dest = CGImageDestinationCreateWithData(
        mutable,
        UTType.png.identifier as CFString,
        1,
        nil
      )
    else {
      throw NSError(domain: "fixture", code: 4)
    }
    CGImageDestinationAddImage(dest, cg, nil)
    guard CGImageDestinationFinalize(dest) else {
      throw NSError(domain: "fixture", code: 5)
    }
    return mutable as Data
  }
}
