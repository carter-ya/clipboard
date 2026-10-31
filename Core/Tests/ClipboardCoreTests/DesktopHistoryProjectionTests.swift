import XCTest

@testable import ClipboardCore

final class DesktopHistoryProjectionTests: XCTestCase {
  private func fixture() -> [ClipItem] {
    [ClipKind.text, .image, .mixed, .file, .image, .rtf].enumerated().map { index, kind in
      ClipItem(
        createdAt: Date(), kind: kind, preview: "fixture", sha256: "fixture-\(index)",
        sizeBytes: 0, pinned: index == 0 || index == 1, sensitive: index == 2)
    }
  }

  func testKindFilteringRetainsQueryWideTabCountsAndOrdering() {
    let items = fixture()
    let projection = DesktopHistoryProjection(matching: items, onlyPinned: false, kind: .image)
    XCTAssertEqual(projection.allCount, 6)
    XCTAssertEqual(projection.pinnedCount, 2)
    XCTAssertEqual(projection.allTypesCount, 6)
    XCTAssertEqual(projection.kindCounts[.text], 1)
    XCTAssertEqual(projection.kindCounts[.image], 2)
    XCTAssertEqual(projection.kindCounts[.mixed], 1)
    XCTAssertEqual(projection.items.map(\.id), [items[1].id, items[4].id])
  }

  func testKindCountsFollowPinnedTabEvenWhenSelectedKindHasNoResults() {
    let projection = DesktopHistoryProjection(matching: fixture(), onlyPinned: true, kind: .file)
    XCTAssertTrue(projection.items.isEmpty)
    XCTAssertEqual(projection.allCount, 6)
    XCTAssertEqual(projection.pinnedCount, 2)
    XCTAssertEqual(projection.allTypesCount, 2)
    XCTAssertEqual(projection.kindCounts[.text], 1)
    XCTAssertEqual(projection.kindCounts[.image], 1)
    XCTAssertEqual(projection.kindCounts[.mixed, default: 0], 0)
  }

  func testMatchedScopeAndLegacySensitiveMixedKindRemainAvailable() {
    let matched = Array(fixture()[2...3])
    let projection = DesktopHistoryProjection(matching: matched, onlyPinned: false, kind: .mixed)
    XCTAssertEqual(projection.allCount, 2)
    XCTAssertEqual(projection.pinnedCount, 0)
    XCTAssertEqual(projection.items.map(\.id), [matched[0].id])
    XCTAssertTrue(projection.items[0].sensitive)
    let empty = DesktopHistoryProjection(matching: [], onlyPinned: true, kind: .rtf)
    XCTAssertEqual(empty.allCount, 0)
    XCTAssertEqual(empty.allTypesCount, 0)
    XCTAssertTrue(empty.kindCounts.isEmpty)
    XCTAssertTrue(empty.items.isEmpty)
  }
}
