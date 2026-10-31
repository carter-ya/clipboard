import XCTest

@testable import ClipboardCore

final class DesktopHistoryActivationTests: XCTestCase {
  @MainActor func testOnlySuccessfulCopyDismissesAndStopRefusesWork() async {
    let state = DesktopHistoryActivationState()
    let failed = await state.activate { false }
    XCTAssertFalse(failed)
    let copied = await state.activate { true }
    XCTAssertTrue(copied)
    state.stop()
    let stopped = await state.activate {
      XCTFail("Stopped activation ran")
      return true
    }
    XCTAssertFalse(stopped)
  }
  @MainActor func testPresentationChangeRejectsLateDismissalAndDuplicateActivation() async {
    let state = DesktopHistoryActivationState()
    let started = expectation(description: "copy suspended")
    var release: CheckedContinuation<Bool, Never>?
    let pending = Task { @MainActor in
      await state.activate {
        await withCheckedContinuation {
          release = $0
          started.fulfill()
        }
      }
    }
    await fulfillment(of: [started], timeout: 3)
    XCTAssertTrue(state.busy)
    let duplicate = await state.activate {
      XCTFail("Duplicate activation ran")
      return true
    }
    XCTAssertFalse(duplicate)
    state.invalidatePresentation()
    release?.resume(returning: true)
    let dismissed = await pending.value
    XCTAssertFalse(dismissed)
    XCTAssertFalse(state.busy)
    let next = await state.activate { true }
    XCTAssertTrue(next)
  }
}
