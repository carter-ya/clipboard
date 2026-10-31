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
  private let comparisonIDs: Set<String>

  public init(blockedBundleIDs: Set<String>) {
    self.blockedBundleIDs = blockedBundleIDs
    comparisonIDs = Set(blockedBundleIDs.map(Self.comparisonKey))
  }

  public init(blockedBundleIDs: [String]) {
    self.init(blockedBundleIDs: Set(blockedBundleIDs))
  }

  private static func comparisonKey(_ identifier: String) -> String {
    // Windows executable identities ignore case. Normalize both custom rules
    // and observed IDs without changing their public spelling. X11 window
    // classes and Mac bundle IDs keep their existing comparison behavior.
    if identifier.prefix(8).lowercased() == "windows:" { return identifier.lowercased() }
    return identifier
  }

  public func evaluate(_ item: RawClipItem, context: ClipContext) -> FilterDecision {
    guard let bundleID = context.sourceBundleID else { return .accept }
    if comparisonIDs.contains(Self.comparisonKey(bundleID)) {
      return .markSensitive("blockedSource:\(bundleID)")
    }
    return .accept
  }

  public static let defaults: Set<String> = {
    let apple: Set<String> = [
      "com.1password.1password", "com.1password.1password7", "com.agilebits.onepassword7",
      "com.bitwarden.desktop", "com.apple.keychainaccess",
    ]
    #if os(Windows)
      return apple.union([
        "windows:1password.exe", "windows:bitwarden.exe", "windows:keepass.exe",
        "windows:keepassxc.exe",
      ])
    #elseif os(Linux)
      return apple.union([
        "linux:1Password", "linux:Bitwarden", "linux:KeePassXC", "linux:keepassxc",
      ])
    #else
      return apple
    #endif
  }()
}
