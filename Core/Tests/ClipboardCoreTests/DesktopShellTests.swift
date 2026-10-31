import XCTest

@testable import ClipboardCore

final class DesktopShellTests: XCTestCase {
  func testQueuedActivationsOwnTheirTokensAcrossUnrelatedEvents() async throws {
    let shell = FakeDesktopShell()
    try shell.start(shortcut: nil, recording: false)
    defer { shell.stop() }
    shell.send(.capabilitiesChanged)
    shell.send(.showHistory, activationToken: "first-private-fixture-token")
    shell.send(.showPreferences, activationToken: "discard-unrelated-token")
    shell.send(.toggleRecording)
    shell.send(.showHistory, activationToken: "second-private-fixture-token")
    var events = shell.actions.makeAsyncIterator()
    let capability = await events.next()
    let first = await events.next()
    let preferences = await events.next()
    let recording = await events.next()
    let second = await events.next()
    XCTAssertNil(capability?.activationToken)
    XCTAssertEqual(first?.activationToken, "first-private-fixture-token")
    XCTAssertNil(preferences?.activationToken)
    XCTAssertNil(recording?.activationToken)
    XCTAssertEqual(second?.activationToken, "second-private-fixture-token")
  }

  func testShortcutValidationAndCanonicalRoundTrip() throws {
    let shortcut = try DesktopShortcut(parsing: "control + alt + v")
    XCTAssertEqual(shortcut.displayName, "Ctrl+Alt+V")
    XCTAssertEqual(try DesktopShortcut(parsing: shortcut.displayName), shortcut)
    XCTAssertEqual(try DesktopShortcut(parsing: "Win+F12").key, "F12")
    for value in ["V", "Shift+V", "Ctrl+Ctrl+V", "Ctrl+", "Ctrl+F25", "Ctrl+AA", "Ctrl+Alt+V+Q"] {
      XCTAssertThrowsError(try DesktopShortcut(parsing: value), value)
    }
  }

  func testDecodedShortcutCannotBypassValidation() throws {
    let invalid = Data(#"{"key":"V","modifiers":{"rawValue":4}}"#.utf8)
    XCTAssertThrowsError(try JSONDecoder().decode(DesktopShortcut.self, from: invalid))
    let valid = try DesktopShortcut(parsing: "Ctrl+Alt+V")
    XCTAssertEqual(
      try JSONDecoder().decode(DesktopShortcut.self, from: JSONEncoder().encode(valid)), valid)
  }

  @MainActor func testHistoryToggleAndPreferencesHandoffKeepWindowStateConsistent() {
    let window = FakeDesktopWindow()
    let coordinator = DesktopWindowCoordinator(window: window)
    coordinator.toggleHistory()
    XCTAssertTrue(window.isVisible)
    XCTAssertEqual(window.focusRequests, 1)
    coordinator.toggleHistory()
    XCTAssertFalse(window.isVisible)
    XCTAssertEqual(window.focusRequests, 1)
    coordinator.showPreferences()
    XCTAssertEqual(coordinator.page, .preferences)
    XCTAssertTrue(window.isVisible)
    XCTAssertEqual(window.focusRequests, 1, "Preferences must not steal search focus")
    coordinator.toggleHistory()
    XCTAssertEqual(coordinator.page, .history)
    XCTAssertTrue(window.isVisible)
    XCTAssertEqual(window.focusRequests, 2)
    coordinator.hide()
    XCTAssertFalse(window.isVisible)
  }

  func testStoppedShellDoesNotDeliverNativeActions() async throws {
    let shell = FakeDesktopShell()
    try shell.start(shortcut: DesktopShortcut(parsing: "Ctrl+Alt+V"), recording: false)
    XCTAssertTrue(shell.capabilities.globalShortcut)
    shell.stop()
    XCTAssertFalse(shell.capabilities.tray)
    shell.send(.quit)
    try shell.start(shortcut: DesktopShortcut(parsing: "Ctrl+Alt+V"), recording: true)
    shell.send(.showHistory)
    var actions = shell.actions.makeAsyncIterator()
    let first = await actions.next()
    XCTAssertEqual(
      first?.action, .showHistory, "The action emitted while stopped must be discarded")
  }
}
