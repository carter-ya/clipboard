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
    XCTAssertTrue(prefs.blocklistEnabled)
    XCTAssertTrue(prefs.blockedBundleIDs.contains("com.1password.1password"))
    XCTAssertFalse(prefs.launchAtLogin)
    XCTAssertNil(prefs.languageOverride)
    XCTAssertTrue(prefs.summariesEnabled)
    XCTAssertTrue(prefs.allowImageSummaries)
    XCTAssertTrue(prefs.allowTextSummaries)
    XCTAssertTrue(prefs.allowFileSummaries)
    XCTAssertFalse(prefs.remoteAIEnabled)
    XCTAssertNil(prefs.remoteAIBaseURL)
    XCTAssertNil(prefs.remoteAIModel)
    XCTAssertFalse(prefs.remoteAIAllowImages)
    XCTAssertEqual(prefs.remoteAITimeoutSeconds, 60)
    XCTAssertEqual(prefs.remoteAIMaxImageBytes, 2 * 1024 * 1024)
  }

  func testRemoteAIRoundTrip() {
    let (store, _) = makeIsolated()
    var prefs = store.current
    prefs.remoteAIEnabled = true
    prefs.remoteAIBaseURL = "https://api.openai.com/v1"
    prefs.remoteAIModel = "gpt-4o-mini"
    prefs.remoteAIAllowImages = true
    prefs.remoteAITimeoutSeconds = 45
    prefs.remoteAIMaxImageBytes = 1_048_576
    store.save(prefs)

    let reloaded = store.current
    XCTAssertTrue(reloaded.remoteAIEnabled)
    XCTAssertEqual(reloaded.remoteAIBaseURL, "https://api.openai.com/v1")
    XCTAssertEqual(reloaded.remoteAIModel, "gpt-4o-mini")
    XCTAssertTrue(reloaded.remoteAIAllowImages)
    XCTAssertEqual(reloaded.remoteAITimeoutSeconds, 45)
    XCTAssertEqual(reloaded.remoteAIMaxImageBytes, 1_048_576)

    var cleared = reloaded
    cleared.remoteAIBaseURL = nil
    cleared.remoteAIModel = nil
    store.save(cleared)
    XCTAssertNil(store.current.remoteAIBaseURL)
    XCTAssertNil(store.current.remoteAIModel)
  }

  func testRemoteAIInvalidBaseURLDroppedOnSave() {
    let (store, _) = makeIsolated()
    var prefs = store.current
    prefs.remoteAIBaseURL = "ssh://nope.example.com"
    store.save(prefs)
    XCTAssertNil(store.current.remoteAIBaseURL)
  }

  func testRemoteAIReset() {
    let (store, _) = makeIsolated()
    var prefs = store.current
    prefs.remoteAIEnabled = true
    prefs.remoteAIBaseURL = "https://api.openai.com/v1"
    prefs.remoteAIModel = "gpt-4o-mini"
    prefs.remoteAIAllowImages = true
    prefs.remoteAITimeoutSeconds = 45
    prefs.remoteAIMaxImageBytes = 1_048_576
    store.save(prefs)

    store.reset()
    let afterReset = store.current
    XCTAssertFalse(afterReset.remoteAIEnabled)
    XCTAssertNil(afterReset.remoteAIBaseURL)
    XCTAssertNil(afterReset.remoteAIModel)
    XCTAssertFalse(afterReset.remoteAIAllowImages)
    XCTAssertEqual(afterReset.remoteAITimeoutSeconds, 60)
    XCTAssertEqual(afterReset.remoteAIMaxImageBytes, 2 * 1024 * 1024)
  }

  /// S63: the four summary toggles should persist through a save/load
  /// cycle and come back to their defaults after reset().
  func testSummaryTogglesRoundTrip() {
    let (store, _) = makeIsolated()
    var prefs = store.current
    prefs.summariesEnabled = false
    prefs.allowImageSummaries = false
    prefs.allowTextSummaries = false
    prefs.allowFileSummaries = false
    store.save(prefs)

    let reloaded = store.current
    XCTAssertFalse(reloaded.summariesEnabled)
    XCTAssertFalse(reloaded.allowImageSummaries)
    XCTAssertFalse(reloaded.allowTextSummaries)
    XCTAssertFalse(reloaded.allowFileSummaries)

    store.reset()
    let afterReset = store.current
    XCTAssertTrue(afterReset.summariesEnabled)
    XCTAssertTrue(afterReset.allowImageSummaries)
    XCTAssertTrue(afterReset.allowTextSummaries)
    XCTAssertTrue(afterReset.allowFileSummaries)
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
    prefs.blocklistEnabled = false
    prefs.blockedBundleIDs = ["com.test.app"]
    prefs.launchAtLogin = true
    store.save(prefs)

    let reloaded = store.current
    XCTAssertEqual(reloaded.maxClipSizeBytes, 5 * 1024 * 1024)
    XCTAssertEqual(reloaded.skipSensitive, false)
    XCTAssertEqual(reloaded.cap, 42)
    XCTAssertFalse(reloaded.blocklistEnabled)
    XCTAssertEqual(reloaded.blockedBundleIDs, ["com.test.app"])
    XCTAssertTrue(reloaded.launchAtLogin)

    store.reset()
    XCTAssertTrue(store.current.blocklistEnabled)
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
