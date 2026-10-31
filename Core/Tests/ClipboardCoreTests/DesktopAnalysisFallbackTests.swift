import XCTest

@testable import ClipboardCore

final class DesktopAnalysisFallbackTests: XCTestCase {
  private func item(_ kind: ClipKind = .text) -> ClipItem {
    .init(createdAt: Date(), kind: kind, preview: "synthetic", sha256: "synthetic", sizeBytes: 0)
  }
  private func preferences() -> DesktopSettings {
    var value = DesktopSettings()
    value.ai.enabled = true
    value.ai.allowFiles = true
    value.ai.allowImages = true
    value.automaticSummaries = true
    return value
  }
  @MainActor func testFallbackRequiresEachManualAndAutomaticLocalPermission() async {
    for kind in ClipKind.allCases {
      let candidate = item(kind)
      let manual = DesktopAnalysisScheduler.Request(
        id: candidate.id, remote: true, automatic: false)
      let automatic = DesktopAnalysisScheduler.Request(
        id: candidate.id, remote: true, automatic: true)
      var settings = preferences()
      if kind != .image { XCTAssertNil(manual.localFallback(item: candidate, settings: settings)) }
      XCTAssertNil(automatic.localFallback(item: candidate, settings: settings))
      settings.localTextSummariesEnabled = true
      settings.localFileSummariesEnabled = true
      let local = manual.localFallback(item: candidate, settings: settings)
      XCTAssertEqual(local?.remote, false)
      XCTAssertEqual(local?.automatic, false)
      XCTAssertNil(automatic.localFallback(item: candidate, settings: settings))
      settings.automaticLocalSummaries = true
      settings.automaticLocalFileSummaries = true
      settings.automaticOCR = true
      XCTAssertEqual(automatic.localFallback(item: candidate, settings: settings)?.automatic, true)
      XCTAssertNil(local?.localFallback(item: candidate, settings: settings))
    }
  }
  @MainActor func testFallbackRejectsRevocationPrivateItemsAndStaleIDs() async {
    var settings = preferences()
    settings.localTextSummariesEnabled = true
    let candidate = item()
    let request = DesktopAnalysisScheduler.Request(id: candidate.id, remote: true, automatic: false)
    XCTAssertNil(request.localFallback(item: item(), settings: settings))
    var privateItem = candidate
    privateItem.sensitive = true
    XCTAssertNil(request.localFallback(item: privateItem, settings: settings))
    privateItem.sensitive = false
    privateItem.payloads = [
      .init(pasteboardType: SensitivityFilter.concealedType, inlineData: Data())
    ]
    XCTAssertNil(request.localFallback(item: privateItem, settings: settings))
    settings.ai.allowText = false
    XCTAssertNil(request.localFallback(item: candidate, settings: settings))
  }
  @MainActor func testFallbackProgressKeepsTheOriginalRetryEngineAndTicket() async throws {
    var values: [UUID: DesktopItemAnalysisProgress] = [:]
    let state = DesktopAnalysisProgressState { values = $0 }
    let first = try XCTUnwrap(state.begin(id: UUID(), remote: true))
    state.useLocalFallback(first)
    XCTAssertTrue(state.isCurrent(first))
    XCTAssertEqual(values[first.id], .running(remote: false))
    state.finish(first, succeeded: false)
    XCTAssertEqual(values[first.id], .failed(remote: true))
    let retry = try XCTUnwrap(state.begin(id: first.id, remote: true))
    state.useLocalFallback(first)
    XCTAssertEqual(values[first.id], .running(remote: true))
    state.finish(retry, succeeded: true)
    XCTAssertTrue(values.isEmpty)
  }
  private actor Gate {
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() {
      continuation?.resume()
      continuation = nil
    }
  }
  @MainActor private final class Owner { weak var scheduler: DesktopAnalysisScheduler? }
  @MainActor func testLocalPhaseRevocationCancelsTheSameOwnedTask() async {
    let candidate = item()
    var settings = preferences()
    settings.localTextSummariesEnabled = true
    let gate = Gate()
    let owner = Owner()
    let local = expectation(description: "local phase started")
    let done = expectation(description: "owned task ended")
    var cancelled = false
    let scheduler = DesktopAnalysisScheduler { _ in
      XCTAssertNotNil(owner.scheduler?.beginLocalFallback(item: candidate, settings: settings))
      local.fulfill()
      await gate.wait()
      cancelled = Task.isCancelled
      done.fulfill()
    }
    owner.scheduler = scheduler
    scheduler.submit(.init(id: candidate.id, remote: true, automatic: false))
    await fulfillment(of: [local], timeout: 3)
    XCTAssertEqual(scheduler.currentRequest?.remote, false)
    XCTAssertNil(scheduler.beginLocalFallback(item: candidate, settings: settings))
    settings.localTextSummariesEnabled = false
    XCTAssertTrue(scheduler.recheckCurrent(id: candidate.id, item: candidate, settings: settings))
    await gate.release()
    await fulfillment(of: [done], timeout: 3)
    XCTAssertTrue(cancelled)
    scheduler.stop()
    XCTAssertNil(scheduler.beginLocalFallback(item: candidate, settings: preferences()))
  }
}
