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
  @MainActor func testPauseDrainsUncooperativeWorkAndOverlappingOwnersCannotResumeEachOther() async
  {
    let started = expectation(description: "active worker owns its file")
    let pausing = expectation(description: "first pause acquired")
    let resumed = expectation(description: "fresh request after both pauses")
    var release: CheckedContinuation<Void, Never>?
    var calls = 0
    let scheduler = DesktopAnalysisScheduler { _ in
      calls += 1
      if calls == 1 {
        await withCheckedContinuation {
          release = $0
          started.fulfill()
        }
        XCTAssertTrue(Task.isCancelled)
      } else {
        resumed.fulfill()
      }
    }
    scheduler.submit(.init(id: UUID(), remote: false, automatic: true))
    await fulfillment(of: [started], timeout: 3)
    scheduler.submit(.init(id: UUID(), remote: false, automatic: true))
    var firstReturned = false
    let first = Task { @MainActor in
      let value = await scheduler.pauseAndDrain()
      firstReturned = true
      pausing.fulfill()
      return value
    }
    // A scheduling yield lets the pause take ownership before a second caller.
    let firstDeadline = Date().addingTimeInterval(3)
    while !scheduler.isPaused && Date() < firstDeadline { await Task.yield() }
    XCTAssertTrue(scheduler.isPaused)
    XCTAssertEqual(scheduler.pendingCount, 0)
    XCTAssertEqual(scheduler.submit(.init(id: UUID(), remote: false, automatic: true)), .busy)
    let second = Task { @MainActor in await scheduler.pauseAndDrain() }
    let secondDeadline = Date().addingTimeInterval(3)
    while scheduler.pauseCount < 2 && Date() < secondDeadline { await Task.yield() }
    XCTAssertEqual(scheduler.pauseCount, 2)
    XCTAssertFalse(firstReturned)
    XCTAssertTrue(scheduler.isBusy)
    release?.resume()
    let firstLease = await first.value
    let secondLease = await second.value
    await fulfillment(of: [pausing], timeout: 3)
    XCTAssertFalse(scheduler.isBusy)
    XCTAssertEqual(calls, 1)
    scheduler.resume(firstLease)
    scheduler.resume(firstLease)
    XCTAssertTrue(scheduler.isPaused)
    XCTAssertEqual(scheduler.submit(.init(id: UUID(), remote: false, automatic: false)), .busy)
    scheduler.resume(secondLease)
    XCTAssertFalse(scheduler.isPaused)
    XCTAssertEqual(scheduler.submit(.init(id: UUID(), remote: false, automatic: false)), .started)
    await fulfillment(of: [resumed], timeout: 3)
    await scheduler.stopAndDrain()
    XCTAssertEqual(scheduler.submit(.init(id: UUID(), remote: false, automatic: true)), .stopped)
  }

  @MainActor func testResumingAnIdlePauseCannotRestartAStoppedScheduler() async {
    let scheduler = DesktopAnalysisScheduler { _ in XCTFail("Stopped work started") }
    let pause = await scheduler.pauseAndDrain()
    await scheduler.stopAndDrain()
    scheduler.resume(pause)
    XCTAssertFalse(scheduler.isPaused)
    XCTAssertEqual(scheduler.submit(.init(id: UUID(), remote: false, automatic: true)), .stopped)
  }

  @MainActor func testOptionalLocalPhaseRevocationCancelsDespiteAnotherAuthorizedEngine() async {
    let started = expectation(description: "generative phase holds its worker")
    var release: CheckedContinuation<Void, Never>?
    let id = UUID()
    let item = ClipItem(
      id: id, createdAt: Date(), kind: .text, preview: "", sha256: "fixture", sizeBytes: 0)
    var settings = DesktopSettings()
    settings.localGenerativeSummariesEnabled = true
    settings.localLanguageSummariesEnabled = true
    weak var owned: DesktopAnalysisScheduler?
    let scheduler = DesktopAnalysisScheduler { request in
      XCTAssertTrue(
        owned?.beginLocalTextPhase(.generative, id: request.id, model: .generative) == true)
      await withCheckedContinuation {
        release = $0
        started.fulfill()
      }
      XCTAssertTrue(Task.isCancelled)
      XCTAssertFalse(owned?.beginLocalTextPhase(.language, id: request.id, model: nil) == true)
    }
    owned = scheduler
    XCTAssertEqual(scheduler.submit(.init(id: id, remote: false, automatic: false)), .started)
    await fulfillment(of: [started], timeout: 3)
    settings.localGenerativeSummariesEnabled = false
    XCTAssertTrue(
      DesktopLocalTextEngine.language.isAllowed(item: item, settings: settings, automatic: false))
    XCTAssertTrue(scheduler.recheckCurrent(id: id, item: item, settings: settings))
    release?.resume()
    await scheduler.stopAndDrain()
    XCTAssertFalse(scheduler.isBusy)
  }

  @MainActor func testModelMaintenanceRetainsUnrelatedActiveWorkAndResumesItsQueue() async {
    let started = expectation(description: "generative phase holds its worker")
    let idlePaused = expectation(description: "unrelated worker finishes while paused")
    let queued = expectation(description: "retained queue resumes")
    var release: CheckedContinuation<Void, Never>?
    var order: [UUID] = []
    let first = UUID()
    let next = UUID()
    weak var owner: DesktopAnalysisScheduler?
    let scheduler = DesktopAnalysisScheduler(
      busyChanged: { if !$0 && order.count == 1 { idlePaused.fulfill() } },
      perform: { request in
        order.append(request.id)
        if request.id == first {
          XCTAssertTrue(
            owner?.beginLocalTextPhase(.generative, id: first, model: .generative) == true)
          await withCheckedContinuation {
            release = $0
            started.fulfill()
          }
          XCTAssertFalse(Task.isCancelled)
        } else {
          queued.fulfill()
        }
      })
    owner = scheduler
    scheduler.submit(.init(id: first, remote: false, automatic: true))
    await fulfillment(of: [started], timeout: 3)
    scheduler.submit(.init(id: next, remote: false, automatic: true))
    let lease = await scheduler.pauseAndDrain(preservingPending: true) {
      $0.usesOptionalModel(.entities)
    }
    XCTAssertTrue(scheduler.isBusy)
    XCTAssertEqual(scheduler.pendingCount, 1)
    XCTAssertEqual(scheduler.currentRequest?.localTextEngine, .generative)
    XCTAssertFalse(scheduler.beginLocalTextPhase(.language, id: first, model: nil))
    release?.resume()
    await fulfillment(of: [idlePaused], timeout: 3)
    XCTAssertFalse(scheduler.isBusy)
    XCTAssertEqual(order, [first])
    scheduler.resume(lease)
    await fulfillment(of: [queued], timeout: 3)
    XCTAssertEqual(order, [first, next])
    await scheduler.stopAndDrain()
  }
  @MainActor func testMatchingModelPauseCancelsOnlyItsTicketAndRetainsOtherFailureMetadata()
    async throws
  {
    var progress: [UUID: DesktopItemAnalysisProgress] = [:]
    let state = DesktopAnalysisProgressState { progress = $0 }
    let ticket = try XCTUnwrap(state.begin(id: UUID(), remote: false))
    let other = try XCTUnwrap(state.begin(id: UUID(), remote: true))
    state.finish(other, succeeded: false)
    let started = expectation(description: "matching worker started")
    var release: CheckedContinuation<Void, Never>?
    weak var owner: DesktopAnalysisScheduler?
    let scheduler = DesktopAnalysisScheduler { request in
      XCTAssertTrue(
        owner?.beginLocalTextPhase(.generative, id: request.id, model: .generative) == true)
      await withCheckedContinuation {
        release = $0
        started.fulfill()
      }
      XCTAssertTrue(Task.isCancelled)
      state.finish(ticket, succeeded: true)
    }
    owner = scheduler
    scheduler.submit(.init(id: ticket.id, remote: false, automatic: false))
    await fulfillment(of: [started], timeout: 3)
    let pausing = Task { @MainActor in
      await scheduler.pauseAndDrain(preservingPending: true) { request in
        guard request.usesOptionalModel(.generative) else { return false }
        state.remove(id: request.id)
        return true
      }
    }
    let deadline = Date().addingTimeInterval(3)
    while !scheduler.isPaused && Date() < deadline { await Task.yield() }
    XCTAssertTrue(scheduler.isPaused)
    XCTAssertTrue(scheduler.isBusy)
    XCTAssertNil(progress[ticket.id])
    XCTAssertEqual(progress[other.id], .failed(remote: true))
    release?.resume()
    let lease = await pausing.value
    scheduler.resume(lease)
    XCTAssertEqual(progress[other.id], .failed(remote: true))
    XCTAssertNil(progress[ticket.id])
    await scheduler.stopAndDrain()
  }

  @MainActor func testLanguageOnlyPhaseOwnsNoOptionalModelAndRejectsWrongModelKinds() async {
    let checked = expectation(description: "resource metadata checked")
    weak var owner: DesktopAnalysisScheduler?
    let scheduler = DesktopAnalysisScheduler { request in
      XCTAssertTrue(owner?.beginLocalTextPhase(.language, id: request.id, model: nil) == true)
      XCTAssertFalse(owner?.currentRequest?.usesOptionalModel(.entities) == true)
      XCTAssertFalse(owner?.currentRequest?.usesOptionalModel(.generative) == true)
      XCTAssertFalse(
        owner?.beginLocalTextPhase(.language, id: request.id, model: .generative) == true)
      XCTAssertTrue(owner?.beginLocalTextPhase(.language, id: request.id, model: .entities) == true)
      XCTAssertTrue(owner?.currentRequest?.usesOptionalModel(.entities) == true)
      XCTAssertFalse(owner?.beginLocalTextPhase(.generative, id: request.id, model: nil) == true)
      checked.fulfill()
    }
    owner = scheduler
    scheduler.submit(.init(id: UUID(), remote: false, automatic: false))
    await fulfillment(of: [checked], timeout: 3)
    await scheduler.stopAndDrain()
  }

}
