import XCTest

@testable import ClipboardCore

final class SensitiveTransitionTests: XCTestCase {
  private let text = Data(("sk-" + String(repeating: "Synthetic123", count: 4)).utf8)
  private func root() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "sensitive-transition-" + UUID().uuidString)
  }

  func testPromotionPreservesAllOriginalRepresentationsOnPrimaryHashDedup() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try await JSONSnapshotClipStore(root: root, inlineThresholdBytes: 1)
    let html = Data("<b>independent original representation</b>".utf8)
    let originalPayloads = [
      RawPayload(pasteboardType: "public.utf8-plain-text", data: text),
      RawPayload(pasteboardType: "public.html", data: html),
    ]
    await store.insert(RawClipItem(payloads: originalPayloads, totalBytes: text.count + html.count))
    let before = await store.all()
    let id = try XCTUnwrap(before.first?.id)
    await store.pin(id: id)
    await store.flush()
    await store.insert(
      RawClipItem(
        payloads: [originalPayloads[0]], totalBytes: text.count,
        isSensitive: true, sensitivityReason: "credentialPattern"))
    await store.flush()
    let after = await store.all()
    let promoted = try XCTUnwrap(after.first)
    XCTAssertEqual(promoted.id, id)
    XCTAssertTrue(promoted.pinned)
    XCTAssertTrue(promoted.sensitive)
    XCTAssertEqual(promoted.payloads.count, 2)
    let clipboard = FakeRichClipboard()
    try RichPasteboardWriter(clipboard: clipboard, blobRoot: root.appendingPathComponent("blobs"))
      .write(promoted)
    let copied = try clipboard.read(maxBytes: 4096)
    XCTAssertEqual(copied?.payloads, originalPayloads)
    XCTAssertEqual(copied?.sensitive, true)
    let blobs = try await store.blobs.listFiles()
    XCTAssertTrue(blobs.isEmpty)
  }

  func testFailedSnapshotRetainsOriginalBlobUntilSuccessfulExplicitRetry() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try await JSONSnapshotClipStore(
      root: root, inlineThresholdBytes: 1, debounceInterval: 3600)
    let payload = RawPayload(pasteboardType: "public.utf8-plain-text", data: text)
    await store.insert(RawClipItem(payloads: [payload], totalBytes: text.count))
    await store.flush()
    let originalBlobs = try await store.blobs.listFiles()
    XCTAssertEqual(originalBlobs.count, 1)
    let history = root.appendingPathComponent("history.json")
    let saved = root.appendingPathComponent("blocked-original.json")
    try FileManager.default.moveItem(at: history, to: saved)
    try FileManager.default.createDirectory(at: history, withIntermediateDirectories: false)
    await store.insert(
      RawClipItem(
        payloads: [payload], totalBytes: text.count,
        isSensitive: true, sensitivityReason: "credentialPattern"))
    let pendingBlobs = try await store.blobs.listFiles()
    let pending = await store.hasPendingSensitivePersistence
    XCTAssertTrue(pending)
    XCTAssertEqual(
      pendingBlobs, originalBlobs,
      "failed snapshot replacement must not release the old persisted reference")
    let live = await store.all()
    XCTAssertEqual(live.first?.sensitive, true)
    XCTAssertEqual(live.first?.payloads.first?.inlineData, text)
    try FileManager.default.removeItem(at: history)
    try FileManager.default.moveItem(at: saved, to: history)
    await store.flush()
    let pendingAfterRetry = await store.hasPendingSensitivePersistence
    XCTAssertFalse(pendingAfterRetry)
    let remaining = try await store.blobs.listFiles()
    XCTAssertTrue(remaining.isEmpty)
    let reopened = try await JSONSnapshotClipStore(root: root)
    let diskItems = await reopened.all()
    XCTAssertTrue(diskItems.isEmpty)
  }

  func testMissingOriginalRepresentationDefersCleanupUntilItCanBeRetried() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try await JSONSnapshotClipStore(
      root: root, inlineThresholdBytes: 1, debounceInterval: 3600)
    let html = Data("<b>original HTML must survive a temporary read failure</b>".utf8)
    let payloads = [
      RawPayload(pasteboardType: "public.utf8-plain-text", data: text),
      RawPayload(pasteboardType: "public.html", data: html),
    ]
    await store.insert(RawClipItem(payloads: payloads, totalBytes: text.count + html.count))
    await store.flush()
    let before = await store.all()
    let original = try XCTUnwrap(before.first)
    let htmlPath = try XCTUnwrap(
      original.payloads.first { $0.pasteboardType == "public.html" }?.blobPath)
    let file = root.appendingPathComponent("blobs").appendingPathComponent(htmlPath)
    let held = root.appendingPathComponent("held-original")
    let savedSnapshot = try Data(contentsOf: root.appendingPathComponent("history.json"))
    try FileManager.default.moveItem(at: file, to: held)
    await store.insert(
      RawClipItem(
        payloads: [payloads[0]], totalBytes: text.count,
        isSensitive: true, sensitivityReason: "credentialPattern"))
    await store.flush()
    let pending = await store.hasPendingSensitivePersistence
    XCTAssertTrue(pending)
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("history.json")), savedSnapshot)
    let interim = await store.all()
    XCTAssertTrue(interim.first?.sensitive == true)
    XCTAssertEqual(interim.first?.payloads.count, 2)
    try FileManager.default.moveItem(at: held, to: file)
    await store.flush()
    let completed = await store.hasPendingSensitivePersistence
    XCTAssertFalse(completed)
    let memory = await store.all()
    let allBytes = try XCTUnwrap(memory.first).payloads.map(\.inlineData)
    XCTAssertEqual(allBytes, [text, html])
    let files = try await store.blobs.listFiles()
    XCTAssertTrue(files.isEmpty)
  }

  private actor HeldCredential: DesktopCredentialStoring {
    var pending: CheckedContinuation<String?, Never>?
    var waiter: CheckedContinuation<Void, Never>?
    func read(account: String) async -> String? {
      await withCheckedContinuation {
        pending = $0
        waiter?.resume()
        waiter = nil
      }
    }
    func started() async { if pending == nil { await withCheckedContinuation { waiter = $0 } } }
    func release() {
      pending?.resume(returning: "synthetic-test-credential")
      pending = nil
    }
    func save(_ value: String, account: String) {}
    func delete(account: String) {}
  }

  private final class CleanupFailureFiles: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var blocked = false
    func block(_ value: Bool) {
      lock.lock()
      blocked = value
      lock.unlock()
    }
    override func removeItem(at url: URL) throws {
      lock.lock()
      let fail = blocked
      lock.unlock()
      if fail && url.deletingLastPathComponent().lastPathComponent == "blobs" {
        throw CocoaError(.fileWriteNoPermission)
      }
      try super.removeItem(at: url)
    }
  }

  func testCommittedSnapshotRetainsCleanupFailureForExplicitRetry() async throws {
    let root = root()
    let files = CleanupFailureFiles()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try await JSONSnapshotClipStore(
      root: root, inlineThresholdBytes: 1,
      debounceInterval: 3600, fileManager: files)
    let payload = RawPayload(pasteboardType: "public.utf8-plain-text", data: text)
    await store.insert(RawClipItem(payloads: [payload], totalBytes: text.count))
    await store.flush()
    files.block(true)
    await store.insert(
      RawClipItem(
        payloads: [payload], totalBytes: text.count,
        isSensitive: true, sensitivityReason: "credentialPattern"))
    let pending = await store.hasPendingSensitivePersistence
    let retained = try await store.blobs.listFiles()
    XCTAssertTrue(pending)
    XCTAssertEqual(retained.count, 1)
    let envelope =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: root.appendingPathComponent("history.json"))) as? [String: Any]
    XCTAssertEqual((envelope?["items"] as? [Any])?.count, 0)
    files.block(false)
    await store.flush()
    let completed = await store.hasPendingSensitivePersistence
    let remaining = try await store.blobs.listFiles()
    XCTAssertFalse(completed)
    XCTAssertTrue(remaining.isEmpty)
  }

  func testConcurrentFlushDoesNotReleaseAnotherLiveRecordsSharedBlob() async throws {
    for _ in 0..<3 {
      let root = root()
      defer { try? FileManager.default.removeItem(at: root) }
      let store = try await JSONSnapshotClipStore(
        root: root, inlineThresholdBytes: 1, debounceInterval: 3600)
      let first = RawPayload(pasteboardType: "public.utf8-plain-text", data: text)
      let other = RawPayload(pasteboardType: "public.utf8-plain-text", data: text + Data([66]))
      // The transport deliberately treats opaque image bytes as binary. This
      // independent live record owns a second reference to the same blob.
      let binary = RawPayload(pasteboardType: "public.png", data: other.data)
      for payload in [first, other, binary] {
        await store.insert(RawClipItem(payloads: [payload], totalBytes: payload.data.count))
      }
      await store.flush()
      let existing = await store.all()
      let keeper = try XCTUnwrap(existing.first { $0.kind == .image })
      let history = root.appendingPathComponent("history.json")
      let saved = root.appendingPathComponent("saved-snapshot")
      try FileManager.default.moveItem(at: history, to: saved)
      try FileManager.default.createDirectory(at: history, withIntermediateDirectories: false)
      for payload in [first, other] {
        await store.insert(
          RawClipItem(
            payloads: [payload], totalBytes: payload.data.count,
            isSensitive: true, sensitivityReason: "credentialPattern"))
      }
      try FileManager.default.removeItem(at: history)
      try FileManager.default.moveItem(at: saved, to: history)
      await withTaskGroup(of: Void.self) { group in
        for _ in 0..<12 { group.addTask { await store.flush() } }
      }
      let pending = await store.hasPendingSensitivePersistence
      XCTAssertFalse(pending)
      let copied = try PayloadResolver(blobRoot: root.appendingPathComponent("blobs")).data(
        for: keeper.payloads[0])
      XCTAssertEqual(copied, other.data)
      let counts = await store.blobs.currentRefCounts
      XCTAssertEqual(counts[Hashing.sha256(of: other.data)], 1)
    }
  }

  func testLiveSensitivityCheckStopsHeldCredentialRequestBeforeUICancellation() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try await JSONSnapshotClipStore(root: root, inlineThresholdBytes: 1)
    let payload = RawPayload(pasteboardType: "public.utf8-plain-text", data: text)
    await store.insert(RawClipItem(payloads: [payload], totalBytes: text.count))
    let items = await store.all()
    let stale = try XCTUnwrap(items.first)
    let credentials = HeldCredential()
    let transport = FakeDesktopAITransport()
    let service = DesktopAnalysis(
      credentials: credentials, transport: transport, ocr: FakeDesktopOCR(),
      blobRoot: root.appendingPathComponent("blobs"), latestItem: { id in await store.item(id: id) }
    )
    var settings = DesktopAISettings()
    settings.enabled = true
    settings.usesCredential = true
    settings.model = "synthetic-fixture"
    let configuration = settings
    let work = Task { try await service.summarize(stale, settings: configuration) }
    await credentials.started()
    await store.insert(
      RawClipItem(
        payloads: [payload], totalBytes: text.count,
        isSensitive: true, sensitivityReason: "credentialPattern"))
    // Deliberately do not cancel work: the independent live metadata gate must
    // close the delay before the UI event observer gets an opportunity to run.
    await credentials.release()
    do {
      _ = try await work.value
      XCTFail("sensitive content reached transport")
    } catch { XCTAssertEqual(error as? DesktopServiceError, .sensitiveContent) }
    let requests = await transport.requests
    XCTAssertTrue(requests.isEmpty)
    await store.flush()
  }
}
