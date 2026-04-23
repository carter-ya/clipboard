import AppKit
import ClipboardCore
import Foundation
import Sparkle

/// Thin wrapper around `SPUStandardUpdaterController`. Reads feed URL
/// and EdDSA public key from `Info.plist`. When either value is missing
/// or still carries the placeholder token (pre-first-release builds),
/// the updater is created but will not produce usable checks — the
/// `canCheckForUpdates` flag will be false and the Preferences button
/// disables itself.
@MainActor
final class SparkleUpdater: NSObject {
  private let controller: SPUStandardUpdaterController
  let isConfigured: Bool

  override init() {
    let bundle = Bundle.main
    let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String
    let pubKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
    self.isConfigured = Self.looksConfigured(feed: feed, pubKey: pubKey)
    // Gate startingUpdater on real config so placeholder dev builds
    // don't spam the network every 24h chasing a 404 appcast.
    self.controller = SPUStandardUpdaterController(
      startingUpdater: isConfigured,
      updaterDelegate: nil,
      userDriverDelegate: nil
    )
    super.init()
    if isConfigured {
      Log.ui.info(
        "sparkle.started feed=\(feed ?? "", privacy: .public)"
      )
    } else {
      Log.ui.info("sparkle.placeholder_config — scheduled + manual checks disabled")
    }
  }

  var canCheckForUpdates: Bool {
    isConfigured && controller.updater.canCheckForUpdates
  }

  func checkForUpdates() {
    controller.checkForUpdates(nil)
  }

  private static func looksConfigured(feed: String?, pubKey: String?) -> Bool {
    guard let feed, !feed.isEmpty, let pubKey, !pubKey.isEmpty else {
      return false
    }
    if feed.contains("OWNER") || pubKey.contains("REPLACE") {
      return false
    }
    return true
  }
}
