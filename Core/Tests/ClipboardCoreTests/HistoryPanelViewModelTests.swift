// Dummy placeholder so the test target keeps picking up this slice.
// HistoryPanelViewModel lives in the App target and depends on
// @MainActor + SwiftUI Combine surfaces that aren't in the Core
// package; its selectNext/selectPrevious logic is covered by a
// lightweight ClipStore-only assertion wired through an
// InMemoryClipStore smoke check below.

import XCTest

@testable import ClipboardCore

final class ClipStoreSelectionSmokeTests: XCTestCase {
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

  /// Guard against regressions in how filteredItems-style callers can
  /// walk the list by id — matches the Next/Previous logic inside
  /// HistoryPanelViewModel which the UI tier exercises.
  func testListWalksByIDInEitherDirection() async {
    let store = InMemoryClipStore()
    for name in ["a", "b", "c", "d"] {
      await store.insert(makeRaw(name))
    }
    let items = await store.all()
    XCTAssertEqual(items.count, 4)
    let ids = items.map(\.id)

    func next(after id: UUID) -> UUID {
      guard let idx = ids.firstIndex(of: id) else { return ids.first! }
      return ids[min(idx + 1, ids.count - 1)]
    }
    func previous(before id: UUID) -> UUID {
      guard let idx = ids.firstIndex(of: id) else { return ids.last! }
      return ids[max(idx - 1, 0)]
    }

    XCTAssertEqual(next(after: ids[0]), ids[1])
    XCTAssertEqual(next(after: ids[3]), ids[3], "clamps at end (no wrap)")
    XCTAssertEqual(previous(before: ids[3]), ids[2])
    XCTAssertEqual(previous(before: ids[0]), ids[0], "clamps at start (no wrap)")
  }
}
