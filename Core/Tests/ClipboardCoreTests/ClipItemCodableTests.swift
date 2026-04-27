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

  /// Round-trips an item that carries an AI-generated summary + the
  /// engine that produced it (S63). Both fields default to nil but
  /// must survive encode/decode when populated.
  func testSummaryFieldsRoundTrip() throws {
    let original = ClipItem(
      id: UUID(),
      createdAt: Date(timeIntervalSince1970: 1_700_000_100),
      kind: .image,
      preview: "<image>",
      sha256: "abc123",
      sizeBytes: 2048,
      payloads: [
        Payload(pasteboardType: "public.png", blobPath: "abc123.png")
      ],
      summary: "Screenshot of terminal with git output",
      summarySource: .vision
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let encoded = try encoder.encode(original)
    let decoded = try decoder.decode(ClipItem.self, from: encoded)

    XCTAssertEqual(decoded, original)
    XCTAssertEqual(decoded.summary, "Screenshot of terminal with git output")
    XCTAssertEqual(decoded.summarySource, .vision)
  }

  func testRemoteOpenAISummarySourceRoundTrip() throws {
    let original = ClipItem(
      id: UUID(),
      createdAt: Date(timeIntervalSince1970: 1_700_000_200),
      kind: .text,
      preview: "hello",
      sha256: "ffeedd",
      sizeBytes: 5,
      payloads: [
        Payload(pasteboardType: "public.utf8-plain-text", inlineData: Data("hello".utf8))
      ],
      summary: "Greeting.",
      summarySource: .remoteOpenAI
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let encoded = try encoder.encode(original)
    let decoded = try decoder.decode(ClipItem.self, from: encoded)

    XCTAssertEqual(decoded, original)
    XCTAssertEqual(decoded.summarySource, .remoteOpenAI)
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
    XCTAssertEqual(ClipKind.infer(from: [] as [String]), .text)
  }

  /// Priority: image > file > rtf > text (html counts as text). Items
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
    // Telegram / Messages image paste: image + temp file-url → image.
    XCTAssertEqual(ClipKind.infer(from: ["public.file-url", "public.png"]), .image)
    // Pure Finder file copy (no image payload) → file.
    XCTAssertEqual(ClipKind.infer(from: ["public.file-url"]), .file)
    // Image without any wrapper still resolves as image.
    XCTAssertEqual(ClipKind.infer(from: ["public.rtf", "public.png"]), .image)
    // HTML-only snippet collapses onto text family.
    XCTAssertEqual(ClipKind.infer(from: ["public.html"]), .text)
  }

  /// Disambiguation by file extension: a Finder PDF copy carries
  /// `public.file-url` plus a PNG/TIFF preview thumbnail. The
  /// type-only inference would mis-classify it as `.image` (and
  /// then Vision OCR would label the document icon as
  /// "diskette, media"). The payload-aware overload peeks at the
  /// file URL and routes non-image extensions to `.file`.
  func testKindInferenceFileURLDisambiguation() {
    func payload(_ type: String, _ data: Data = Data()) -> RawPayload {
      RawPayload(pasteboardType: type, data: data)
    }
    func urlPayload(_ url: String) -> RawPayload {
      RawPayload(pasteboardType: "public.file-url", data: Data(url.utf8))
    }

    // Finder PDF copy: image preview + file URL with .pdf → file.
    let pdfCopy: [RawPayload] = [
      payload("public.tiff"),
      urlPayload("file:///Users/me/Documents/spec.pdf"),
    ]
    XCTAssertEqual(ClipKind.infer(from: pdfCopy), .file)
    // Same for .docx, .txt — anything non-image-extension routes to file.
    let txtCopy: [RawPayload] = [
      payload("public.png"),
      urlPayload("file:///tmp/notes.txt"),
    ]
    XCTAssertEqual(ClipKind.infer(from: txtCopy), .file)
    // Telegram / Messages image paste: file-url is a temp .png → image.
    let telegramImage: [RawPayload] = [
      payload("public.png"),
      urlPayload("file:///tmp/IMG_0001.png"),
    ]
    XCTAssertEqual(ClipKind.infer(from: telegramImage), .image)
    // Image-only (no file-url) → image.
    let imageOnly: [RawPayload] = [payload("public.png")]
    XCTAssertEqual(ClipKind.infer(from: imageOnly), .image)
    // Pure Finder file copy (no image payload) → file via fallback.
    let pureFile: [RawPayload] = [urlPayload("file:///tmp/x.pdf")]
    XCTAssertEqual(ClipKind.infer(from: pureFile), .file)
  }
}
