import Foundation

/// Project a query/source-matched snapshot without collapsing tab counts to one kind.
public struct DesktopHistoryProjection: Sendable {
  public let items: [ClipItem]
  public let allCount: Int
  public let pinnedCount: Int
  public let allTypesCount: Int
  public let kindCounts: [ClipKind: Int]

  public init(matching: [ClipItem], onlyPinned: Bool, kind: ClipKind?) {
    allCount = matching.count
    pinnedCount = matching.filter(\.pinned).count
    let tabItems = onlyPinned ? matching.filter(\.pinned) : matching
    allTypesCount = tabItems.count
    var counts: [ClipKind: Int] = [:]
    for item in tabItems { counts[item.kind, default: 0] += 1 }
    kindCounts = counts
    items = kind.map { kind in tabItems.filter { $0.kind == kind } } ?? tabItems
  }
}
