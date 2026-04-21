import AppKit
import XCTest

@testable import ClipboardCore

final class NSPasteboardWriterTests: XCTestCase {

  private func makePasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("com.clipboard.test.\(UUID().uuidString)"))
  }

  func testWritesInlinePayloadsToSystemPasteboard() throws {
    let pb = makePasteboard()
    let writer = NSPasteboardWriter(pasteboard: pb)
    let item = ClipItem(
      createdAt: Date(),
      kind: .text,
      preview: "hi",
      sha256: "abc",
      sizeBytes: 5,
      payloads: [
        Payload(pasteboardType: "public.utf8-plain-text", inlineData: Data("hi".utf8)),
        Payload(pasteboardType: "public.html", inlineData: Data("<b>hi</b>".utf8)),
      ]
    )
    try writer.write(item)

    XCTAssertEqual(
      pb.string(forType: NSPasteboard.PasteboardType("public.utf8-plain-text")),
      "hi"
    )
    XCTAssertEqual(
      pb.data(forType: NSPasteboard.PasteboardType("public.html")),
      Data("<b>hi</b>".utf8)
    )
  }

  func testResolvesBlobsFromRoot() throws {
    let pb = makePasteboard()
    let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("writer-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpRoot) }

    let blobName = "abc.bin"
    let blobURL = tmpRoot.appendingPathComponent(blobName)
    let blobBody = Data(repeating: 0xAA, count: 2048)
    try blobBody.write(to: blobURL)

    let writer = NSPasteboardWriter(pasteboard: pb, blobRoot: tmpRoot)
    let item = ClipItem(
      createdAt: Date(), kind: .image, preview: "<image>", sha256: "x", sizeBytes: 2048,
      payloads: [Payload(pasteboardType: "public.png", blobPath: blobName)]
    )
    try writer.write(item)

    XCTAssertEqual(pb.data(forType: NSPasteboard.PasteboardType("public.png")), blobBody)
  }

  func testRecordingWriterCapturesAllCalls() throws {
    let writer = RecordingPasteboardWriter()
    let item = ClipItem(
      createdAt: Date(), kind: .text, preview: "x", sha256: "1", sizeBytes: 1
    )
    try writer.write(item)
    try writer.write(item)
    XCTAssertEqual(writer.writes.count, 2)
    XCTAssertEqual(writer.writes.first?.id, item.id)
  }

  func testThrowsWhenPayloadHasNoData() {
    let pb = makePasteboard()
    let writer = NSPasteboardWriter(pasteboard: pb)
    let item = ClipItem(
      createdAt: Date(), kind: .text, preview: "x", sha256: "1", sizeBytes: 0,
      payloads: [Payload(pasteboardType: "public.utf8-plain-text")]
    )
    XCTAssertThrowsError(try writer.write(item)) { error in
      if case PasteboardWriterError.missingData(let type) = error {
        XCTAssertEqual(type, "public.utf8-plain-text")
      } else {
        XCTFail("expected missingData, got \(error)")
      }
    }
  }
}
