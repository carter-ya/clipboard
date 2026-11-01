import XCTest

@testable import ClipboardCore

final class DesktopHistoryPresentationTests: XCTestCase {
  private func item(_ kind: ClipKind = .text) -> ClipItem {
    .init(
      createdAt: Date(timeIntervalSince1970: 1_700_000_000), kind: kind,
      preview: "Original preview", sha256: "synthetic", sizeBytes: 19)
  }
  func testImageRowsPreferBoundedResultsWithoutChangingOriginalOrRevealingSensitiveContent() throws
  {
    var image = item(.image)
    image.summary = "Recognized image text · 中文\nSecond line"
    let result = DesktopHistoryPresentation.make(items: [image], language: "en")
    XCTAssertEqual(result[image.id]?.rowText, "Recognized image text · 中文 Second line")
    XCTAssertEqual(image.preview, "Original preview")
    image.sensitive = true
    XCTAssertNil(DesktopHistoryPresentation.make(items: [image], language: "en")[image.id]?.rowText)
    image.sensitive = false
    image.summary = String(repeating: "😀中", count: 1000)
    let bounded = try XCTUnwrap(
      DesktopHistoryPresentation.make(items: [image], language: "en")[image.id]?.rowText)
    XCTAssertLessThanOrEqual(bounded.utf8.count, 512)
    XCTAssertFalse(bounded.contains("\u{FFFD}"))
    var text = item()
    text.summary = "A separate analysis result"
    XCTAssertEqual(
      DesktopHistoryPresentation.make(items: [text], language: "en")[text.id]?.rowText, text.preview
    )
  }
  func testSourceLabelsAreReadableBoundedAndDoNotRewriteIdentifiers() {
    XCTAssertEqual(
      DesktopHistoryPresentation.sourceName("windows:C:\\Program Files\\Example.exe"), "Example.exe"
    )
    XCTAssertEqual(
      DesktopHistoryPresentation.sourceName("linux:org.gnome.Nautilus"), "org.gnome.Nautilus")
    XCTAssertEqual(DesktopHistoryPresentation.sourceName("com.google.Chrome"), "com.google.Chrome")
    XCTAssertNil(DesktopHistoryPresentation.sourceName(nil))
    let source = "windows:" + String(repeating: "中文", count: 1000)
    XCTAssertLessThanOrEqual(DesktopHistoryPresentation.sourceName(source)?.utf8.count ?? 0, 256)
    XCTAssertFalse(DesktopHistoryPresentation.sourceName("linux:app\nname")?.contains("\n") ?? true)
  }
  func testDatesUseTheSelectedLanguageAndTimezoneAndRejectInvalidRanges() throws {
    let value = item()
    let zero = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
    let nextDay = try XCTUnwrap(TimeZone(secondsFromGMT: 7200))
    let english = try XCTUnwrap(
      DesktopHistoryPresentation.make(items: [value], language: "en", timeZone: zero)[value.id])
    let japanese = try XCTUnwrap(
      DesktopHistoryPresentation.make(items: [value], language: "ja", timeZone: zero)[value.id])
    XCTAssertTrue(english.createdText.contains("2023"))
    XCTAssertNotEqual(english.createdText, japanese.createdText)
    XCTAssertNotEqual(
      english.createdText,
      DesktopHistoryPresentation.make(items: [value], language: "en", timeZone: nextDay)[value.id]?
        .createdText)
    var invalid = value
    invalid.createdAt = Date(timeIntervalSince1970: .infinity)
    XCTAssertEqual(
      DesktopHistoryPresentation.make(items: [invalid], language: "en")[value.id]?.createdText, "—")
  }
  func testFileReferencesHaveDecodedNamesBoundedDisplayAndUntouchedOriginalBytes() throws {
    let urls = [
      URL(fileURLWithPath: "/synthetic/设计 😀.txt"), URL(fileURLWithPath: "/synthetic/second.pdf"),
    ]
    let data = ClipboardFormats.fileURLData(urls)
    let display = try DesktopFileReferencePreview(data: data)
    XCTAssertEqual(display.totalCount, 2)
    XCTAssertEqual(display.entries.map(\.name), ["设计 😀.txt", "second.pdf"])
    XCTAssertEqual(display.entries[0].path, urls[0].path)
    XCTAssertFalse(display.isTruncated)
    let limited = try DesktopFileReferencePreview(data: data, maxEntries: 1)
    XCTAssertEqual(limited.totalCount, 2)
    XCTAssertEqual(limited.entries.count, 1)
    XCTAssertTrue(limited.isTruncated)
    XCTAssertEqual(try ClipboardFormats.fileURLs(from: data), urls)
    XCTAssertThrowsError(
      try DesktopFileReferencePreview(data: Data("https://example.invalid/secret".utf8)))
    XCTAssertThrowsError(try DesktopFileReferencePreview(data: Data()))
  }
  func testFileDisplayBudgetsAndMalformedReferencesFailWithoutTouchingFiles() throws {
    let url = try XCTUnwrap(URL(string: "file:///synthetic/reference.txt"))
    let many = try DesktopFileReferencePreview(
      data: ClipboardFormats.fileURLData(Array(repeating: url, count: 129)))
    XCTAssertEqual(many.totalCount, 129)
    XCTAssertEqual(many.entries.count, 128)
    XCTAssertTrue(many.isTruncated)
    let small = try DesktopFileReferencePreview(
      data: ClipboardFormats.fileURLData([url]), maxUTF8Bytes: 1)
    XCTAssertTrue(small.entries.isEmpty)
    XCTAssertTrue(small.isTruncated)
    XCTAssertThrowsError(try DesktopFileReferencePreview(data: Data([255, 0])))
    XCTAssertThrowsError(
      try DesktopFileReferencePreview(data: ClipboardFormats.fileURLData([url]), maxEntries: -1))
  }
  func testCancelledPresentationBatchDoesNotBuildAnyRows() async {
    let candidate = item()
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return DesktopHistoryPresentation.make(items: [candidate], language: "en")
    }
    let result = await task.value
    XCTAssertTrue(result.isEmpty)
  }

}
