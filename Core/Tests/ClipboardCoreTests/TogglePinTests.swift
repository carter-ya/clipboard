import XCTest

@testable import ClipboardCore

final class TogglePinTests: XCTestCase {

  private func makeRaw(_ text: String) -> RawClipItem {
    let data = Data(text.utf8)
    return RawClipItem(
      payloads: [RawPayload(pasteboardType: "public.utf8-plain-text", data: data)],
      bundleID: nil,
      changeCount: 1,
      totalBytes: data.count,
      timestamp: Date()
    )
  }

  func testTogglePinFlipsState() async {
    let store = InMemoryClipStore()
    await store.insert(makeRaw("alpha"))
    let id = (await store.all()).first!.id

    await store.togglePin(id: id)
    var item = await store.item(id: id)
    XCTAssertEqual(item?.pinned, true)

    await store.togglePin(id: id)
    item = await store.item(id: id)
    XCTAssertEqual(item?.pinned, false)
  }

  func testTogglePinUnknownIDIsNoop() async {
    let store = InMemoryClipStore()
    await store.insert(makeRaw("alpha"))
    let before = await store.all()
    await store.togglePin(id: UUID())
    let after = await store.all()
    XCTAssertEqual(before.map(\.pinned), after.map(\.pinned))
  }

  func testJSONStoreTogglePinPersistsForNonSensitive() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("togglepin-persist-\(UUID().uuidString)")
    let store = try await JSONSnapshotClipStore(root: root, cap: 100)
    await store.insert(makeRaw("keep"))
    let id = (await store.all()).first!.id

    await store.togglePin(id: id)
    await store.flush()

    let reopened = try await JSONSnapshotClipStore(root: root, cap: 100)
    let items = await reopened.all()
    XCTAssertEqual(items.first?.pinned, true, "pin must survive reload")
  }

  func testJSONStoreTogglePinOnSensitiveDoesNotWriteDisk() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("togglepin-sensitive-\(UUID().uuidString)")
    let store = try await JSONSnapshotClipStore(root: root, cap: 100)
    let data = Data("secret".utf8)
    let raw = RawClipItem(
      payloads: [RawPayload(pasteboardType: "public.utf8-plain-text", data: data)],
      bundleID: nil,
      changeCount: 1,
      totalBytes: data.count,
      timestamp: Date(),
      isSensitive: true,
      sensitivityReason: "concealedType"
    )
    await store.insert(raw)
    let id = (await store.all()).first!.id
    await store.togglePin(id: id)
    await store.flush()

    let historyPath = root.appendingPathComponent("history.json").path
    if let data = try? Data(contentsOf: root.appendingPathComponent("history.json")),
      let text = String(data: data, encoding: .utf8)
    {
      XCTAssertFalse(text.contains("secret"), "sensitive content must not leak to disk")
    } else {
      // No history.json at all is also acceptable (only sensitive items).
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: historyPath)
          && (try? String(contentsOfFile: historyPath))?.contains("secret") == true,
        "sensitive content must not leak to disk"
      )
    }
  }
}
