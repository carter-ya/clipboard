import XCTest

@testable import ClipboardCore

final class BumpToTopTests: XCTestCase {

  private func makeRaw(_ text: String, changeCount: Int) -> RawClipItem {
    let data = Data(text.utf8)
    return RawClipItem(
      payloads: [RawPayload(pasteboardType: "public.utf8-plain-text", data: data)],
      bundleID: nil,
      changeCount: changeCount,
      totalBytes: data.count,
      timestamp: Date()
    )
  }

  func testBumpMovesItemToHeadAndRefreshesCreatedAt() async throws {
    let store = InMemoryClipStore()
    await store.insert(makeRaw("a", changeCount: 1))
    try? await Task.sleep(nanoseconds: 10_000_000)
    await store.insert(makeRaw("b", changeCount: 2))
    try? await Task.sleep(nanoseconds: 10_000_000)
    await store.insert(makeRaw("c", changeCount: 3))

    let before = await store.all()
    XCTAssertEqual(before.map(\.preview), ["c", "b", "a"])
    let target = before.first(where: { $0.preview == "a" })!
    let originalCreatedAt = target.createdAt

    try? await Task.sleep(nanoseconds: 50_000_000)
    await store.bumpToTop(id: target.id)

    let after = await store.all()
    XCTAssertEqual(after.map(\.preview), ["a", "c", "b"])
    let bumped = after.first!
    XCTAssertGreaterThan(bumped.createdAt, originalCreatedAt)
  }

  func testBumpUnknownIDIsNoop() async {
    let store = InMemoryClipStore()
    await store.insert(makeRaw("only", changeCount: 1))
    let before = await store.all()

    await store.bumpToTop(id: UUID())

    let after = await store.all()
    XCTAssertEqual(after.map(\.id), before.map(\.id))
  }

  func testBumpKeepsPinnedFlagUntouched() async throws {
    let store = InMemoryClipStore()
    await store.insert(makeRaw("a", changeCount: 1))
    try? await Task.sleep(nanoseconds: 10_000_000)
    await store.insert(makeRaw("b", changeCount: 2))
    let items = await store.all()
    let aID = items.first(where: { $0.preview == "a" })!.id
    await store.pin(id: aID)

    await store.bumpToTop(id: aID)

    let after = await store.all()
    XCTAssertEqual(after.first?.preview, "a")
    XCTAssertTrue(after.first?.pinned == true)
  }
}
