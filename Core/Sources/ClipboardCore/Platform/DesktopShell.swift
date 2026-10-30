import Foundation

public struct DesktopShortcut: Codable, Equatable, Sendable {
  public struct Modifiers: OptionSet, Codable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let control = Self(rawValue: 1)
    public static let alt = Self(rawValue: 2)
    public static let shift = Self(rawValue: 4)
    public static let superKey = Self(rawValue: 8)
  }

  public enum ValidationError: Error { case invalidShortcut }
  public let key: String
  public let modifiers: Modifiers

  public init(key: String, modifiers: Modifiers) throws {
    let normalized = key.uppercased()
    let letter =
      normalized.utf8.count == 1
      && normalized.utf8.allSatisfy {
        (65...90).contains($0) || (48...57).contains($0)
      }
    let function =
      normalized.first == "F"
      && Int(normalized.dropFirst()).map {
        (1...24).contains($0)
      } == true
    guard letter || function || normalized == "SPACE",
      !modifiers.intersection([.control, .alt, .superKey]).isEmpty,
      modifiers.rawValue & ~UInt32(15) == 0
    else { throw ValidationError.invalidShortcut }
    self.key = normalized
    self.modifiers = modifiers
  }

  public init(parsing text: String) throws {
    let components = text.split(separator: "+", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
    guard components.count > 1, let key = components.last else {
      throw ValidationError.invalidShortcut
    }
    var modifiers: Modifiers = []
    for value in components.dropLast() {
      let modifier: Modifiers
      switch value {
      case "CTRL", "CONTROL": modifier = .control
      case "ALT": modifier = .alt
      case "SHIFT": modifier = .shift
      case "SUPER", "WIN", "META": modifier = .superKey
      default: throw ValidationError.invalidShortcut
      }
      guard !modifiers.contains(modifier) else { throw ValidationError.invalidShortcut }
      modifiers.insert(modifier)
    }
    try self.init(key: key, modifiers: modifiers)
  }

  private enum CodingKeys: String, CodingKey { case key, modifiers }
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      key: values.decode(String.self, forKey: .key),
      modifiers: values.decode(Modifiers.self, forKey: .modifiers))
  }

  public var displayName: String {
    var parts: [String] = []
    if modifiers.contains(.control) { parts.append("Ctrl") }
    if modifiers.contains(.alt) { parts.append("Alt") }
    if modifiers.contains(.shift) { parts.append("Shift") }
    if modifiers.contains(.superKey) { parts.append("Super") }
    return (parts + [key == "SPACE" ? "Space" : key]).joined(separator: "+")
  }
}

public enum DesktopShellAction: Int32, Sendable {
  case toggleHistory = 1
  case showHistory = 2
  case showPreferences = 3
  case toggleRecording = 4
  case quit = 5
  case capabilitiesChanged = 6
}

public enum DesktopShortcutPortalStatus: UInt32, Sendable {
  case notApplicable = 0
  case pending, permissionRequired, active, denied, unavailable
}

public struct DesktopShellCapabilities: Sendable, Equatable {
  public let tray: Bool
  public let globalShortcut: Bool
  public let shortcutPortal: DesktopShortcutPortalStatus
  public init(
    tray: Bool, globalShortcut: Bool, shortcutPortal: DesktopShortcutPortalStatus = .notApplicable
  ) {
    self.tray = tray
    self.globalShortcut = globalShortcut
    self.shortcutPortal = shortcutPortal
  }
}

public enum DesktopShellError: Error { case unavailable, shortcutConflict, invalidShortcut }

/// Owns native event sources. It never synthesizes input or writes the clipboard.
public protocol DesktopShellAccess: AnyObject, Sendable {
  var actions: AsyncStream<DesktopShellAction> { get }
  var capabilities: DesktopShellCapabilities { get }
  var activationTimestamp: UInt32 { get }
  func start(shortcut: DesktopShortcut?, recording: Bool) throws
  func requestShortcutPermission()
  func takeActivationToken() -> String?
  func updateLanguage(_ tag: String)
  func updateRecording(_ enabled: Bool)
  func stop()
}

extension DesktopShellAccess {
  public var activationTimestamp: UInt32 { 0 }
  public func requestShortcutPermission() {}
  public func takeActivationToken() -> String? { nil }
}

public final class FakeDesktopShell: DesktopShellAccess, @unchecked Sendable {
  public let actions: AsyncStream<DesktopShellAction>
  private let continuation: AsyncStream<DesktopShellAction>.Continuation
  private let lock = NSLock()
  private var running = false
  private var recording = false
  private var shortcutEnabled = false
  public var capabilities: DesktopShellCapabilities {
    lock.withLock { .init(tray: running, globalShortcut: running && shortcutEnabled) }
  }
  public init() { (actions, continuation) = AsyncStream.makeStream() }
  public func start(shortcut: DesktopShortcut?, recording: Bool) throws {
    lock.withLock {
      running = true
      shortcutEnabled = shortcut != nil
      self.recording = recording
    }
  }
  public func updateLanguage(_ tag: String) {}
  public func updateRecording(_ enabled: Bool) { lock.withLock { recording = enabled } }
  public func stop() { lock.withLock { running = false } }
  public func send(_ action: DesktopShellAction) {
    if lock.withLock({ running }) { continuation.yield(action) }
  }
  deinit { continuation.finish() }
}

@MainActor public protocol DesktopWindowControlling: AnyObject {
  var isVisible: Bool { get }
  func present()
  func hide()
  func focusSearch()
}

@MainActor public final class DesktopWindowCoordinator {
  public enum Page { case history, preferences }
  public private(set) var page: Page = .history
  private let window: any DesktopWindowControlling
  public init(window: any DesktopWindowControlling) { self.window = window }
  public func showHistory() {
    page = .history
    window.present()
    window.focusSearch()
  }
  public func showPreferences() {
    page = .preferences
    window.present()
  }
  public func toggleHistory() {
    if window.isVisible && page == .history { window.hide() } else { showHistory() }
  }
  public func hide() { window.hide() }
}

@MainActor public final class FakeDesktopWindow: DesktopWindowControlling {
  public private(set) var isVisible = false
  public private(set) var focusRequests = 0
  public init() {}
  public func present() { isVisible = true }
  public func hide() { isVisible = false }
  public func focusSearch() { if isVisible { focusRequests += 1 } }
}
