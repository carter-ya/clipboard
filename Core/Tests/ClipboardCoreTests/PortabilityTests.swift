import XCTest

@testable import ClipboardCore

final class PortabilityTests: XCTestCase {
  func testSHA256MatchesKnownVectorsAcrossBackends() {
    XCTAssertEqual(
      Hashing.sha256(of: Data()),
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    )
    XCTAssertEqual(
      Hashing.sha256(of: Data("abc".utf8)),
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    )
  }

  func testClipboardWriterContractDoesNotRequireAppKit() throws {
    let writer = RecordingPasteboardWriter()
    let item = ClipItem(
      createdAt: Date(), kind: .text, preview: "hello", sha256: "fixture", sizeBytes: 5
    )
    try writer.write(item)
    XCTAssertEqual(writer.writes, [item])
  }

  func testStoreRoundTripWithUnicodeDirectoryAndRepeatedFlush() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("clipboard portable 中文 \(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try await JSONSnapshotClipStore(root: root)
    for text in ["first", "second"] {
      await store.insert(
        RawClipItem(
          payloads: [RawPayload(pasteboardType: "public.utf8-plain-text", data: Data(text.utf8))],
          totalBytes: text.utf8.count
        ))
      await store.flush()
    }
    let reopened = try await JSONSnapshotClipStore(root: root)
    let items = await reopened.all()
    XCTAssertEqual(items.map(\.preview), ["second", "first"])
  }

  #if !os(macOS)
    func testRichPayloadBytesSurviveWithoutApplePreviewDecoder() async throws {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("clipboard-rich-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: root) }
      let store = try await JSONSnapshotClipStore(root: root)
      let payload = RawPayload(pasteboardType: "public.html", data: Data("<b>hello</b>".utf8))
      await store.insert(RawClipItem(payloads: [payload], totalBytes: payload.data.count))
      await store.flush()
      let reopened = try await JSONSnapshotClipStore(root: root)
      let items = await reopened.all()
      let item = try XCTUnwrap(items.first)
      XCTAssertEqual(item.preview, "", "Raw markup must not masquerade as rendered text")
      XCTAssertEqual(item.payloads.first?.inlineData, payload.data)
    }

    func testPlainTextSidecarStillProvidesRichTextPreview() {
      let payloads = [
        RawPayload(pasteboardType: "public.rtf", data: Data("{\\rtf1 hello}".utf8)),
        RawPayload(pasteboardType: "public.utf8-plain-text", data: Data("hello".utf8)),
      ]
      XCTAssertEqual(PreviewBuilder.build(for: payloads), "hello")
    }
  #endif

  #if !canImport(OSLog)
    func testPortableLogRedactsInterpolationByDefault() {
      let secret = "synthetic-secret"
      let message: Logger.Message = "token=\(secret) id=\(42, privacy: .public)"
      XCTAssertEqual(message.text, "token=<private> id=42")
      XCTAssertFalse(message.text.contains(secret))
    }
  #endif
}
