import XCTest

@testable import ClipboardCore

/// Covers `ClipStore.updateSummary(id:summary:source:)` semantics
/// introduced in S64. The coordinator in the app module calls this
/// after an on-device Vision / Writing Tools / Foundation Models run
/// finishes; we need to make sure the store updates both fields,
/// emits an .updated event, and ignores unknown ids.
final class UpdateSummaryTests: XCTestCase {

  private func makeRaw(_ text: String, pasteboardType: String = "public.utf8-plain-text")
    -> RawClipItem
  {
    let data = Data(text.utf8)
    return RawClipItem(
      payloads: [RawPayload(pasteboardType: pasteboardType, data: data)],
      bundleID: nil,
      changeCount: 1,
      totalBytes: data.count,
      timestamp: Date()
    )
  }

  func testUpdateSummaryAttachesFields() async {
    let store = InMemoryClipStore()
    await store.insert(makeRaw("png-bytes", pasteboardType: "public.png"))
    let id = (await store.all()).first!.id

    await store.updateSummary(id: id, summary: "A dog on grass", source: .vision)

    let updated = await store.item(id: id)
    XCTAssertEqual(updated?.summary, "A dog on grass")
    XCTAssertEqual(updated?.summarySource, .vision)
  }

  func testUpdateSummaryReplacesExisting() async {
    let store = InMemoryClipStore()
    await store.insert(makeRaw("png-bytes", pasteboardType: "public.png"))
    let id = (await store.all()).first!.id
    await store.updateSummary(id: id, summary: "old summary", source: .vision)

    await store.updateSummary(
      id: id, summary: "richer summary", source: .foundationModels)

    let updated = await store.item(id: id)
    XCTAssertEqual(updated?.summary, "richer summary")
    XCTAssertEqual(updated?.summarySource, .foundationModels)
  }

  func testUpdateSummaryUnknownIDIsNoop() async {
    let store = InMemoryClipStore()
    await store.insert(makeRaw("png-bytes", pasteboardType: "public.png"))
    let before = await store.all()
    await store.updateSummary(id: UUID(), summary: "ignored", source: .vision)
    let after = await store.all()
    XCTAssertEqual(before.map(\.summary), after.map(\.summary))
  }
}
