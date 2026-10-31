import Foundation

/// Desktop behavior only. API credentials never enter this file-backed model.
public struct DesktopSettings: Codable, Equatable, Sendable {
  public var recordingEnabled = false
  public var shortcutEnabled = true
  public var shortcut = "Ctrl+Alt+V"
  public var closeToTray = true
  public var showOnLaunch = true
  public var historyCapacity = 100
  public var maxClipSizeBytes = 10 * 1024 * 1024
  public var skipSensitive = true
  public var blocklistEnabled = true
  public var blockedAppIDs = Array(BlocklistFilter.defaults).sorted()
  public var appearance = "system"
  public var languageOverride: String?
  public init() {}

  private enum CodingKeys: String, CodingKey {
    case recordingEnabled, shortcutEnabled, shortcut, closeToTray, showOnLaunch
    case historyCapacity, maxClipSizeBytes, skipSensitive, blocklistEnabled, blockedAppIDs
    case appearance, languageOverride
  }
  public init(from decoder: any Decoder) throws {
    self.init()
    let values = try decoder.container(keyedBy: CodingKeys.self)
    recordingEnabled =
      try values.decodeIfPresent(Bool.self, forKey: .recordingEnabled) ?? recordingEnabled
    shortcutEnabled =
      try values.decodeIfPresent(Bool.self, forKey: .shortcutEnabled) ?? shortcutEnabled
    shortcut = try values.decodeIfPresent(String.self, forKey: .shortcut) ?? shortcut
    closeToTray = try values.decodeIfPresent(Bool.self, forKey: .closeToTray) ?? closeToTray
    showOnLaunch = try values.decodeIfPresent(Bool.self, forKey: .showOnLaunch) ?? showOnLaunch
    historyCapacity =
      try values.decodeIfPresent(Int.self, forKey: .historyCapacity) ?? historyCapacity
    maxClipSizeBytes =
      try values.decodeIfPresent(Int.self, forKey: .maxClipSizeBytes) ?? maxClipSizeBytes
    skipSensitive = try values.decodeIfPresent(Bool.self, forKey: .skipSensitive) ?? skipSensitive
    blocklistEnabled =
      try values.decodeIfPresent(Bool.self, forKey: .blocklistEnabled) ?? blocklistEnabled
    blockedAppIDs =
      try values.decodeIfPresent([String].self, forKey: .blockedAppIDs) ?? blockedAppIDs
    appearance = try values.decodeIfPresent(String.self, forKey: .appearance) ?? appearance
    languageOverride = try values.decodeIfPresent(String.self, forKey: .languageOverride)
    try validate()
  }

  public enum ValidationError: Error { case invalidValue }
  public func validate() throws {
    guard (1...5000).contains(historyCapacity),
      (1...(16 * 1024 * 1024)).contains(maxClipSizeBytes),
      ["system", "light", "dark"].contains(appearance)
    else { throw ValidationError.invalidValue }
    if shortcutEnabled { _ = try DesktopShortcut(parsing: shortcut) }
  }
}

public protocol DesktopSettingsPersisting: AnyObject, Sendable {
  func load() async throws -> DesktopSettings
  func save(_ settings: DesktopSettings) async throws
}

public actor JSONDesktopSettingsStore: DesktopSettingsPersisting {
  private let root: URL
  private let file: URL
  public init(root: URL) {
    self.root = root
    self.file = root.appendingPathComponent("desktop-settings.json")
  }
  public func load() throws -> DesktopSettings {
    guard FileManager.default.fileExists(atPath: file.path) else { return DesktopSettings() }
    return try JSONDecoder().decode(DesktopSettings.self, from: Data(contentsOf: file))
  }
  public func save(_ settings: DesktopSettings) throws {
    try settings.validate()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(settings)
    try data.write(to: file, options: .atomic)
  }
}

public actor InMemoryDesktopSettingsStore: DesktopSettingsPersisting {
  private var value = DesktopSettings()
  public init() {}
  public func load() -> DesktopSettings { value }
  public func save(_ settings: DesktopSettings) throws {
    try settings.validate()
    value = settings
  }
}
