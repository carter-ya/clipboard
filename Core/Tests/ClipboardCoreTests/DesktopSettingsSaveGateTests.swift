import XCTest

@testable import ClipboardCore

final class DesktopSettingsSaveGateTests: XCTestCase {
  @MainActor func testQueuedPresentationSavesPreserveTheLatestAIOptOut() async throws {
    let gate = DesktopSettingsSaveGate()
    let store = InMemoryDesktopSettingsStore()
    var live = DesktopSettings()
    live.ai.enabled = true
    live.ai.model = "fixture-model"
    live.automaticSummaries = true
    let waiting = expectation(description: "both presentation actions submitted")
    waiting.expectedFulfillmentCount = 2
    var presentationWrites = 0

    // Hold an AI settings save across the await, as a slow disk write would.
    await gate.acquire()
    var optOut = live
    optOut.ai.enabled = false
    optOut.automaticSummaries = false
    let appearance = Task { @MainActor in
      waiting.fulfill()
      await gate.acquire()
      defer { gate.release() }
      var next = live
      next.appearance = "light"
      try await store.save(next)
      live = next
      presentationWrites += 1
    }
    let language = Task { @MainActor in
      waiting.fulfill()
      await gate.acquire()
      defer { gate.release() }
      var next = live
      next.languageOverride = "zh-Hans"
      try await store.save(next)
      live = next
      presentationWrites += 1
    }
    await fulfillment(of: [waiting], timeout: 3)
    XCTAssertEqual(presentationWrites, 0)
    try await store.save(optOut)
    live = optOut
    gate.release()
    try await appearance.value
    try await language.value
    let saved = await store.load()
    XCTAssertEqual(presentationWrites, 2, "Accepted clicks must wait rather than disappear")
    XCTAssertFalse(saved.ai.enabled)
    XCTAssertFalse(saved.automaticSummaries)
    XCTAssertEqual(saved.appearance, "light")
    XCTAssertEqual(saved.languageOverride, "zh-Hans")
    XCTAssertEqual(saved, live)
  }
}
