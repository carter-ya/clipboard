import XCTest

@testable import ClipboardCore

final class FakeClipboardMonitorTests: XCTestCase {

  func testPushDeliversItemsToStream() async {
    let monitor = FakeClipboardMonitor()
    let expected = RawClipItem(
      payloads: [RawPayload(pasteboardType: "public.utf8-plain-text", data: Data("x".utf8))],
      bundleID: "com.apple.finder",
      changeCount: 5,
      totalBytes: 1,
      timestamp: Date(timeIntervalSince1970: 0)
    )

    let collectTask = Task {
      var items: [RawClipItem] = []
      for await item in monitor.changes {
        items.append(item)
        if items.count == 1 { break }
      }
      return items
    }

    monitor.push(expected)
    let items = await collectTask.value
    XCTAssertEqual(items.count, 1)
    XCTAssertEqual(items.first, expected)
  }

  func testStartStopToggle() {
    let monitor = FakeClipboardMonitor()
    XCTAssertFalse(monitor.isStarted)
    monitor.start()
    XCTAssertTrue(monitor.isStarted)
    monitor.stop()
    XCTAssertFalse(monitor.isStarted)
  }
}
