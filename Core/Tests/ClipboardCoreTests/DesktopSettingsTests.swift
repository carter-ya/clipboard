import XCTest

@testable import ClipboardCore

final class DesktopSettingsTests: XCTestCase {
  func testFreshDesktopStartsPausedAndPartialUpgradeRetainsPrivacyDefaults() throws {
    let defaults = DesktopSettings()
    XCTAssertFalse(defaults.recordingEnabled)
    XCTAssertTrue(defaults.skipSensitive)
    let upgraded = try JSONDecoder().decode(
      DesktopSettings.self, from: Data(#"{"shortcut":"Ctrl+F8"}"#.utf8))
    XCTAssertFalse(upgraded.recordingEnabled)
    XCTAssertTrue(upgraded.skipSensitive)
    XCTAssertEqual(upgraded.shortcut, "Ctrl+F8")
  }
  func testSettingsRoundTripAndInvalidSaveKeepsPreviousFile() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "desktop settings 中文 \(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = JSONDesktopSettingsStore(root: root)
    var settings = DesktopSettings()
    settings.recordingEnabled = true
    settings.shortcut = "Ctrl+Alt+F9"
    try await store.save(settings)
    let reopened = JSONDesktopSettingsStore(root: root)
    let restored = try await reopened.load()
    XCTAssertEqual(restored, settings)
    var invalid = settings
    invalid.shortcut = "Shift+V"
    do {
      try await store.save(invalid)
      XCTFail("Invalid shortcut was accepted")
    } catch {}
    let preserved = try await reopened.load()
    XCTAssertEqual(preserved, settings)
    let file = try String(
      contentsOf: root.appendingPathComponent("desktop-settings.json"), encoding: .utf8)
    XCTAssertFalse(file.lowercased().contains("apikey"))
  }
  func testMalformedStoredSettingsDoNotEnableRecording() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data(#"{"recordingEnabled":true,"historyCapacity":-1}"#.utf8)
      .write(to: root.appendingPathComponent("desktop-settings.json"))
    do {
      _ = try await JSONDesktopSettingsStore(root: root).load()
      XCTFail("Corrupt settings were accepted")
    } catch {}
  }
}
