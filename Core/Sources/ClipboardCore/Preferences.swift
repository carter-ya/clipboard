import Foundation

public struct Preferences: Sendable, Equatable {
  public var maxClipSizeBytes: Int
  public var skipSensitive: Bool
  public var cap: Int
  public var blockedBundleIDs: [String]
  public var launchAtLogin: Bool
  /// nil = follow system; otherwise an Apple-recognised language
  /// code matching one of the shipped `.lproj` folders.
  public var languageOverride: String?

  public init(
    maxClipSizeBytes: Int = 10 * 1024 * 1024,
    skipSensitive: Bool = true,
    cap: Int = 100,
    blockedBundleIDs: [String] = Array(BlocklistFilter.defaults).sorted(),
    launchAtLogin: Bool = false,
    languageOverride: String? = nil
  ) {
    self.maxClipSizeBytes = maxClipSizeBytes
    self.skipSensitive = skipSensitive
    self.cap = cap
    self.blockedBundleIDs = blockedBundleIDs
    self.launchAtLogin = launchAtLogin
    self.languageOverride = languageOverride
  }
}

public final class PreferencesStore: @unchecked Sendable {
  public static let shared = PreferencesStore()

  private let defaults: UserDefaults
  private enum Keys {
    static let maxClipSizeBytes = "maxClipSizeBytes"
    static let skipSensitive = "skipSensitive"
    static let cap = "cap"
    static let blockedBundleIDs = "blockedBundleIDs"
    static let launchAtLogin = "launchAtLogin"
    static let languageOverride = "languageOverride"
  }

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public var current: Preferences {
    let defaultsValue = Preferences()
    return Preferences(
      maxClipSizeBytes: defaults.object(forKey: Keys.maxClipSizeBytes) as? Int
        ?? defaultsValue.maxClipSizeBytes,
      skipSensitive: defaults.object(forKey: Keys.skipSensitive) as? Bool
        ?? defaultsValue.skipSensitive,
      cap: defaults.object(forKey: Keys.cap) as? Int ?? defaultsValue.cap,
      blockedBundleIDs: defaults.stringArray(forKey: Keys.blockedBundleIDs)
        ?? defaultsValue.blockedBundleIDs,
      launchAtLogin: defaults.object(forKey: Keys.launchAtLogin) as? Bool
        ?? defaultsValue.launchAtLogin,
      languageOverride: defaults.string(forKey: Keys.languageOverride)
    )
  }

  public func save(_ prefs: Preferences) {
    defaults.set(prefs.maxClipSizeBytes, forKey: Keys.maxClipSizeBytes)
    defaults.set(prefs.skipSensitive, forKey: Keys.skipSensitive)
    defaults.set(prefs.cap, forKey: Keys.cap)
    defaults.set(prefs.blockedBundleIDs, forKey: Keys.blockedBundleIDs)
    defaults.set(prefs.launchAtLogin, forKey: Keys.launchAtLogin)
    if let lang = prefs.languageOverride {
      defaults.set(lang, forKey: Keys.languageOverride)
    } else {
      defaults.removeObject(forKey: Keys.languageOverride)
    }
  }

  public func reset() {
    defaults.removeObject(forKey: Keys.maxClipSizeBytes)
    defaults.removeObject(forKey: Keys.skipSensitive)
    defaults.removeObject(forKey: Keys.cap)
    defaults.removeObject(forKey: Keys.blockedBundleIDs)
    defaults.removeObject(forKey: Keys.launchAtLogin)
    defaults.removeObject(forKey: Keys.languageOverride)
  }
}
