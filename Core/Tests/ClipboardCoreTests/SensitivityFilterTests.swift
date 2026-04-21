import XCTest

@testable import ClipboardCore

final class SensitivityFilterTests: XCTestCase {
  private let context = ClipContext(sourceBundleID: nil, changeCount: 1, timestamp: Date())

  func testMarksSensitiveOnConcealedType() {
    let filter = SensitivityFilter(skipSensitive: true)
    let item = RawClipItem(
      payloads: [
        RawPayload(pasteboardType: "public.utf8-plain-text", data: Data("pw".utf8)),
        RawPayload(
          pasteboardType: SensitivityFilter.concealedType, data: Data()),
      ]
    )
    XCTAssertEqual(filter.evaluate(item, context: context), .markSensitive("concealedType"))
  }

  func testAcceptsWhenSkipDisabled() {
    let filter = SensitivityFilter(skipSensitive: false)
    let item = RawClipItem(
      payloads: [RawPayload(pasteboardType: SensitivityFilter.concealedType, data: Data())]
    )
    XCTAssertEqual(filter.evaluate(item, context: context), .accept)
  }

  func testAcceptsWhenNoConcealedTypeDeclared() {
    let filter = SensitivityFilter(skipSensitive: true)
    let item = RawClipItem(
      payloads: [RawPayload(pasteboardType: "public.utf8-plain-text", data: Data())]
    )
    XCTAssertEqual(filter.evaluate(item, context: context), .accept)
  }
}

final class BlocklistFilterTests: XCTestCase {
  private let item = RawClipItem()

  func testMarksSensitiveWhenBundleInList() {
    let filter = BlocklistFilter(blockedBundleIDs: ["com.1password.1password"])
    let ctx = ClipContext(
      sourceBundleID: "com.1password.1password", changeCount: 1, timestamp: Date())
    XCTAssertEqual(
      filter.evaluate(item, context: ctx),
      .markSensitive("blockedSource:com.1password.1password")
    )
  }

  func testAcceptsWhenBundleNotInList() {
    let filter = BlocklistFilter(blockedBundleIDs: ["com.other.app"])
    let ctx = ClipContext(
      sourceBundleID: "com.apple.TextEdit", changeCount: 1, timestamp: Date())
    XCTAssertEqual(filter.evaluate(item, context: ctx), .accept)
  }

  func testAcceptsWhenBundleIsNil() {
    let filter = BlocklistFilter(blockedBundleIDs: ["com.1password.1password"])
    let ctx = ClipContext(sourceBundleID: nil, changeCount: 1, timestamp: Date())
    XCTAssertEqual(filter.evaluate(item, context: ctx), .accept)
  }

  func testDefaultsCoversMajorPasswordManagers() {
    XCTAssertTrue(BlocklistFilter.defaults.contains("com.1password.1password"))
    XCTAssertTrue(BlocklistFilter.defaults.contains("com.bitwarden.desktop"))
    XCTAssertTrue(BlocklistFilter.defaults.contains("com.apple.keychainaccess"))
  }
}
