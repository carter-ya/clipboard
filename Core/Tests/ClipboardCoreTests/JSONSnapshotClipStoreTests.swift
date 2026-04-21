import XCTest

@testable import ClipboardCore

final class JSONSnapshotClipStoreTests: XCTestCase {

  private func makeRoot() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("store-test-\(UUID().uuidString)")
  }

  private func makeRaw(
    text: String,
    bundle: String? = nil,
    sensitive: Bool = false,
    changeCount: Int = 1
  ) -> RawClipItem {
    let data = Data(text.utf8)
    return RawClipItem(
      payloads: [RawPayload(pasteboardType: "public.utf8-plain-text", data: data)],
      bundleID: bundle,
      changeCount: changeCount,
      totalBytes: data.count,
      timestamp: Date(),
      isSensitive: sensitive,
      sensitivityReason: sensitive ? "concealedType" : nil
    )
  }

  func testInsertOrderingNewestFirst() async throws {
    let root = makeRoot()
    let store = try await JSONSnapshotClipStore(root: root, cap: 100)
    for i in 0..<5 {
      await store.insert(makeRaw(text: "item-\(i)", changeCount: i + 1))
    }
    let all = await store.all()
    XCTAssertEqual(all.count, 5)
    XCTAssertEqual(all.first?.preview, "item-4")
    XCTAssertEqual(all.last?.preview, "item-0")
  }

  func testDedupMovesToTopPreservingSourceBundle() async throws {
    let root = makeRoot()
    let store = try await JSONSnapshotClipStore(root: root, cap: 100)

    await store.insert(makeRaw(text: "repeat", bundle: "com.first.app", changeCount: 1))
    await store.insert(makeRaw(text: "other", bundle: "com.other.app", changeCount: 2))
    await store.insert(makeRaw(text: "repeat", bundle: "com.second.app", changeCount: 3))

    let all = await store.all()
    XCTAssertEqual(all.count, 2, "dedup keeps one entry, not two")
    XCTAssertEqual(all.first?.preview, "repeat")
    XCTAssertEqual(
      all.first?.sourceBundleID,
      "com.first.app",
      "first-write-wins on sourceBundleID"
    )
  }

  func testCapacityEvictsOldestNonPinned() async throws {
    let root = makeRoot()
    let store = try await JSONSnapshotClipStore(root: root, cap: 3)
    await store.insert(makeRaw(text: "a", changeCount: 1))
    await store.insert(makeRaw(text: "b", changeCount: 2))
    await store.insert(makeRaw(text: "c", changeCount: 3))
    let pinTarget = await store.all().last!.id
    await store.pin(id: pinTarget)

    for i in 0..<5 {
      await store.insert(makeRaw(text: "new-\(i)", changeCount: 100 + i))
    }

    let all = await store.all()
    XCTAssertEqual(all.count, 4, "1 pinned + 3 newest = 4")
    XCTAssertTrue(all.contains(where: { $0.id == pinTarget && $0.pinned }))
  }

  func testPinnedCountExceedingCapAllPreserved() async throws {
    let root = makeRoot()
    let store = try await JSONSnapshotClipStore(root: root, cap: 2)
    // Pin each new item immediately so that none are evicted by cap
    for i in 0..<5 {
      await store.insert(makeRaw(text: "p-\(i)", changeCount: i + 1))
      if let newest = await store.all().first {
        await store.pin(id: newest.id)
      }
    }
    let beforeFresh = await store.all()
    XCTAssertEqual(beforeFresh.count, 5)
    await store.insert(makeRaw(text: "fresh", changeCount: 100))

    let all = await store.all()
    XCTAssertEqual(
      all.count,
      6,
      "all 5 pinned stay regardless of cap; plus 1 new non-pinned"
    )
  }

  func testSensitiveItemsStayInMemoryOnly() async throws {
    let root = makeRoot()
    let store = try await JSONSnapshotClipStore(root: root, cap: 100)
    await store.insert(makeRaw(text: "secret", sensitive: true, changeCount: 1))
    await store.insert(makeRaw(text: "normal", sensitive: false, changeCount: 2))
    await store.flush()

    let historyURL = root.appendingPathComponent("history.json")
    let data = try Data(contentsOf: historyURL)
    let json = String(data: data, encoding: .utf8) ?? ""
    XCTAssertFalse(json.contains("secret"), "sensitive content must not be in history.json")
    XCTAssertTrue(json.contains("normal"))

    let all = await store.all()
    XCTAssertEqual(all.count, 2, "sensitive item still visible in-memory")
    XCTAssertTrue(all.contains(where: { $0.sensitive && $0.preview == "secret" }))
  }

  func testSensitiveLargePayloadNotWrittenToBlobs() async throws {
    let root = makeRoot()
    let store = try await JSONSnapshotClipStore(
      root: root,
      cap: 100,
      inlineThresholdBytes: 16
    )
    let big = Data(repeating: 0x58, count: 4096)
    let raw = RawClipItem(
      payloads: [RawPayload(pasteboardType: "public.data", data: big)],
      bundleID: nil,
      changeCount: 1,
      totalBytes: big.count,
      timestamp: Date(),
      isSensitive: true,
      sensitivityReason: "concealedType"
    )
    await store.insert(raw)
    await store.flush()

    let blobsRoot = root.appendingPathComponent("blobs")
    let files = (try? FileManager.default.contentsOfDirectory(atPath: blobsRoot.path)) ?? []
    XCTAssertTrue(
      files.isEmpty,
      "sensitive large payload must not land under blobs/"
    )
  }

  func testRoundTripThroughFlushAndReopen() async throws {
    let root = makeRoot()
    let store = try await JSONSnapshotClipStore(root: root, cap: 100)
    await store.insert(makeRaw(text: "alpha", bundle: "com.a", changeCount: 1))
    await store.insert(makeRaw(text: "beta", bundle: "com.b", changeCount: 2))
    await store.flush()

    let reopened = try await JSONSnapshotClipStore(root: root, cap: 100)
    let items = await reopened.all()
    XCTAssertEqual(items.count, 2)
    XCTAssertEqual(items.first?.preview, "beta")
    XCTAssertEqual(items.last?.preview, "alpha")
  }

  func testCorruptRecoveryProducesBakAndEmptyStart() async throws {
    let root = makeRoot()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let historyURL = root.appendingPathComponent("history.json")
    try Data("this is not JSON".utf8).write(to: historyURL)

    let store = try await JSONSnapshotClipStore(root: root, cap: 100)
    let items = await store.all()
    XCTAssertEqual(items.count, 0)

    let bakURL = root.appendingPathComponent("history.json.bak")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: bakURL.path),
      ".bak should exist"
    )
  }

  func testReconcileDeletesOrphansOnStartup() async throws {
    let root = makeRoot()
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("blobs"),
      withIntermediateDirectories: true
    )
    // plant an orphan before any history is built
    let orphan = root.appendingPathComponent("blobs/stray.bin")
    try Data("garbage".utf8).write(to: orphan)

    var events: [StoreEvent] = []
    let store = try await JSONSnapshotClipStore(root: root, cap: 100)
    let eventTask = Task {
      for await e in store.events {
        events.append(e)
        if case .reconciled = e { break }
      }
    }
    // Reconcile happened synchronously in init; give a moment for event
    try await Task.sleep(nanoseconds: 100_000_000)
    eventTask.cancel()

    XCTAssertFalse(
      FileManager.default.fileExists(atPath: orphan.path),
      "orphan blob should have been deleted"
    )
  }

  func testPreviewTruncatedTo256() async throws {
    let root = makeRoot()
    let store = try await JSONSnapshotClipStore(root: root, cap: 100)
    let long = String(repeating: "x", count: 500)
    await store.insert(makeRaw(text: long, changeCount: 1))
    let items = await store.all()
    XCTAssertEqual(items.first?.preview.count, 256)
  }

  func testDeleteRemovesAndEvictsBlobs() async throws {
    let root = makeRoot()
    let store = try await JSONSnapshotClipStore(
      root: root,
      cap: 100,
      inlineThresholdBytes: 16
    )
    let bigText = String(repeating: "abcdefgh", count: 100)  // 800 bytes
    await store.insert(makeRaw(text: bigText, changeCount: 1))
    let victim = await store.all().first!
    await store.delete(id: victim.id)
    await store.flush()

    let blobsRoot = root.appendingPathComponent("blobs")
    let files =
      (try? FileManager.default.contentsOfDirectory(atPath: blobsRoot.path)) ?? []
    XCTAssertTrue(files.isEmpty, "deleting last referrer should delete blob file")
  }
}
