import XCTest

@testable import ClipboardCore

final class SizeFilterTests: XCTestCase {
  private let context = ClipContext(sourceBundleID: nil, changeCount: 1, timestamp: Date())

  func testAcceptsBelowLimit() {
    let filter = SizeFilter(maxClipSizeBytes: 1000)
    let item = RawClipItem(totalBytes: 500)
    XCTAssertEqual(filter.evaluate(item, context: context), .accept)
  }

  func testAcceptsAtBoundary() {
    let filter = SizeFilter(maxClipSizeBytes: 1000)
    let item = RawClipItem(totalBytes: 1000)
    XCTAssertEqual(filter.evaluate(item, context: context), .accept)
  }

  func testRejectsAboveLimit() {
    let filter = SizeFilter(maxClipSizeBytes: 1000)
    let item = RawClipItem(totalBytes: 1001)
    XCTAssertEqual(filter.evaluate(item, context: context), .reject("tooLarge"))
  }

  func testZeroLimitDisables() {
    let filter = SizeFilter(maxClipSizeBytes: 0)
    let item = RawClipItem(totalBytes: Int.max / 2)
    XCTAssertEqual(filter.evaluate(item, context: context), .accept)
  }

  func testNegativeLimitDisables() {
    let filter = SizeFilter(maxClipSizeBytes: -1)
    let item = RawClipItem(totalBytes: 10_000_000)
    XCTAssertEqual(filter.evaluate(item, context: context), .accept)
  }
}
