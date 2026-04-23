import AppKit
import Foundation

/// Resolves a source bundle identifier (e.g. "com.apple.Notes") to a
/// human-readable app name (e.g. "Notes") via NSWorkspace + Finder's
/// localized display name. Results are cached per session — the
/// mapping is stable while the app remains installed, so a single
/// resolve per bundle ID is enough. If the app can't be located the
/// raw bundle ID is returned so uninstalled sources stay identifiable
/// rather than collapsing to "unknown".
final class BundleNameResolver: @unchecked Sendable {
  static let shared = BundleNameResolver()

  private let queue = DispatchQueue(label: "com.clipboard.bundle-name")
  private var cache: [String: String] = [:]

  func displayName(for bundleID: String) -> String {
    queue.sync {
      if let cached = cache[bundleID] { return cached }
      let resolved = Self.resolve(bundleID: bundleID) ?? bundleID
      cache[bundleID] = resolved
      return resolved
    }
  }

  private static func resolve(bundleID: String) -> String? {
    guard
      let url = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: bundleID
      )
    else { return nil }
    let name = FileManager.default.displayName(atPath: url.path)
    let trimmed =
      name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    return trimmed.isEmpty ? nil : trimmed
  }
}
