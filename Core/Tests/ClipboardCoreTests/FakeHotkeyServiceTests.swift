import KeyboardShortcuts
import XCTest

@testable import ClipboardCore

final class FakeHotkeyServiceTests: XCTestCase {

  func testFireEmitsEvent() async {
    let svc = FakeHotkeyService()
    let collector = Task {
      var count = 0
      for await _ in svc.events {
        count += 1
        if count == 2 { break }
      }
      return count
    }
    svc.fire()
    svc.fire()
    let count = await collector.value
    XCTAssertEqual(count, 2)
  }

  func testBindSetsNameAndStatus() async {
    let svc = FakeHotkeyService()
    let collector = Task {
      var statuses: [BindingStatus] = []
      for await s in svc.bindingStatus {
        statuses.append(s)
        if statuses.count == 2 { break }
      }
      return statuses
    }
    svc.bind(.toggleHistoryPanel)
    svc.unbind()
    let statuses = await collector.value
    XCTAssertEqual(statuses, [.ok, .unbound])
    XCTAssertNil(svc.boundName)
  }

  func testSimulateConflictEmitsConflictStatus() async {
    let svc = FakeHotkeyService()
    let collector = Task {
      var out: [BindingStatus] = []
      for await s in svc.bindingStatus {
        out.append(s)
        if out.count == 1 { break }
      }
      return out
    }
    svc.simulateConflict(reason: "taken by Spotlight")
    let result = await collector.value
    XCTAssertEqual(result, [.conflict("taken by Spotlight")])
  }
}
