import XCTest

@testable import ClipboardCore

final class RichClipboardTests: XCTestCase {
  private final class RestrictedClipboard: RichClipboardAccess, @unchecked Sendable {
    let canMonitor = false
    private(set) var reads = 0
    func revision() -> UInt64 { 1 }
    func read(maxBytes: Int) throws -> RichClipboardSnapshot? {
      reads += 1
      throw TextClipboardError.unsupportedSession
    }
    func write(payloads: [RawPayload], sensitive: Bool) throws {}
  }
  private final class RecordingFilter: ClipFilter, @unchecked Sendable {
    var captured: RawClipItem?
    func evaluate(_ item: RawClipItem, context: ClipContext) -> FilterDecision {
      captured = item
      return .accept
    }
  }
  func testZeroSizePreferenceCapturesTextAndLargeFileReferences() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("synthetic-large-file")
    XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: 20 * 1024 * 1024)
    try handle.close()
    let clipboard = FakeRichClipboard()
    let filter = RecordingFilter()
    let monitor = RichClipboardMonitor(clipboard: clipboard, filter: filter, maxBytes: 0)
    clipboard.push(
      .init(
        payloads: [
          .init(pasteboardType: "public.utf8-plain-text", data: Data("synthetic size fixture".utf8))
        ], revision: 1))
    monitor.pulse()
    XCTAssertEqual(filter.captured?.payloads.first?.data, Data("synthetic size fixture".utf8))
    filter.captured = nil
    clipboard.push(
      .init(
        payloads: [
          .init(pasteboardType: "public.file-url", data: ClipboardFormats.fileURLData([file]))
        ], revision: 2))
    monitor.pulse()
    XCTAssertGreaterThan(filter.captured?.totalBytes ?? 0, 16 * 1024 * 1024)
  }
  func testZeroSizePreferenceRetainsBoundedNativeTransferProtection() async {
    let clipboard = FakeRichClipboard()
    let filter = RecordingFilter()
    let monitor = RichClipboardMonitor(clipboard: clipboard, filter: filter, maxBytes: 0)
    clipboard.push(
      .init(
        payloads: [
          .init(pasteboardType: "public.png", data: Data(repeating: 0, count: 16 * 1024 * 1024 + 1))
        ], revision: 1))
    monitor.pulse()
    var skips = monitor.skips.makeAsyncIterator()
    let skip = await skips.next()
    XCTAssertEqual(skip?.reason, "tooLarge")
    XCTAssertEqual(skip?.limit, 16 * 1024 * 1024)
    XCTAssertNil(filter.captured)
  }
  func testRestrictedSessionStopsCaptureWithoutReadingContent() async {
    let clipboard = RestrictedClipboard()
    let monitor = RichClipboardMonitor(clipboard: clipboard)
    monitor.start()
    var skips = monitor.skips.makeAsyncIterator()
    let skip = await skips.next()
    XCTAssertEqual(skip?.reason, "unsupportedSession")
    XCTAssertEqual(clipboard.reads, 0)
    monitor.stop()
  }

  func testRichOnlyPreviewsDoNotExposeMarkupOrEmbeddedObjects() {
    let html = RawPayload(
      pasteboardType: "public.html",
      data: Data(
        "<head><style>hidden</style></head><p>中文 &amp; &#x1F600;</p><script>not text</script>".utf8)
    )
    XCTAssertEqual(RichTextPreview.text(from: [html]), "中文 & 😀")
    let rtf = RawPayload(
      pasteboardType: "public.rtf",
      data: Data("{\\rtf1{\\fonttbl hidden}Fixture \\u20013?\\u25991? {\\pict hidden object}}".utf8)
    )
    XCTAssertEqual(RichTextPreview.text(from: [rtf]), "Fixture 中文")
  }

  func testWindowsHTMLUsesByteOffsetsAndRejectsOutOfBounds() throws {
    let fragment = Data("<b>中文 😀</b>".utf8)
    let native = try ClipboardFormats.windowsHTML(fragment)
    XCTAssertEqual(try ClipboardFormats.htmlFromWindows(native), fragment)
    XCTAssertThrowsError(
      try ClipboardFormats.htmlFromWindows(Data("StartFragment:999\r\nEndFragment:1000\r\n".utf8)))
    XCTAssertThrowsError(
      try ClipboardFormats.htmlFromWindows(Data("StartFragment:-1\r\nEndFragment:0\r\n".utf8)))
  }
  func testURIListPreservesMultipleUnicodeFilesAndRejectsNonFileSchemes() throws {
    let urls = [URL(fileURLWithPath: "/tmp/中文 name.txt"), URL(fileURLWithPath: "/tmp/two.txt")]
    let data = Data("# clipboard files\r\n".utf8) + ClipboardFormats.fileURLData(urls)
    XCTAssertEqual(
      try ClipboardFormats.fileURLs(from: data).map(\.absoluteString), urls.map(\.absoluteString))
    XCTAssertThrowsError(try ClipboardFormats.fileURLs(from: Data("https://example.com/file".utf8)))
  }
  func testRichWriterPreservesFormatsAndNativeSensitivity() throws {
    let clipboard = FakeRichClipboard()
    let payloads = [
      RawPayload(pasteboardType: "public.html", data: Data("<b>fixture</b>".utf8)),
      .init(pasteboardType: "public.png", data: Data([1, 2, 3])),
    ]
    let item = ClipItem(
      createdAt: Date(), kind: .image, preview: "", sha256: "fixture", sizeBytes: 3,
      sensitive: true,
      payloads: payloads.map { .init(pasteboardType: $0.pasteboardType, inlineData: $0.data) })
    try RichPasteboardWriter(clipboard: clipboard).write(item)
    let value = try XCTUnwrap(clipboard.read(maxBytes: 1024))
    XCTAssertEqual(value.payloads, payloads)
    XCTAssertTrue(value.sensitive)
  }
  func testMonitorPreservesNativeHintAndSourceBlocklist() async throws {
    let clipboard = FakeRichClipboard()
    let monitor = RichClipboardMonitor(
      clipboard: clipboard, filter: BlocklistFilter(blockedBundleIDs: ["linux:PasswordFixture"]))
    clipboard.push(
      .init(
        payloads: [.init(pasteboardType: "public.png", data: Data([1, 2]))],
        sourceAppID: "linux:PasswordFixture", revision: 1))
    monitor.pulse()
    var changes = monitor.changes.makeAsyncIterator()
    let raw = await changes.next()
    XCTAssertTrue(raw?.isSensitive == true)
    XCTAssertEqual(raw?.bundleID, "linux:PasswordFixture")
    clipboard.push(
      .init(
        payloads: [.init(pasteboardType: "public.html", data: Data("fixture".utf8))],
        sensitive: true, revision: 2))
    monitor.pulse()
    let native = await changes.next()
    XCTAssertTrue(native?.isSensitive == true)
  }
  func testAggregateLimitRejectsMultipleIndividuallySmallPayloads() async throws {
    let clipboard = FakeRichClipboard()
    let monitor = RichClipboardMonitor(clipboard: clipboard, maxBytes: 5)
    try clipboard.write(
      payloads: [
        .init(pasteboardType: "public.html", data: Data([1, 2, 3])),
        .init(pasteboardType: "public.png", data: Data([4, 5, 6])),
      ], sensitive: false)
    monitor.pulse()
    var skips = monitor.skips.makeAsyncIterator()
    let rejected = await skips.next()
    XCTAssertEqual(rejected?.reason, "tooLarge")
    XCTAssertEqual(rejected?.limit, 5)
  }
  func testArchiveExcludesSensitiveContentAndResolvesBlobs() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try await JSONSnapshotClipStore(root: root, inlineThresholdBytes: 1)
    await store.insert(
      .init(
        payloads: [.init(pasteboardType: "public.png", data: Data([0, 1, 2, 3]))], totalBytes: 4))
    await store.insert(
      .init(
        payloads: [
          .init(pasteboardType: "public.utf8-plain-text", data: Data("sensitive fixture".utf8))
        ], totalBytes: 17, isSensitive: true))
    let destination = root.appendingPathComponent("export.clipboard.json")
    try DesktopHistoryArchive.write(
      items: await store.all(), blobRoot: root.appendingPathComponent("blobs"), to: destination)
    let restored = try DesktopHistoryArchive.read(from: destination)
    XCTAssertEqual(restored.count, 1)
    XCTAssertEqual(restored.first?.payloads.first?.inlineData, Data([0, 1, 2, 3]))
    XCTAssertNil(restored.first?.payloads.first?.blobPath)
    XCTAssertFalse(
      String(decoding: try Data(contentsOf: destination), as: UTF8.self).contains(
        "sensitive fixture"))
    let target = try await JSONSnapshotClipStore(root: root.appendingPathComponent("target"))
    let imported = await target.importItems(restored, blobsRoot: nil)
    XCTAssertEqual(imported.added, 1)
    let duplicate = await target.importItems(restored, blobsRoot: nil)
    XCTAssertEqual(duplicate.skipped, 1)
  }
  func testArchiveRejectsExternalBlobReferencesWithoutReadingThem() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let item = ClipItem(
      createdAt: Date(), kind: .text, preview: "", sha256: "forged", sizeBytes: 1,
      payloads: [.init(pasteboardType: "public.utf8-plain-text", blobPath: "../../private.txt")])
    let file = root.appendingPathComponent("malformed.json")
    struct Envelope: Encodable {
      let version = 1
      let items: [ClipItem]
    }
    try JSONEncoder().encode(Envelope(items: [item])).write(to: file)
    XCTAssertThrowsError(try DesktopHistoryArchive.read(from: file))
  }
  func testCapacityChangePreservesPinnedAndMemoryOnlyItems() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try await JSONSnapshotClipStore(root: root)
    await store.insert(rawTextFixture("pinned"))
    let first = await store.all()
    let id = try XCTUnwrap(first.first?.id)
    await store.pin(id: id)
    await store.insert(rawTextFixture("old"))
    var secret = rawTextFixture("sensitive fixture")
    secret.isSensitive = true
    await store.insert(secret)
    try await store.setCapacity(1)
    let items = await store.all()
    XCTAssertEqual(items.count, 2)
    XCTAssertTrue(items.contains(where: { $0.id == id && $0.pinned }))
    XCTAssertTrue(items.contains(where: \.sensitive))
    await store.flush()
    let disk = try Data(contentsOf: root.appendingPathComponent("history.json"))
    XCTAssertFalse(String(decoding: disk, as: UTF8.self).contains("sensitive fixture"))
    do {
      try await store.setCapacity(0)
      XCTFail("invalid capacity accepted")
    } catch {}
  }
  private func rawTextFixture(_ value: String) -> RawClipItem {
    .init(
      payloads: [.init(pasteboardType: "public.utf8-plain-text", data: Data(value.utf8))],
      totalBytes: value.utf8.count)
  }
}
