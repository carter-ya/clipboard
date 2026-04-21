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
    XCTAssertEqual(ClipKind.infer(from: ["public.rtf", "public.png"]), .mixed)
    XCTAssertEqual(ClipKind.infer(from: []), .text)
  }
}
