import XCTest

@testable import ClipboardCore

#if os(Linux)
  import DesktopClipboard
#endif

final class TextClipboardTests: XCTestCase {
  func testFakePreservesUnicodeAndNativeSensitivity() throws {
    let clipboard = FakeTextClipboard()
    try clipboard.write(text: "中文 😀\nsecond line", sensitive: true)
    let first = try XCTUnwrap(clipboard.read(maxBytes: 1024))
    XCTAssertEqual(first.text, "中文 😀\nsecond line")
    XCTAssertTrue(first.sensitive)
    try clipboard.write(text: first.text, sensitive: false)
    XCTAssertNotEqual(clipboard.revision(), first.revision)
  }

  func testMonitorNormalizesTextAndKeepsNativeSecretHint() async throws {
    let clipboard = FakeTextClipboard()
    let monitor = TextClipboardMonitor(clipboard: clipboard)
    try clipboard.write(text: "synthetic secret", sensitive: true)
    monitor.pulse()
    var iterator = monitor.changes.makeAsyncIterator()
    let item = await iterator.next()
    XCTAssertEqual(item?.payloads.first?.pasteboardType, "public.utf8-plain-text")
    XCTAssertEqual(item?.payloads.first?.data, Data("synthetic secret".utf8))
    XCTAssertTrue(item?.isSensitive == true)
    XCTAssertNil(item?.bundleID)
  }

  func testMonitorPublishesBoundedSizeRejection() async throws {
    let clipboard = FakeTextClipboard()
    let monitor = TextClipboardMonitor(clipboard: clipboard, maxBytes: 4)
    try clipboard.write(text: "12345", sensitive: false)
    monitor.pulse()
    var iterator = monitor.skips.makeAsyncIterator()
    let skip = await iterator.next()
    XCTAssertEqual(skip?.reason, "tooLarge")
    XCTAssertEqual(skip?.bytes, 5)
    XCTAssertEqual(skip?.limit, 4)
  }

  func testWriterResolvesBlobAndPropagatesSensitivity() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("blob text 😀".utf8).write(to: root.appendingPathComponent("fixture.txt"))
    let clipboard = FakeTextClipboard()
    let writer = TextPasteboardWriter(clipboard: clipboard, blobRoot: root)
    let item = ClipItem(
      createdAt: Date(), kind: .text, preview: "", sha256: "fixture", sizeBytes: 14,
      sensitive: true,
      payloads: [Payload(pasteboardType: "public.utf8-plain-text", blobPath: "fixture.txt")])
    try writer.write(item)
    let result = try clipboard.read(maxBytes: 1024)
    XCTAssertEqual(result?.text, "blob text 😀")
    XCTAssertTrue(result?.sensitive == true)
  }

  func testWriterRejectsNonTextWithoutChangingClipboard() throws {
    let clipboard = FakeTextClipboard()
    try clipboard.write(text: "original", sensitive: false)
    let writer = TextPasteboardWriter(clipboard: clipboard)
    let item = ClipItem(
      createdAt: Date(), kind: .image, preview: "", sha256: "fixture", sizeBytes: 0,
      payloads: [Payload(pasteboardType: "public.png", inlineData: Data())])
    XCTAssertThrowsError(try writer.write(item))
    XCTAssertEqual(try clipboard.read(maxBytes: 1024)?.text, "original")
  }

  func testWriterRejectsEmbeddedNullWithoutChangingClipboard() throws {
    let clipboard = FakeTextClipboard()
    try clipboard.write(text: "original", sensitive: false)
    let item = ClipItem(
      createdAt: Date(), kind: .text, preview: "", sha256: "fixture", sizeBytes: 3,
      payloads: [Payload(pasteboardType: "public.utf8-plain-text", inlineData: Data([65, 0, 66]))])
    XCTAssertThrowsError(try TextPasteboardWriter(clipboard: clipboard).write(item))
    XCTAssertEqual(try clipboard.read(maxBytes: 1024)?.text, "original")
  }

  #if os(Linux)
    func testWaylandIsExplicitlyUnsupportedBeforeOpeningDisplay() {
      XCTAssertThrowsError(
        try SystemTextClipboard(environment: [
          "WAYLAND_DISPLAY": "wayland-0", "DISPLAY": ":99",
        ])
      ) { error in
        XCTAssertEqual(error as? TextClipboardError, .unsupportedSession)
      }
    }
  #endif
}
