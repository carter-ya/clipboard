import KeyboardShortcuts
import XCTest

@testable import ClipboardCore

final class KeyboardShortcutsHotkeyServiceTests: XCTestCase {
  func testBindWithoutStoredShortcutReportsUnbound() async {
    let name = KeyboardShortcuts.Name("testNoShortcut-\(UUID().uuidString)")
    KeyboardShortcuts.setShortcut(nil, for: name)

    let service = KeyboardShortcutsHotkeyService()
    let collector = Task {
      var statuses: [BindingStatus] = []
      for await status in service.bindingStatus {
        statuses.append(status)
        if statuses.count == 2 { break }
      }
      return statuses
    }

    service.bind(name)

    let statuses = await collector.value
    XCTAssertEqual(statuses, [.unbound, .unbound])
  }
}
