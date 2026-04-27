import Foundation

public struct Preferences: Sendable, Equatable {
  public var maxClipSizeBytes: Int
  public var skipSensitive: Bool
  public var cap: Int
  public var blocklistEnabled: Bool
  public var blockedBundleIDs: [String]
  public var launchAtLogin: Bool
  /// nil = follow system; otherwise an Apple-recognised language
  /// code matching one of the shipped `.lproj` folders.
  public var languageOverride: String?
  /// Master switch for the on-device AI summary pipeline. Individual
  /// `allow…Summaries` toggles below act as sub-filters when this is
  /// true; all summarization is off when this is false.
  public var summariesEnabled: Bool
  public var allowImageSummaries: Bool
  public var allowTextSummaries: Bool
  public var allowFileSummaries: Bool
  public var remoteAIEnabled: Bool
  public var remoteAIBaseURL: String?
  public var remoteAIModel: String?
  public var remoteAIAllowImages: Bool
  public var remoteAITimeoutSeconds: Int
  public var remoteAIMaxImageBytes: Int

  public init(
    maxClipSizeBytes: Int = 10 * 1024 * 1024,
    skipSensitive: Bool = true,
    cap: Int = 100,
    blocklistEnabled: Bool = true,
    blockedBundleIDs: [String] = Array(BlocklistFilter.defaults).sorted(),
    launchAtLogin: Bool = false,
    languageOverride: String? = nil,
    summariesEnabled: Bool = true,
    allowImageSummaries: Bool = true,
    allowTextSummaries: Bool = true,
    allowFileSummaries: Bool = true,
    remoteAIEnabled: Bool = false,
    remoteAIBaseURL: String? = nil,
    remoteAIModel: String? = nil,
    remoteAIAllowImages: Bool = false,
    remoteAITimeoutSeconds: Int = 60,
    remoteAIMaxImageBytes: Int = 2 * 1024 * 1024
  ) {
    self.maxClipSizeBytes = maxClipSizeBytes
    self.skipSensitive = skipSensitive
    self.cap = cap
    self.blocklistEnabled = blocklistEnabled
    self.blockedBundleIDs = blockedBundleIDs
    self.launchAtLogin = launchAtLogin
    self.languageOverride = languageOverride
    self.summariesEnabled = summariesEnabled
    self.allowImageSummaries = allowImageSummaries
    self.allowTextSummaries = allowTextSummaries
    self.allowFileSummaries = allowFileSummaries
    self.remoteAIEnabled = remoteAIEnabled
    self.remoteAIBaseURL = remoteAIBaseURL
    self.remoteAIModel = remoteAIModel
    self.remoteAIAllowImages = remoteAIAllowImages
    self.remoteAITimeoutSeconds = remoteAITimeoutSeconds
    self.remoteAIMaxImageBytes = remoteAIMaxImageBytes
  }
}

public final class PreferencesStore: @unchecked Sendable {
  public static let shared = PreferencesStore()

  private let defaults: UserDefaults
  private enum Keys {
    static let maxClipSizeBytes = "maxClipSizeBytes"
    static let skipSensitive = "skipSensitive"
    static let cap = "cap"
    static let blocklistEnabled = "blocklistEnabled"
    static let blockedBundleIDs = "blockedBundleIDs"
    static let launchAtLogin = "launchAtLogin"
    static let languageOverride = "languageOverride"
    static let summariesEnabled = "summariesEnabled"
    static let allowImageSummaries = "allowImageSummaries"
    static let allowTextSummaries = "allowTextSummaries"
    static let allowFileSummaries = "allowFileSummaries"
    static let remoteAIEnabled = "remoteAIEnabled"
    static let remoteAIBaseURL = "remoteAIBaseURL"
    static let remoteAIModel = "remoteAIModel"
    static let remoteAIAllowImages = "remoteAIAllowImages"
    static let remoteAITimeoutSeconds = "remoteAITimeoutSeconds"
    static let remoteAIMaxImageBytes = "remoteAIMaxImageBytes"
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
      blocklistEnabled: defaults.object(forKey: Keys.blocklistEnabled) as? Bool
        ?? defaultsValue.blocklistEnabled,
      blockedBundleIDs: defaults.stringArray(forKey: Keys.blockedBundleIDs)
        ?? defaultsValue.blockedBundleIDs,
      launchAtLogin: defaults.object(forKey: Keys.launchAtLogin) as? Bool
        ?? defaultsValue.launchAtLogin,
      languageOverride: defaults.string(forKey: Keys.languageOverride),
      summariesEnabled: defaults.object(forKey: Keys.summariesEnabled) as? Bool
        ?? defaultsValue.summariesEnabled,
      allowImageSummaries: defaults.object(forKey: Keys.allowImageSummaries) as? Bool
        ?? defaultsValue.allowImageSummaries,
      allowTextSummaries: defaults.object(forKey: Keys.allowTextSummaries) as? Bool
        ?? defaultsValue.allowTextSummaries,
      allowFileSummaries: defaults.object(forKey: Keys.allowFileSummaries) as? Bool
        ?? defaultsValue.allowFileSummaries,
      remoteAIEnabled: defaults.object(forKey: Keys.remoteAIEnabled) as? Bool
        ?? defaultsValue.remoteAIEnabled,
      remoteAIBaseURL: defaults.string(forKey: Keys.remoteAIBaseURL),
      remoteAIModel: defaults.string(forKey: Keys.remoteAIModel),
      remoteAIAllowImages: defaults.object(forKey: Keys.remoteAIAllowImages) as? Bool
        ?? defaultsValue.remoteAIAllowImages,
      // Treat the legacy default (20s) as "unset" — reasoning models
      // routinely need 30-50s for one summary, and 20s was hit by
      // anyone who configured Remote AI before this bump. Saved
      // values other than 20 are honoured as deliberate user choices.
      remoteAITimeoutSeconds: {
        let saved = defaults.object(forKey: Keys.remoteAITimeoutSeconds) as? Int
        if let saved, saved != 20 { return saved }
        return defaultsValue.remoteAITimeoutSeconds
      }(),
      remoteAIMaxImageBytes: defaults.object(forKey: Keys.remoteAIMaxImageBytes) as? Int
        ?? defaultsValue.remoteAIMaxImageBytes
    )
  }

  public func save(_ prefs: Preferences) {
    defaults.set(prefs.maxClipSizeBytes, forKey: Keys.maxClipSizeBytes)
    defaults.set(prefs.skipSensitive, forKey: Keys.skipSensitive)
    defaults.set(prefs.cap, forKey: Keys.cap)
    defaults.set(prefs.blocklistEnabled, forKey: Keys.blocklistEnabled)
    defaults.set(prefs.blockedBundleIDs, forKey: Keys.blockedBundleIDs)
    defaults.set(prefs.launchAtLogin, forKey: Keys.launchAtLogin)
    if let lang = prefs.languageOverride {
      defaults.set(lang, forKey: Keys.languageOverride)
    } else {
      defaults.removeObject(forKey: Keys.languageOverride)
    }
    defaults.set(prefs.summariesEnabled, forKey: Keys.summariesEnabled)
    defaults.set(prefs.allowImageSummaries, forKey: Keys.allowImageSummaries)
    defaults.set(prefs.allowTextSummaries, forKey: Keys.allowTextSummaries)
    defaults.set(prefs.allowFileSummaries, forKey: Keys.allowFileSummaries)
    defaults.set(prefs.remoteAIEnabled, forKey: Keys.remoteAIEnabled)
    if let raw = prefs.remoteAIBaseURL,
      let url = validateRemoteAIBaseURL(raw)
    {
      defaults.set(url.absoluteString, forKey: Keys.remoteAIBaseURL)
    } else {
      defaults.removeObject(forKey: Keys.remoteAIBaseURL)
    }
    if let model = prefs.remoteAIModel {
      defaults.set(model, forKey: Keys.remoteAIModel)
    } else {
      defaults.removeObject(forKey: Keys.remoteAIModel)
    }
    defaults.set(prefs.remoteAIAllowImages, forKey: Keys.remoteAIAllowImages)
    defaults.set(prefs.remoteAITimeoutSeconds, forKey: Keys.remoteAITimeoutSeconds)
    defaults.set(prefs.remoteAIMaxImageBytes, forKey: Keys.remoteAIMaxImageBytes)
  }

  public func reset() {
    defaults.removeObject(forKey: Keys.maxClipSizeBytes)
    defaults.removeObject(forKey: Keys.skipSensitive)
    defaults.removeObject(forKey: Keys.cap)
    defaults.removeObject(forKey: Keys.blocklistEnabled)
    defaults.removeObject(forKey: Keys.blockedBundleIDs)
    defaults.removeObject(forKey: Keys.launchAtLogin)
    defaults.removeObject(forKey: Keys.languageOverride)
    defaults.removeObject(forKey: Keys.summariesEnabled)
    defaults.removeObject(forKey: Keys.allowImageSummaries)
    defaults.removeObject(forKey: Keys.allowTextSummaries)
    defaults.removeObject(forKey: Keys.allowFileSummaries)
    defaults.removeObject(forKey: Keys.remoteAIEnabled)
    defaults.removeObject(forKey: Keys.remoteAIBaseURL)
    defaults.removeObject(forKey: Keys.remoteAIModel)
    defaults.removeObject(forKey: Keys.remoteAIAllowImages)
    defaults.removeObject(forKey: Keys.remoteAITimeoutSeconds)
    defaults.removeObject(forKey: Keys.remoteAIMaxImageBytes)
  }
}
