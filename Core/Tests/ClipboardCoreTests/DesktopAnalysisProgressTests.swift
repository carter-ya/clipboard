import XCTest

@testable import ClipboardCore

final class DesktopAnalysisProgressTests: XCTestCase {
  @MainActor func testProgressBelongsToOneItemAndRetryInvalidatesPriorTicket() async throws {
    var states: [UUID: DesktopItemAnalysisProgress] = [:]
    let state = DesktopAnalysisProgressState { states = $0 }
    let first = UUID()
    let other = UUID()
    let ticket = try XCTUnwrap(state.begin(id: first, remote: true))
    XCTAssertEqual(states[first], .running(remote: true))
    XCTAssertNil(states[other])
    XCTAssertNil(state.begin(id: first, remote: true))
    state.finish(ticket, succeeded: false)
    XCTAssertEqual(states[first], .failed(remote: true))
    XCTAssertFalse(state.isCurrent(ticket))
    let retry = try XCTUnwrap(state.begin(id: first, remote: true))
    state.finish(ticket, succeeded: true)
    XCTAssertEqual(states[first], .running(remote: true))
    state.finish(retry, succeeded: true)
    XCTAssertTrue(states.isEmpty)
  }

  @MainActor func testDeleteClearAndStopRejectLateOutcomes() async throws {
    var states: [UUID: DesktopItemAnalysisProgress] = [:]
    let state = DesktopAnalysisProgressState { states = $0 }
    let id = UUID()
    let removed = try XCTUnwrap(state.begin(id: id, remote: false))
    state.remove(id: id)
    state.finish(removed, succeeded: false)
    XCTAssertTrue(states.isEmpty)
    let cleared = try XCTUnwrap(state.begin(id: id, remote: false))
    state.clear()
    state.finish(cleared, succeeded: false)
    XCTAssertTrue(states.isEmpty)
    let stopped = try XCTUnwrap(state.begin(id: id, remote: true))
    state.stop()
    state.finish(stopped, succeeded: false)
    XCTAssertTrue(states.isEmpty)
    XCTAssertNil(state.begin(id: id, remote: false))
  }

  @MainActor func testCapacityBoundsFailureMetadataWithoutDroppingRunningWork() async throws {
    var states: [UUID: DesktopItemAnalysisProgress] = [:]
    let state = DesktopAnalysisProgressState(capacity: 2) { states = $0 }
    let active = try XCTUnwrap(state.begin(id: UUID(), remote: false))
    let failed = try XCTUnwrap(state.begin(id: UUID(), remote: true))
    XCTAssertNil(state.begin(id: UUID(), remote: true))
    state.finish(failed, succeeded: false)
    let new = try XCTUnwrap(state.begin(id: UUID(), remote: true))
    XCTAssertEqual(states.count, 2)
    XCTAssertEqual(states[active.id], .running(remote: false))
    XCTAssertEqual(states[new.id], .running(remote: true))
    XCTAssertNil(states[failed.id])
  }
}
