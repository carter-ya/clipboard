import XCTest

@testable import ClipboardCore

final class PreferencesStoreTests: XCTestCase {
  private func makeIsolated() -> (PreferencesStore, UserDefaults) {
    let suite = UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    return (PreferencesStore(defaults: defaults), defaults)
  }

  func testDefaultsWhenNothingSaved() {
    let (store, _) = makeIsolated()
    let prefs = store.current
    XCTAssertEqual(prefs.maxClipSizeBytes, 10 * 1024 * 1024)
    XCTAssertTrue(prefs.skipSensitive)
    XCTAssertEqual(prefs.cap, 100)
    XCTAssertTrue(prefs.blockedBundleIDs.contains("com.1password.1password"))
    XCTAssertFalse(prefs.launchAtLogin)
    XCTAssertNil(prefs.languageOverride)
  }

  func testLanguageOverrideRoundTrip() {
    let (store, _) = makeIsolated()
    var prefs = store.current
    prefs.languageOverride = "ja"
    store.save(prefs)
    XCTAssertEqual(store.current.languageOverride, "ja")
    prefs.languageOverride = nil
    store.save(prefs)
    XCTAssertNil(store.current.languageOverride)
  }

  func testRoundTripSaveLoad() {
    let (store, _) = makeIsolated()
    var prefs = store.current
    prefs.maxClipSizeBytes = 5 * 1024 * 1024
    prefs.skipSensitive = false
    prefs.cap = 42
    prefs.blockedBundleIDs = ["com.test.app"]
    prefs.launchAtLogin = true
    store.save(prefs)

    let reloaded = store.current
    XCTAssertEqual(reloaded.maxClipSizeBytes, 5 * 1024 * 1024)
    XCTAssertEqual(reloaded.skipSensitive, false)
    XCTAssertEqual(reloaded.cap, 42)
    XCTAssertEqual(reloaded.blockedBundleIDs, ["com.test.app"])
    XCTAssertTrue(reloaded.launchAtLogin)
  }

  func testResetFallsBackToDefaults() {
    let (store, _) = makeIsolated()
    var prefs = store.current
    prefs.cap = 5
    store.save(prefs)
    XCTAssertEqual(store.current.cap, 5)
    store.reset()
    XCTAssertEqual(store.current.cap, 100)
  }
}
