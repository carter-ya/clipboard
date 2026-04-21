import XCTest

@testable import ClipboardCore

final class ImportItemsTests: XCTestCase {

  private func makeItem(
    sha: String,
    pinned: Bool = false,
    sensitive: Bool = false,
    blobs: [(path: String, sha: String)] = []
  ) -> ClipItem {
    ClipItem(
      createdAt: Date(),
      kind: .text,
      preview: "preview",
      sha256: sha,
      sizeBytes: 0,
      pinned: pinned,
      sensitive: sensitive,
      sensitivityReason: sensitive ? "concealedType" : nil,
      sourceBundleID: nil,
      payloads: blobs.map {
        Payload(pasteboardType: "public.png", blobPath: $0.path)
      }
    )
  }

  func testImportAddsNewItems() async {
    let store = InMemoryClipStore()
    let result = await store.importItems(
      [makeItem(sha: "a"), makeItem(sha: "b")],
      blobsRoot: nil
    )
    XCTAssertEqual(result.added, 2)
    XCTAssertEqual(result.skipped, 0)
    XCTAssertEqual(result.blobsMissing, 0)
    let items = await store.all()
    XCTAssertEqual(items.count, 2)
  }

  func testImportSkipsDuplicatesBySha() async {
    let store = InMemoryClipStore()
    await store.insert(rawText("hello"))
    let existing = await store.all().first!
    let result = await store.importItems(
      [makeItem(sha: existing.sha256), makeItem(sha: "new")],
      blobsRoot: nil
    )
    XCTAssertEqual(result.added, 1)
    XCTAssertEqual(result.skipped, 1)
  }

  func testImportSkipsSensitiveEntries() async {
    let store = InMemoryClipStore()
    let result = await store.importItems(
      [makeItem(sha: "s", sensitive: true)],
      blobsRoot: nil
    )
    XCTAssertEqual(result.added, 0)
    XCTAssertEqual(result.skipped, 1)
    let items = await store.all()
    XCTAssertTrue(items.isEmpty)
  }

  func testJSONStoreImportCopiesBlobAndCountsMissing() async throws {
    let storeRoot = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("import-store-\(UUID().uuidString)")
    let store = try await JSONSnapshotClipStore(
      root: storeRoot, cap: 100, inlineThresholdBytes: 16
    )

    // Build a fake source directory with one blob file present and
    // one item whose blob is missing.
    let srcRoot = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("import-src-\(UUID().uuidString)")
    let srcBlobs = srcRoot.appendingPathComponent("blobs")
    try FileManager.default.createDirectory(
      at: srcBlobs, withIntermediateDirectories: true
    )
    let payloadData = Data(repeating: 0x77, count: 2048)
    let sha = Hashing.sha256(of: payloadData)
    let blobName = "\(sha).png"
    try payloadData.write(to: srcBlobs.appendingPathComponent(blobName))

    let goodItem = makeItem(sha: "present", blobs: [(blobName, sha)])
    let missingItem = makeItem(
      sha: "missing",
      blobs: [(path: "nope.png", sha: "nope")]
    )

    let result = await store.importItems([goodItem, missingItem], blobsRoot: srcBlobs)
    XCTAssertEqual(result.added, 1)
    XCTAssertEqual(result.skipped, 0)
    XCTAssertEqual(result.blobsMissing, 1)

    let destBlobs = storeRoot.appendingPathComponent("blobs")
    let contents =
      (try? FileManager.default.contentsOfDirectory(atPath: destBlobs.path))
      ?? []
    XCTAssertTrue(contents.contains(where: { $0.hasPrefix(sha) }))
  }

  private func rawText(_ text: String) -> RawClipItem {
    let data = Data(text.utf8)
    return RawClipItem(
      payloads: [RawPayload(pasteboardType: "public.utf8-plain-text", data: data)],
      bundleID: nil,
      changeCount: 1,
      totalBytes: data.count,
      timestamp: Date()
    )
  }
}
