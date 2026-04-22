import XCTest

@testable import ClipboardCore

final class ClipItemCodableTests: XCTestCase {

  func testRoundTrip() throws {
    let original = ClipItem(
      id: UUID(),
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      kind: .mixed,
      preview: "hi there",
      sha256: "deadbeef",
      sizeBytes: 42,
      pinned: true,
      sensitive: false,
      sensitivityReason: nil,
      sourceBundleID: "com.apple.TextEdit",
      payloads: [
        Payload(pasteboardType: "public.utf8-plain-text", inlineData: Data("hi".utf8)),
        Payload(pasteboardType: "public.png", blobPath: "abc123.png"),
      ]
    )

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let data = try encoder.encode(original)
    let decoded = try decoder.decode(ClipItem.self, from: data)

    XCTAssertEqual(decoded, original)
  }

  func testPayloadBlobShaExtraction() {
    XCTAssertEqual(Payload(pasteboardType: "x", blobPath: "abc.png").blobSHA256, "abc")
    XCTAssertEqual(Payload(pasteboardType: "x", blobPath: "nohash").blobSHA256, "nohash")
    XCTAssertNil(Payload(pasteboardType: "x", inlineData: Data()).blobSHA256)
  }

  func testKindInference() {
    XCTAssertEqual(ClipKind.infer(from: ["public.utf8-plain-text"]), .text)
    XCTAssertEqual(ClipKind.infer(from: ["public.rtf"]), .rtf)
    XCTAssertEqual(ClipKind.infer(from: ["public.png"]), .image)
    XCTAssertEqual(ClipKind.infer(from: ["public.file-url"]), .file)
    XCTAssertEqual(ClipKind.infer(from: []), .text)
  }

  /// Priority: file > image > rtf > text (html counts as text). Items
  /// with several pasteboard representations resolve to their richest
  /// type instead of the legacy `.mixed` catch-all.
  func testKindInferencePriority() {
    // Browser image copy: PNG + HTML wrapper → image, not mixed.
    XCTAssertEqual(ClipKind.infer(from: ["public.png", "public.html"]), .image)
    // Rich text from a word processor: RTF + plain text fallback → rtf.
    XCTAssertEqual(
      ClipKind.infer(from: ["public.rtf", "public.utf8-plain-text"]),
      .rtf
    )
    // File drag from Finder that also carries a thumbnail → file.
    XCTAssertEqual(ClipKind.infer(from: ["public.file-url", "public.png"]), .file)
    // Image without any wrapper still resolves as image.
    XCTAssertEqual(ClipKind.infer(from: ["public.rtf", "public.png"]), .image)
    // HTML-only snippet collapses onto text family.
    XCTAssertEqual(ClipKind.infer(from: ["public.html"]), .text)
  }
}
