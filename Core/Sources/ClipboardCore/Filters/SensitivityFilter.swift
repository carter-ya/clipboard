import Foundation

public struct SensitivityFilter: ClipFilter {
  public static let concealedType = "org.nspasteboard.ConcealedType"
  public let skipSensitive: Bool

  public init(skipSensitive: Bool = true) {
    self.skipSensitive = skipSensitive
  }

  public func evaluate(_ item: RawClipItem, context: ClipContext) -> FilterDecision {
    guard skipSensitive else { return .accept }
    if item.payloads.contains(where: { $0.pasteboardType == Self.concealedType }) {
      return .markSensitive("concealedType")
    }
    return .accept
  }
}

public struct BlocklistFilter: ClipFilter {
  public let blockedBundleIDs: Set<String>

  public init(blockedBundleIDs: Set<String>) {
    self.blockedBundleIDs = blockedBundleIDs
  }

  public init(blockedBundleIDs: [String]) {
    self.blockedBundleIDs = Set(blockedBundleIDs)
  }

  public func evaluate(_ item: RawClipItem, context: ClipContext) -> FilterDecision {
    guard let bundleID = context.sourceBundleID else { return .accept }
    if blockedBundleIDs.contains(bundleID) {
      return .markSensitive("blockedSource:\(bundleID)")
    }
    return .accept
  }

  public static let defaults: Set<String> = [
    "com.1password.1password",
    "com.1password.1password7",
    "com.agilebits.onepassword7",
    "com.bitwarden.desktop",
    "com.apple.keychainaccess",
  ]
}
