import XCTest

@testable import ClipboardCore

final class DesktopStartupStateTests: XCTestCase {
  private actor Backend: DesktopStartupControlling {
    var enabled = false
    enum Failure: Error { case denied }
    var failWrite = false
    var holdRead = false
    var holdWrite = false
    var readGate: CheckedContinuation<Bool, Never>?
    var writeGate: CheckedContinuation<Void, Never>?
    var writes: [Bool] = []
    let readStarted: @Sendable () -> Void
    let writeStarted: @Sendable () -> Void
    init(
      readStarted: @escaping @Sendable () -> Void = {},
      writeStarted: @escaping @Sendable () -> Void = {}
    ) {
      self.readStarted = readStarted
      self.writeStarted = writeStarted
    }
    func isEnabled() async -> Bool {
      if holdRead {
        holdRead = false
        return await withCheckedContinuation {
          readGate = $0
          readStarted()
        }
      }
      return enabled
    }
    func setEnabled(_ value: Bool) async throws {
      writes.append(value)
      if failWrite {
        failWrite = false
        throw Failure.denied
      }
      if holdWrite {
        holdWrite = false
        await withCheckedContinuation {
          writeGate = $0
          writeStarted()
        }
      }
      enabled = value
    }
    func externalChange(_ value: Bool) { enabled = value }
    func pauseRead() { holdRead = true }
    func pauseWrite() { holdWrite = true }
    func denyNextWrite() { failWrite = true }
    func releaseRead(_ value: Bool) {
      readGate?.resume(returning: value)
      readGate = nil
    }
    func releaseWrite() {
      writeGate?.resume()
      writeGate = nil
    }
    func recordedWrites() -> [Bool] { writes }
  }

  @MainActor func testPassiveRefreshTracksExternalChangesWithoutRegistering() async throws {
    let backend = Backend()
    var changes: [Bool] = []
    let state = DesktopStartupState(backend: backend) { value, _ in changes.append(value) }
    try await state.refresh()
    await backend.externalChange(true)
    try await state.refresh()
    try await state.refresh()
    await backend.externalChange(false)
    try await state.refresh()
    XCTAssertEqual(changes, [true, false])
    let writes = await backend.recordedWrites()
    XCTAssertTrue(writes.isEmpty)
  }

  @MainActor func testLatePassiveReadCannotOverwriteAnExplicitChange() async throws {
    let started = expectation(description: "old system read is suspended")
    let backend = Backend(readStarted: { started.fulfill() })
    let state = DesktopStartupState(backend: backend) { _, _ in }
    await backend.pauseRead()
    let oldRead = Task { @MainActor in try await state.refresh() }
    await fulfillment(of: [started], timeout: 3)
    let applied = try await state.apply(true)
    XCTAssertTrue(applied)
    await backend.releaseRead(false)
    try await oldRead.value
    XCTAssertTrue(state.enabled)
    XCTAssertFalse(state.busy)
  }

  @MainActor func testRefreshDuringMutationIsReconciledAndDuplicateClickIsIgnored() async throws {
    let started = expectation(description: "startup mutation is suspended")
    let backend = Backend(writeStarted: { started.fulfill() })
    let state = DesktopStartupState(backend: backend) { _, _ in }
    await backend.pauseWrite()
    let change = Task { @MainActor in try await state.apply(true) }
    await fulfillment(of: [started], timeout: 3)
    XCTAssertTrue(state.busy)
    try await state.refresh()
    let duplicate = try await state.apply(false)
    XCTAssertFalse(duplicate)
    await backend.releaseWrite()
    _ = try await change.value
    XCTAssertTrue(state.enabled)
    XCTAssertFalse(state.busy)
    let writes = await backend.recordedWrites()
    XCTAssertEqual(writes, [true])
  }

  @MainActor func testFailedMutationReleasesControlAndAllowsFreshRead() async throws {
    let backend = Backend()
    let state = DesktopStartupState(backend: backend) { _, _ in }
    await backend.denyNextWrite()
    do {
      _ = try await state.apply(true)
      XCTFail("Denied registration was accepted")
    } catch {}
    XCTAssertFalse(state.busy)
    XCTAssertFalse(state.enabled)
    await backend.externalChange(true)
    try await state.refresh()
    XCTAssertTrue(state.enabled)
    let writes = await backend.recordedWrites()
    XCTAssertEqual(writes, [true], "Recovery reads must not retry registration")
  }

  @MainActor func testStoppedStateIgnoresLateReadsAndFutureMutations() async throws {
    let started = expectation(description: "system read is suspended")
    let backend = Backend(readStarted: { started.fulfill() })
    var callbacks = 0
    let state = DesktopStartupState(backend: backend) { _, _ in callbacks += 1 }
    await backend.pauseRead()
    let read = Task { @MainActor in try await state.refresh() }
    await fulfillment(of: [started], timeout: 3)
    state.stop()
    await backend.releaseRead(true)
    try await read.value
    let applied = try await state.apply(true)
    XCTAssertFalse(applied)
    XCTAssertEqual(callbacks, 0)
    let writes = await backend.recordedWrites()
    XCTAssertTrue(writes.isEmpty)
  }
}
