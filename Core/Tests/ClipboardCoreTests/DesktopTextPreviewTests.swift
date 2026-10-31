import XCTest

@testable import ClipboardCore

final class DesktopTextPreviewTests: XCTestCase {
  func testFullTextRemainsAvailableAtAndBelowTheDisplayBudget() {
    let text = String(repeating: "a", count: 64 * 1024)
    XCTAssertEqual(DesktopTextPreview(text).text, text)
    XCTAssertFalse(DesktopTextPreview(text).isTruncated)
    XCTAssertEqual(DesktopTextPreview("").text, "")
    XCTAssertFalse(DesktopTextPreview("").isTruncated)
  }

  func testTruncationReportsExceededBudget() {
    let text = String(repeating: "x", count: 64 * 1024) + "tail"
    let preview = DesktopTextPreview(text)
    XCTAssertTrue(preview.isTruncated)
    XCTAssertEqual(preview.text.utf8.count, 64 * 1024)
    XCTAssertEqual(DesktopTextPreview("a", maxUTF8Bytes: 0).text, "")
    XCTAssertTrue(DesktopTextPreview("a", maxUTF8Bytes: 0).isTruncated)
  }

  func testUTF8BoundaryNeverProducesReplacementCharacters() {
    for text in ["中文", "😀abc", "e\u{301}z", "👨‍👩‍👧‍👦z"] {
      for limit in 0..<text.utf8.count {
        let preview = DesktopTextPreview(text, maxUTF8Bytes: limit)
        XCTAssertLessThanOrEqual(preview.text.utf8.count, limit)
        XCTAssertFalse(preview.text.contains("\u{FFFD}"))
        XCTAssertTrue(Array(text.utf8).starts(with: preview.text.utf8))
        XCTAssertTrue(preview.isTruncated)
      }
    }
  }
}
