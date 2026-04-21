import XCTest

@testable import ClipboardCore

final class BlobStoreTests: XCTestCase {
  private func makeRoot() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("blobstore-test-\(UUID().uuidString)")
  }

  func testStoreAndRetainCount() async throws {
    let root = makeRoot()
    let store = try BlobStore(root: root)
    let data = Data(repeating: 0x42, count: 1024)
    let sha = Hashing.sha256(of: data)

    let first = try await store.store(data: data, sha256: sha, ext: "bin")
    var refs = await store.currentRefCounts
    XCTAssertEqual(refs[sha], 1)

    let second = try await store.store(data: data, sha256: sha, ext: "bin")
    XCTAssertEqual(first, second, "same sha returns same relative path")
    refs = await store.currentRefCounts
    XCTAssertEqual(refs[sha], 2)

    let files = try await store.listFiles()
    XCTAssertEqual(files.count, 1, "dedup should not create a second file")
  }

  func testReleaseDeletesFileOnlyWhenCountDrops() async throws {
    let root = makeRoot()
    let store = try BlobStore(root: root)
    let data = Data("hello".utf8)
    let sha = Hashing.sha256(of: data)
    _ = try await store.store(data: data, sha256: sha, ext: "txt")
    _ = try await store.store(data: data, sha256: sha, ext: "txt")

    var deleted = await store.release(sha256: sha)
    XCTAssertFalse(deleted, "count drops from 2 to 1, file must stay")
    var refs = await store.currentRefCounts
    XCTAssertEqual(refs[sha], 1)

    deleted = await store.release(sha256: sha)
    XCTAssertTrue(deleted, "count hits 0, file must be deleted")
    refs = await store.currentRefCounts
    XCTAssertNil(refs[sha])

    let files = try await store.listFiles()
    XCTAssertTrue(files.isEmpty)
  }

  func testReleaseUnknownIsNoop() async throws {
    let root = makeRoot()
    let store = try BlobStore(root: root)
    let deleted = await store.release(sha256: "nonexistent")
    XCTAssertFalse(deleted)
  }

  func testReconcileDeletesOrphans() async throws {
    let root = makeRoot()
    let store = try BlobStore(root: root)

    let data = Data("keep".utf8)
    let sha = Hashing.sha256(of: data)
    _ = try await store.store(data: data, sha256: sha, ext: "txt")

    let orphanURL = root.appendingPathComponent("orphan-xyz.bin")
    try Data("stray".utf8).write(to: orphanURL)

    let deleted = try await store.reconcile()
    XCTAssertEqual(deleted, 1, "one orphan should be removed")

    let files = try await store.listFiles()
    XCTAssertEqual(files.count, 1)
    XCTAssertTrue(files.first?.hasPrefix(sha) ?? false)
  }

  func testRebuildRefCountsFromItems() async throws {
    let root = makeRoot()
    let store = try BlobStore(root: root)

    let shaA = "aaa"
    let shaB = "bbb"
    let items = [
      ClipItem(
        createdAt: Date(), kind: .image, preview: "", sha256: "itemA",
        sizeBytes: 0,
        payloads: [Payload(pasteboardType: "public.png", blobPath: "\(shaA).png")]
      ),
      ClipItem(
        createdAt: Date(), kind: .image, preview: "", sha256: "itemB",
        sizeBytes: 0,
        payloads: [
          Payload(pasteboardType: "public.png", blobPath: "\(shaA).png"),
          Payload(pasteboardType: "public.tiff", blobPath: "\(shaB).tiff"),
        ]
      ),
    ]
    await store.rebuildRefCounts(from: items)
    let refs = await store.currentRefCounts
    XCTAssertEqual(refs[shaA], 2)
    XCTAssertEqual(refs[shaB], 1)
  }
}
