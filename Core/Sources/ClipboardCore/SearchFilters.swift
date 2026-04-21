import Foundation

public struct SearchFilters: Sendable, Equatable {
  public var kinds: Set<ClipKind>?
  public var pinnedOnly: Bool
  public var includeSensitive: Bool
  public var sourceBundleID: String?

  public init(
    kinds: Set<ClipKind>? = nil,
    pinnedOnly: Bool = false,
    includeSensitive: Bool = true,
    sourceBundleID: String? = nil
  ) {
    self.kinds = kinds
    self.pinnedOnly = pinnedOnly
    self.includeSensitive = includeSensitive
    self.sourceBundleID = sourceBundleID
  }

  public static let all = SearchFilters()
}
