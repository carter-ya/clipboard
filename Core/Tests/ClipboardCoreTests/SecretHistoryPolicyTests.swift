import XCTest

@testable import ClipboardCore

final class SecretHistoryPolicyTests: XCTestCase {
  private var key: Data { Data(("sk-proj-" + String(repeating: "Synthetic123", count: 4)).utf8) }
  private func root() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "secret-history-" + UUID().uuidString)
  }
  private func raw(_ bytes: Data) -> RawClipItem {
    .init(
      payloads: [.init(pasteboardType: "public.utf8-plain-text", data: bytes)],
      totalBytes: bytes.count)
  }

  func testBootstrapReclassifiesOriginalInlineAndBlobRecordsBeforeExposure() async throws {
    for threshold in [1, 4096] {
      let folder = root()
      defer { try? FileManager.default.removeItem(at: folder) }
      let old = try await JSONSnapshotClipStore(
        root: folder, inlineThresholdBytes: threshold, sensitiveTextMasking: false)
      var capture = raw(key)
      let html = Data("<b>original additional representation</b>".utf8)
      capture.payloads.append(.init(pasteboardType: "public.html", data: html))
      capture.totalBytes += html.count
      await old.insert(capture)
      let originalItems = await old.all()
      let original = try XCTUnwrap(originalItems.first)
      await old.pin(id: original.id)
      await old.updateSummary(
        id: original.id, summary: "old synthetic summary", source: .remoteOpenAI)
      await old.flush()
      let reopened = try await JSONSnapshotClipStore(root: folder)
      let current = await reopened.all()
      let masked = try XCTUnwrap(current.first)
      XCTAssertTrue(masked.sensitive)
      XCTAssertEqual(masked.id, original.id)
      XCTAssertEqual(masked.sha256, original.sha256)
      XCTAssertTrue(masked.pinned)
      XCTAssertNil(masked.summary)
      XCTAssertEqual(masked.payloads.first?.inlineData, key)
      XCTAssertEqual(masked.payloads.count, 2)
      XCTAssertEqual(masked.payloads.last?.inlineData, html)
      let blobs = try await reopened.blobs.listFiles()
      XCTAssertTrue(blobs.isEmpty)
      let disk =
        try JSONSerialization.jsonObject(
          with: Data(contentsOf: folder.appendingPathComponent("history.json"))) as! [String: Any]
      XCTAssertEqual((disk["items"] as? [Any])?.count, 0)
    }
  }

  func testImportRecognizesKeysBeforeWritingOwnedBlobsAndPreservesSourceArchive() async throws {
    let sourceRoot = root()
    let targetRoot = root()
    defer {
      try? FileManager.default.removeItem(at: sourceRoot)
      try? FileManager.default.removeItem(at: targetRoot)
    }
    let source = try await JSONSnapshotClipStore(
      root: sourceRoot, inlineThresholdBytes: 1, sensitiveTextMasking: false)
    await source.insert(raw(key))
    await source.flush()
    let sourceItems = await source.all()
    let before = try Data(contentsOf: sourceRoot.appendingPathComponent("history.json"))
    let target = try await JSONSnapshotClipStore(root: targetRoot, inlineThresholdBytes: 1)
    let imported = await target.importItems(
      sourceItems, blobsRoot: sourceRoot.appendingPathComponent("blobs"))
    XCTAssertEqual(imported.added, 1)
    let current = await target.all()
    XCTAssertEqual(current.first?.sensitive, true)
    XCTAssertEqual(current.first?.payloads.first?.inlineData, key)
    let blobs = try await target.blobs.listFiles()
    XCTAssertTrue(blobs.isEmpty)
    await target.flush()
    let disk =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: targetRoot.appendingPathComponent("history.json"))) as! [String: Any]
    XCTAssertEqual((disk["items"] as? [Any])?.count, 0)
    XCTAssertEqual(try Data(contentsOf: sourceRoot.appendingPathComponent("history.json")), before)
  }

  func testLiveEnableClassifiesExistingRecordsAndDisableCannotDeclassifyThem() async throws {
    let folder = root()
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try await JSONSnapshotClipStore(
      root: folder, inlineThresholdBytes: 1, sensitiveTextMasking: false)
    await store.insert(raw(key))
    await store.flush()
    let old = await store.all()
    XCTAssertEqual(old.first?.sensitive, false)
    let applied = await store.setSensitiveTextMasking(true)
    XCTAssertTrue(applied)
    let masked = await store.all()
    XCTAssertEqual(masked.first?.id, old.first?.id)
    XCTAssertEqual(masked.first?.sensitive, true)
    await store.setSensitiveTextMasking(false)
    let retained = await store.all()
    XCTAssertEqual(retained.first?.sensitive, true)
    let second = key + Data([66])
    await store.insert(raw(second))
    let disabled = await store.all()
    XCTAssertEqual(disabled.first?.sensitive, false)
  }

  func testDisabledStartupPolicyPreservesExistingPreference() async throws {
    let folder = root()
    defer { try? FileManager.default.removeItem(at: folder) }
    let old = try await JSONSnapshotClipStore(root: folder, sensitiveTextMasking: false)
    await old.insert(raw(key))
    await old.flush()
    let reopened = try await JSONSnapshotClipStore(root: folder, sensitiveTextMasking: false)
    let current = await reopened.all()
    XCTAssertEqual(current.first?.sensitive, false)
    XCTAssertEqual(current.first?.payloads.first?.inlineData, key)
  }

  func testUnfilteredInsertUsesStorePolicyBeforeCreatingBlobs() async throws {
    let folder = root()
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try await JSONSnapshotClipStore(root: folder, inlineThresholdBytes: 1)
    await store.insert(raw(key))
    let current = await store.all()
    XCTAssertEqual(current.first?.sensitive, true)
    let blobs = try await store.blobs.listFiles()
    XCTAssertTrue(blobs.isEmpty)
  }

  func testImportRejectsExternalAndInvalidReferencesWithoutPartialOwnedBlobs() async throws {
    let sourceRoot = root()
    let targetRoot = root()
    defer {
      try? FileManager.default.removeItem(at: sourceRoot)
      try? FileManager.default.removeItem(at: targetRoot)
    }
    let source = try await JSONSnapshotClipStore(
      root: sourceRoot, inlineThresholdBytes: 1, sensitiveTextMasking: false)
    await source.insert(raw(Data("ordinary valid text".utf8)))
    await source.flush()
    let original = await source.all()[0]
    let target = try await JSONSnapshotClipStore(root: targetRoot, inlineThresholdBytes: 1)
    for path in ["../history.json", "/tmp/external", String(repeating: "0", count: 64) + ".txt"] {
      var invalid = original
      invalid.payloads.append(.init(pasteboardType: "public.html", blobPath: path))
      let result = await target.importItems(
        [invalid], blobsRoot: sourceRoot.appendingPathComponent("blobs"))
      XCTAssertEqual(result.added, 0)
      XCTAssertEqual(result.blobsMissing, 1)
      let blobs = try await target.blobs.listFiles()
      XCTAssertTrue(blobs.isEmpty, "validation must finish before any owned blob write")
    }
  }

  func testImportBatchDeduplicatesUsingValidatedContent() async throws {
    let folder = root()
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try await JSONSnapshotClipStore(root: folder)
    let bytes = Data("ordinary payload".utf8)
    let item = ClipItem(
      createdAt: Date(), kind: .text, preview: "stale metadata", sha256: "untrusted", sizeBytes: 0,
      payloads: [.init(pasteboardType: "public.utf8-plain-text", inlineData: bytes)])
    let result = await store.importItems([item, item], blobsRoot: nil)
    XCTAssertEqual(result.added, 1)
    XCTAssertEqual(result.skipped, 1)
    let current = await store.all()
    XCTAssertEqual(current.first?.preview, "ordinary payload")
    XCTAssertEqual(current.first?.sha256, Hashing.sha256(of: raw(bytes).payloads))
  }

  func testUnreadableStartupTextStaysMaskedAndPendingUntilOriginalIsRestored() async throws {
    let folder = root()
    defer { try? FileManager.default.removeItem(at: folder) }
    let old = try await JSONSnapshotClipStore(
      root: folder, inlineThresholdBytes: 1, sensitiveTextMasking: false)
    await old.insert(raw(key))
    await old.flush()
    let oldItems = await old.all()
    let path = try XCTUnwrap(oldItems.first?.payloads.first?.blobPath)
    let file = folder.appendingPathComponent("blobs").appendingPathComponent(path)
    try Data("synthetic invalid digest".utf8).write(to: file)
    let store = try await JSONSnapshotClipStore(root: folder)
    let current = await store.all()
    XCTAssertEqual(current.first?.sensitive, true)
    XCTAssertEqual(current.first?.sensitivityReason, "sensitivityUnavailable")
    let pending = await store.hasPendingSensitivePersistence
    XCTAssertTrue(pending)
    try key.write(to: file)
    await store.flush()
    let afterRetry = await store.all()
    XCTAssertEqual(afterRetry.first?.payloads.first?.inlineData, key)
    let stillPending = await store.hasPendingSensitivePersistence
    XCTAssertFalse(stillPending)
  }
}
