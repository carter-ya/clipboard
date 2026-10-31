import Foundation
import XCTest
import ZIPFoundation

@testable import ClipboardCore

final class DesktopHistoryArchiveTests: XCTestCase {
  private struct Envelope: Encodable {
    var version = 1
    var items: [ClipItem]
  }
  private func root() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "archive-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
  }
  private func item(_ text: String, sensitive: Bool = false) -> ClipItem {
    ClipItem(
      createdAt: Date(timeIntervalSince1970: 1_700_000_000), kind: .text,
      preview: "untrusted", sha256: "untrusted", sizeBytes: -1, pinned: true, sensitive: sensitive,
      sourceBundleID: "synthetic.source",
      payloads: [.init(pasteboardType: "public.utf8-plain-text", inlineData: Data(text.utf8))])
  }
  private func history(_ items: [ClipItem], version: Int = 1) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(Envelope(version: version, items: items))
  }
  private func fixture(_ entries: [(String, Data)], at file: URL, symlink: Bool = false) throws {
    let archive = try Archive(url: file, accessMode: .create)
    for (path, data) in entries {
      try archive.addEntry(
        with: path, type: symlink ? .symlink : .file, uncompressedSize: Int64(data.count)
      ) {
        position, count in data.subdata(in: Int(position)..<(Int(position) + count))
      }
    }
  }

  func testZIPRoundTripExcludesSensitiveAndConcealedAndResolvesStoredBlobs() async throws {
    let directory = try root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try await JSONSnapshotClipStore(
      root: directory.appendingPathComponent("source"), inlineThresholdBytes: 1)
    let body = Data(repeating: 42, count: 32768)
    await store.insert(
      .init(payloads: [.init(pasteboardType: "public.png", data: body)], totalBytes: body.count))
    var concealed = item("concealed fixture")
    concealed.payloads.append(
      .init(pasteboardType: SensitivityFilter.concealedType, inlineData: Data()))
    let file = directory.appendingPathComponent("history.zip")
    let items = await store.all()
    try DesktopHistoryArchive.write(
      items: items + [item("private fixture", sensitive: true), concealed],
      blobRoot: directory.appendingPathComponent("source/blobs"), to: file)
    let archive = try Archive(url: file, accessMode: .read)
    XCTAssertEqual(Array(archive).count, 2)
    XCTAssertNotNil(archive["history.json"])
    let result = try DesktopHistoryArchive.readResult(from: file)
    XCTAssertEqual(result.items.count, 1)
    XCTAssertEqual(result.items.first?.payloads.first?.inlineData, body)
    XCTAssertNil(result.items.first?.payloads.first?.blobPath)
    let target = try await JSONSnapshotClipStore(root: directory.appendingPathComponent("target"))
    let first = await target.importItems(result.items, blobsRoot: nil)
    let duplicate = await target.importItems(result.items, blobsRoot: nil)
    XCTAssertEqual(first.added, 1)
    XCTAssertEqual(duplicate.skipped, 1)
  }

  func testWrappedMacLayoutAndMissingBlobResults() throws {
    let directory = try root()
    defer { try? FileManager.default.removeItem(at: directory) }
    var missing = item("missing")
    missing.payloads = [
      .init(pasteboardType: "public.png", blobPath: String(repeating: "a", count: 64) + ".png")
    ]
    let file = directory.appendingPathComponent("mac.zip")
    try fixture(
      [
        (
          "Clipboard/history.json",
          try history([item("中文 fixture"), missing, item("secret", sensitive: true)])
        ),
        ("__MACOSX/Clipboard/._history.json", Data([1, 2])),
      ], at: file)
    let result = try DesktopHistoryArchive.readResult(from: file)
    XCTAssertEqual(result.items.map(\.preview), ["中文 fixture"])
    XCTAssertEqual(result.blobsMissing, 1)
    XCTAssertEqual(result.skipped, 1)
    XCTAssertEqual(result.items.first?.createdAt, Date(timeIntervalSince1970: 1_700_000_000))
    XCTAssertEqual(result.items.first?.sourceBundleID, "synthetic.source")
    XCTAssertTrue(result.items.first?.pinned == true)
    XCTAssertNotEqual(result.items.first?.sha256, "untrusted")
    XCTAssertEqual(result.items.first?.sizeBytes, "中文 fixture".utf8.count)
  }

  func testDuplicateContentIsRecomputedAndCountedWithinTheArchive() throws {
    let directory = try root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("duplicates.zip")
    var duplicate = item("same body")
    duplicate.sha256 = "another forged hash"
    try fixture([("history.json", try history([item("same body"), duplicate]))], at: file)
    let result = try DesktopHistoryArchive.readResult(from: file)
    XCTAssertEqual(result.items.count, 1)
    XCTAssertEqual(result.skipped, 1)
  }

  func testLegacyJSONStillRoundTripsWithItsOriginalDateEncoding() throws {
    let directory = try root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("legacy.clipboard.json")
    try DesktopHistoryArchive.write(items: [item("legacy")], blobRoot: nil, to: file)
    XCTAssertEqual(try Data(contentsOf: file).first, UInt8(ascii: "{"))
    let result = try DesktopHistoryArchive.readResult(from: file)
    XCTAssertEqual(result.items.map(\.preview), ["legacy"])
    XCTAssertEqual(result.items.first?.createdAt, Date(timeIntervalSince1970: 1_700_000_000))
  }

  func testUnsafeOrAmbiguousZIPPathsAreRejected() throws {
    let directory = try root()
    defer { try? FileManager.default.removeItem(at: directory) }
    for path in ["../outside", "/absolute", "C:/drive", "blobs\\outside", "one//two"] {
      let file = directory.appendingPathComponent(UUID().uuidString + ".zip")
      try fixture([("history.json", try history([])), (path, Data([1]))], at: file)
      XCTAssertThrowsError(try DesktopHistoryArchive.read(from: file), path)
    }
    for extra in ["history.json", "HISTORY.JSON", "another/history.json"] {
      let file = directory.appendingPathComponent(UUID().uuidString + ".zip")
      try fixture([("history.json", try history([])), (extra, try history([]))], at: file)
      XCTAssertThrowsError(try DesktopHistoryArchive.read(from: file), extra)
    }
  }

  func testSymlinkEntriesAreRejectedWithoutExtraction() throws {
    let directory = try root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("symlink.zip")
    try fixture([("history.json", Data("../../outside".utf8))], at: file, symlink: true)
    XCTAssertThrowsError(try DesktopHistoryArchive.read(from: file))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: directory.appendingPathComponent("outside").path))
  }

  func testCorruptCRCAndForgedBlobDigestAreRejected() throws {
    let directory = try root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("crc.zip")
    try fixture([("history.json", try history([item("CRC fixture")]))], at: file)
    var bytes = try Data(contentsOf: file)
    let range = try XCTUnwrap(
      bytes.range(of: Data(Data("CRC fixture".utf8).base64EncodedString().utf8)))
    bytes[range.lowerBound] ^= 1
    try bytes.write(to: file)
    XCTAssertThrowsError(try DesktopHistoryArchive.read(from: file))
    var blob = item("")
    let name = String(repeating: "a", count: 64) + ".png"
    blob.payloads = [.init(pasteboardType: "public.png", blobPath: name)]
    let forged = directory.appendingPathComponent("forged.zip")
    try fixture(
      [("history.json", try history([blob])), ("blobs/" + name, Data([1, 2, 3]))], at: forged)
    XCTAssertThrowsError(try DesktopHistoryArchive.read(from: forged))
  }

  func testBlobTraversalIsRejectedEvenWhenTheFileIsMissing() throws {
    let directory = try root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("traversal.zip")
    var external = item("")
    external.payloads = [.init(pasteboardType: "public.png", blobPath: "../outside.png")]
    try fixture([("history.json", try history([external]))], at: file)
    XCTAssertThrowsError(try DesktopHistoryArchive.read(from: file))
  }

  func testDeclaredSizeAndDirectoryBoundsAreCheckedBeforeExtraction() throws {
    let directory = try root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = directory.appendingPathComponent("valid.zip")
    try fixture([("history.json", try history([]))], at: original)
    let source = try Data(contentsOf: original)
    let central = try XCTUnwrap(source.range(of: Data([0x50, 0x4b, 1, 2]))).lowerBound
    for offset in [central + 24, source.count - 22 + 16] {
      var bytes = source
      bytes.replaceSubrange(offset..<(offset + 4), with: [0xff, 0xff, 0xff, 0xff])
      let file = directory.appendingPathComponent(UUID().uuidString + ".zip")
      try bytes.write(to: file)
      XCTAssertThrowsError(try DesktopHistoryArchive.read(from: file))
    }
    let truncated = directory.appendingPathComponent("truncated.zip")
    try source.dropLast().write(to: truncated)
    XCTAssertThrowsError(try DesktopHistoryArchive.read(from: truncated))
  }

  func testSharedBlobReferencesCannotMultiplyTheLogicalBudget() throws {
    let directory = try root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let data = Data(repeating: 42, count: 16 * 1024 * 1024)
    let name = Hashing.sha256(of: data) + ".png"
    var reference = item("")
    reference.payloads = [.init(pasteboardType: "public.png", blobPath: name)]
    let file = directory.appendingPathComponent("repeated.zip")
    try fixture(
      [
        ("history.json", try history(Array(repeating: reference, count: 17))),
        ("blobs/" + name, data),
      ], at: file)
    XCTAssertThrowsError(try DesktopHistoryArchive.read(from: file)) { error in
      guard case DesktopHistoryArchive.ArchiveError.tooLarge = error else {
        return XCTFail("Expected a logical decoded-byte limit")
      }
    }
  }

  func testExportChecksExpandedReferencesBeforeReplacingTheDestination() throws {
    let directory = try root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let shared = Data(repeating: 65, count: 16 * 1024 * 1024 - 1)
    let clips = (0..<17).map { index -> ClipItem in
      var clip = item("logical export")
      clip.payloads = [
        .init(pasteboardType: "public.utf8-plain-text", inlineData: Data([UInt8(65 + index)])),
        .init(pasteboardType: "public.html", inlineData: shared),
      ]
      return clip
    }
    let file = directory.appendingPathComponent("existing.zip")
    let previous = Data("previous archive fixture".utf8)
    try previous.write(to: file)
    XCTAssertThrowsError(try DesktopHistoryArchive.write(items: clips, blobRoot: nil, to: file))
    XCTAssertEqual(try Data(contentsOf: file), previous)
  }

  func testFailedExportPreservesThePreviousDestination() throws {
    let directory = try root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("existing.zip")
    let previous = Data("previous archive fixture".utf8)
    try previous.write(to: file)
    var invalid = item("")
    invalid.payloads = [.init(pasteboardType: "public.png", blobPath: "../../unrelated")]
    XCTAssertThrowsError(
      try DesktopHistoryArchive.write(items: [invalid], blobRoot: directory, to: file))
    XCTAssertEqual(try Data(contentsOf: file), previous)
  }

  #if os(macOS)
    func testActualMacCoordinatorExportIsAccepted() throws {
      let directory = try root()
      defer { try? FileManager.default.removeItem(at: directory) }
      let source = directory.appendingPathComponent("Mac history 中文")
      try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
      try history([item("actual Mac fixture")]).write(
        to: source.appendingPathComponent("history.json"))
      let file = directory.appendingPathComponent("coordinated.zip")
      var coordinationError: NSError?
      var copyError: Error?
      NSFileCoordinator().coordinate(
        readingItemAt: source, options: [.forUploading], error: &coordinationError
      ) {
        url in
        do { try FileManager.default.copyItem(at: url, to: file) } catch { copyError = error }
      }
      if let coordinationError { throw coordinationError }
      if let copyError { throw copyError }
      XCTAssertEqual(
        try DesktopHistoryArchive.read(from: file).map(\.preview), ["actual Mac fixture"])
    }
  #endif
}
