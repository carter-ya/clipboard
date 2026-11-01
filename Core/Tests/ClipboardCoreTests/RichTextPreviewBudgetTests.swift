import XCTest

@testable import ClipboardCore

final class RichTextPreviewBudgetTests: XCTestCase {
  func testRichDisplayUsesTheFullBudgetAndKeepsUnicodeScalarBoundaries() {
    let body = String(repeating: "中😀", count: 12_000)
    let payload = RawPayload(pasteboardType: "public.html", data: Data("<p>\(body)</p>".utf8))
    let preview = RichTextPreview.preview(from: [payload])
    XCTAssertTrue(preview.isTruncated)
    XCTAssertGreaterThan(preview.text.utf8.count, 64 * 1024 - 4)
    XCTAssertLessThanOrEqual(preview.text.utf8.count, 64 * 1024)
    XCTAssertTrue(body.hasPrefix(preview.text))
    XCTAssertFalse(preview.text.contains("�"))
    XCTAssertEqual(payload.data, Data("<p>\(body)</p>".utf8))
  }

  func testCompleteRichPreviewDoesNotReportTruncationFromHiddenMarkup() {
    let html = RawPayload(
      pasteboardType: "public.html",
      data: Data("<head><style>hidden</style></head><p>中文 &#x1F600;</p>".utf8))
    let htmlPreview = RichTextPreview.preview(from: [html])
    XCTAssertEqual(htmlPreview.text, "中文 😀")
    XCTAssertFalse(htmlPreview.isTruncated)
    let rtf = RawPayload(
      pasteboardType: "public.rtf", data: Data("{\\rtf1 Fixture \\u20013?\\u25991?}".utf8))
    let rtfPreview = RichTextPreview.preview(from: [rtf])
    XCTAssertEqual(rtfPreview.text, "Fixture 中文")
    XCTAssertFalse(rtfPreview.isTruncated)
  }

  func testParserSourceBudgetReportsOmittedContentEvenWithShortVisibleOutput() {
    let html = RawPayload(
      pasteboardType: "public.html",
      data: Data(
        ("Visible<script>" + String(repeating: "x", count: 256 * 1024) + "</script>tail").utf8))
    let preview = RichTextPreview.preview(from: [html])
    XCTAssertEqual(preview.text, "Visible")
    XCTAssertTrue(preview.isTruncated)
    let rtf = RawPayload(
      pasteboardType: "public.rtf",
      data: Data(
        ("{\\rtf1 Visible{\\pict " + String(repeating: "x", count: 256 * 1024) + "}tail}").utf8))
    let rtfPreview = RichTextPreview.preview(from: [rtf])
    XCTAssertEqual(rtfPreview.text, "Visible")
    XCTAssertTrue(rtfPreview.isTruncated)
  }

  func testLegacyHTMLCharacterLimitsIncludeCombinedNumericEntities() {
    let combined = String(repeating: "e&#769;", count: 256)
    let payload = RawPayload(pasteboardType: "public.html", data: Data(combined.utf8))
    XCTAssertEqual(
      RichTextPreview.text(from: [payload], limit: 256), String(repeating: "e\u{301}", count: 256))
    let family = String(repeating: "&#x1F468;&#x200D;&#x1F469;&#x200D;&#x1F467;", count: 8)
    let emoji = RawPayload(pasteboardType: "public.html", data: Data(family.utf8))
    XCTAssertEqual(RichTextPreview.text(from: [emoji], limit: 8), String(repeating: "👨‍👩‍👧", count: 8))
  }

  func testRTFDisplayBudgetAndLegacyCallersRemainBounded() {
    let body = String(repeating: "x", count: 70_000)
    let payload = RawPayload(pasteboardType: "public.rtf", data: Data("{\\rtf1 \(body)}".utf8))
    let preview = RichTextPreview.preview(from: [payload])
    XCTAssertEqual(preview.text, String(repeating: "x", count: 64 * 1024))
    XCTAssertTrue(preview.isTruncated)
    XCTAssertEqual(RichTextPreview.text(from: [payload], limit: 256).count, 256)
    XCTAssertEqual(RichTextPreview.text(from: [payload], limit: Int.max).count, 16_000)
  }
}
