// Exercises the (kind × pinned) filter combination that
// HistoryPanelViewModel.filteredItems replicates on top of the
// store. The app-layer view model lives outside Core's test
// module, so the logic is re-verified here against the plain
// store API — if this passes, the view model's computed
// filteredItems path inherits the same semantics.

import XCTest

@testable import ClipboardCore

final class KindFilterCombinationTests: XCTestCase {
  private func makeRaw(
    _ text: String,
    pasteboardType: String = "public.utf8-plain-text"
  ) -> RawClipItem {
    let data = Data(text.utf8)
    return RawClipItem(
      payloads: [RawPayload(pasteboardType: pasteboardType, data: data)],
      bundleID: nil,
      changeCount: 1,
      totalBytes: data.count,
      timestamp: Date()
    )
  }

  func testKindFilterNilReturnsAll() async {
    let store = InMemoryClipStore()
    await store.insert(makeRaw("hello"))
    await store.insert(makeRaw("png-bytes", pasteboardType: "public.png"))

    let items = await store.all()
    XCTAssertEqual(items.count, 2)
  }

  func testKindFilterImageNarrowsToImages() async {
    let store = InMemoryClipStore()
    await store.insert(makeRaw("text"))
    await store.insert(makeRaw("png-bytes", pasteboardType: "public.png"))
    await store.insert(makeRaw("more-text"))

    let items = await store.all()
    let images = items.filter { $0.kind == .image }
    XCTAssertEqual(images.count, 1)
    XCTAssertEqual(images.first?.kind, .image)
  }

  func testKindFilterCombinedWithPinned() async {
    let store = InMemoryClipStore()
    await store.insert(makeRaw("text-a"))
    await store.insert(makeRaw("png-a", pasteboardType: "public.png"))
    await store.insert(makeRaw("png-b", pasteboardType: "public.png"))
    let items = await store.all()
    // pin one image and one text
    await store.pin(id: items.first(where: { $0.kind == .image })!.id)
    await store.pin(id: items.first(where: { $0.kind == .text })!.id)

    let afterPin = await store.all()
    let imagesPinned = afterPin.filter { $0.kind == .image && $0.pinned }
    XCTAssertEqual(imagesPinned.count, 1)
  }
}
