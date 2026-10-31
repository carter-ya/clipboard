import XCTest

@testable import ClipboardCore

final class DesktopLocalImagePolicyTests: XCTestCase {
  private func image() -> ClipItem {
    .init(
      createdAt: Date(), kind: .image, preview: "Synthetic image", sha256: "fixture", sizeBytes: 1)
  }
  func testLegacyOCRSettingsDoNotEnableAutomaticImageLabels() throws {
    var settings = DesktopSettings()
    settings.automaticOCR = true
    let restored = try JSONDecoder().decode(
      DesktopSettings.self, from: Data("{\"automaticOCR\":true}".utf8))
    XCTAssertTrue(restored.automaticOCR)
    XCTAssertFalse(restored.automaticLocalImageSummaries)
    settings.automaticLocalImageSummaries = true
    let current = try JSONDecoder().decode(
      DesktopSettings.self, from: JSONEncoder().encode(settings))
    XCTAssertEqual(settings, current)
    XCTAssertFalse(current.ai.enabled)
    XCTAssertFalse(current.ai.allowImages)
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        DesktopSettings.self,
        from: Data("{\"automaticLocalImageSummaries\":\"true\"}".utf8)))
  }
  func testAutomaticImageLabelsNeedBothOptInsWhileExplicitManualAnalysisStaysIndependent() {
    let item = image()
    let automatic = DesktopAnalysisScheduler.Request(
      id: item.id, remote: false, automatic: true, imageSummary: true)
    let manual = DesktopAnalysisScheduler.Request(
      id: item.id, remote: false, automatic: false, imageSummary: true)
    var settings = DesktopSettings()
    XCTAssertFalse(automatic.isAllowed(item: item, settings: settings))
    XCTAssertTrue(manual.isAllowed(item: item, settings: settings))
    settings.automaticOCR = true
    XCTAssertFalse(automatic.isAllowed(item: item, settings: settings))
    settings.automaticLocalImageSummaries = true
    XCTAssertTrue(automatic.isAllowed(item: item, settings: settings))
    settings.automaticOCR = false
    XCTAssertFalse(automatic.isAllowed(item: item, settings: settings))
    XCTAssertFalse(
      DesktopAnalysisScheduler.Request(
        id: item.id, remote: true, automatic: false, imageSummary: true
      )
      .isAllowed(item: item, settings: settings))
    var sensitive = item
    sensitive.sensitive = true
    XCTAssertFalse(manual.isAllowed(item: sensitive, settings: settings))
    var text = item
    text.kind = .text
    XCTAssertFalse(manual.isAllowed(item: text, settings: settings))
  }
  @MainActor func testImageRetryPreservesItsModeAndRejectsPriorOutcomes() throws {
    var states: [UUID: DesktopItemAnalysisProgress] = [:]
    let state = DesktopAnalysisProgressState { states = $0 }
    let id = UUID()
    XCTAssertNil(state.begin(id: id, remote: true, imageSummary: true))
    let first = try XCTUnwrap(state.begin(id: id, remote: false, imageSummary: true))
    XCTAssertEqual(states[id], .running(remote: false, imageSummary: true))
    XCTAssertNil(state.begin(id: id, remote: false))
    state.finish(first, succeeded: false)
    XCTAssertEqual(states[id], .failed(remote: false, imageSummary: true))
    let retry = try XCTUnwrap(state.begin(id: id, remote: false, imageSummary: true))
    state.finish(first, succeeded: true)
    XCTAssertEqual(states[id], .running(remote: false, imageSummary: true))
    state.finish(retry, succeeded: true)
    XCTAssertTrue(states.isEmpty)
  }
  @MainActor func testRevokingOnlyImageLabelsCancelsAnActiveAutomaticRequest() async {
    let started = expectation(description: "image request waiting")
    let done = expectation(description: "cancelled image work drained")
    var release: CheckedContinuation<Void, Never>?
    let item = image()
    var settings = DesktopSettings()
    settings.automaticOCR = true
    settings.automaticLocalImageSummaries = true
    let scheduler = DesktopAnalysisScheduler { _ in
      await withCheckedContinuation {
        release = $0
        started.fulfill()
      }
      XCTAssertTrue(Task.isCancelled)
      done.fulfill()
    }
    scheduler.submit(.init(id: item.id, remote: false, automatic: true, imageSummary: true))
    await fulfillment(of: [started], timeout: 3)
    settings.automaticLocalImageSummaries = false
    XCTAssertTrue(settings.automaticOCR)
    XCTAssertTrue(scheduler.recheckCurrent(id: item.id, item: item, settings: settings))
    release?.resume()
    await fulfillment(of: [done], timeout: 3)
  }
}
