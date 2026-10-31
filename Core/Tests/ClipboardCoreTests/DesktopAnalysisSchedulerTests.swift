import XCTest

@testable import ClipboardCore

final class DesktopAnalysisSchedulerTests: XCTestCase {
  @MainActor func testAutomaticWorkWaitsThenRunsInOrderAndManualBusyGuardRemains() async {
    let started = expectation(description: "first request is suspended")
    let drained = expectation(description: "three requests complete")
    drained.expectedFulfillmentCount = 3
    var release: CheckedContinuation<Void, Never>?
    var order: [UUID] = []
    var busyStates: [Bool] = []
    let ids = (0..<4).map { _ in UUID() }
    let scheduler = DesktopAnalysisScheduler(
      capacity: 2, busyChanged: { busyStates.append($0) },
      perform: { request in
        order.append(request.id)
        if request.id == ids[0] {
          await withCheckedContinuation {
            release = $0
            started.fulfill()
          }
        }
        drained.fulfill()
      })
    func automatic(_ index: Int) -> DesktopAnalysisScheduler.Request {
      .init(id: ids[index], remote: true, automatic: true)
    }
    XCTAssertEqual(scheduler.submit(automatic(0)), .started)
    await fulfillment(of: [started], timeout: 3)
    XCTAssertEqual(scheduler.submit(automatic(0)), .duplicate)
    XCTAssertEqual(scheduler.submit(automatic(1)), .queued)
    XCTAssertEqual(scheduler.submit(automatic(1)), .duplicate)
    XCTAssertEqual(scheduler.submit(automatic(2)), .queued)
    XCTAssertEqual(scheduler.submit(automatic(3)), .full)
    XCTAssertEqual(
      scheduler.submit(.init(id: ids[3], remote: false, automatic: false)), .busy)
    XCTAssertEqual(order, [ids[0]])
    XCTAssertEqual(scheduler.pendingCount, 2)
    release?.resume()
    await fulfillment(of: [drained], timeout: 3)
    XCTAssertEqual(order, Array(ids.prefix(3)))
    XCTAssertFalse(scheduler.isBusy)
    XCTAssertEqual(scheduler.pendingCount, 0)
    XCTAssertEqual(busyStates, [true, false])
  }

  @MainActor func testCancellingOneItemDropsItsQueueEntryAndDrainsOtherAllowedWork() async {
    let started = expectation(description: "active request suspended")
    let drained = expectation(description: "retained queue drained")
    let first = UUID()
    let removed = UUID()
    let retained = UUID()
    var release: CheckedContinuation<Void, Never>?
    var order: [UUID] = []
    let scheduler = DesktopAnalysisScheduler(
      busyChanged: { if !$0 { drained.fulfill() } },
      perform: { request in
        order.append(request.id)
        if request.id == first {
          await withCheckedContinuation {
            release = $0
            started.fulfill()
          }
          XCTAssertTrue(Task.isCancelled)
        } else {
          XCTAssertFalse(Task.isCancelled)
        }
      })
    scheduler.submit(.init(id: first, remote: true, automatic: true))
    await fulfillment(of: [started], timeout: 3)
    scheduler.submit(.init(id: removed, remote: true, automatic: true))
    scheduler.submit(.init(id: retained, remote: true, automatic: true))
    scheduler.cancel(id: removed)
    XCTAssertEqual(scheduler.pendingCount, 1)
    scheduler.cancel(id: first)
    release?.resume()
    await fulfillment(of: [drained], timeout: 3)
    XCTAssertEqual(order, [first, retained])
    XCTAssertNil(scheduler.currentRequest)
    XCTAssertFalse(scheduler.isBusy)
    XCTAssertEqual(scheduler.pendingCount, 0)
  }

  @MainActor func testStopCancelsActiveWorkAndDiscardsPendingRequests() async {
    let started = expectation(description: "active")
    let stopped = expectation(description: "active observes cancellation")
    var release: CheckedContinuation<Void, Never>?
    var calls = 0
    let scheduler = DesktopAnalysisScheduler { _ in
      calls += 1
      await withCheckedContinuation {
        release = $0
        started.fulfill()
      }
      XCTAssertTrue(Task.isCancelled)
      stopped.fulfill()
    }
    let first = DesktopAnalysisScheduler.Request(id: UUID(), remote: true, automatic: true)
    let next = DesktopAnalysisScheduler.Request(id: UUID(), remote: false, automatic: true)
    XCTAssertEqual(scheduler.submit(first), .started)
    await fulfillment(of: [started], timeout: 3)
    XCTAssertEqual(scheduler.submit(next), .queued)
    scheduler.stop()
    XCTAssertEqual(scheduler.pendingCount, 0)
    XCTAssertEqual(scheduler.submit(next), .stopped)
    release?.resume()
    await fulfillment(of: [stopped], timeout: 3)
    XCTAssertEqual(calls, 1)
    XCTAssertFalse(scheduler.isBusy)
  }

  @MainActor func testWorkerRechecksRevokedPermissionBeforeDraining() async {
    let started = expectation(description: "first request active")
    let drained = expectation(description: "queue drained")
    var release: CheckedContinuation<Void, Never>?
    var settings = DesktopSettings()
    settings.ai.enabled = true
    settings.automaticSummaries = true
    var requests = 0
    let first = UUID()
    let scheduler = DesktopAnalysisScheduler(
      busyChanged: { if !$0 { drained.fulfill() } },
      perform: { request in
        let item = ClipItem(
          id: request.id, createdAt: Date(), kind: .text, preview: "", sha256: "fixture",
          sizeBytes: 0, sensitive: false, payloads: [])
        guard request.isAllowed(item: item, settings: settings) else { return }
        requests += 1
        if request.id == first {
          await withCheckedContinuation {
            release = $0
            started.fulfill()
          }
        }
      })
    scheduler.submit(.init(id: first, remote: true, automatic: true))
    await fulfillment(of: [started], timeout: 3)
    scheduler.submit(.init(id: UUID(), remote: true, automatic: true))
    settings.automaticSummaries = false
    release?.resume()
    await fulfillment(of: [drained], timeout: 3)
    XCTAssertEqual(requests, 1)
    XCTAssertFalse(scheduler.isBusy)
  }
}
