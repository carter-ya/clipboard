import AppKit
import XCTest

@testable import ClipboardCore

final class SkipEventTests: XCTestCase {

  func testNSPasteboardMonitorEmitsSkipForOversizedClip() async {
    let pasteboard = FakePasteboard()
    let chain = FilterChain(filters: [SizeFilter(maxClipSizeBytes: 1000)])
    let monitor = NSPasteboardMonitor(
      pasteboard: pasteboard,
      filter: chain,
      maxClipSizeBytes: 1000,
      pollInterval: 0.3,
      leeway: .milliseconds(10),
      workspace: StubWorkspaceProvider(bundleID: "com.test.source"),
      queue: DispatchQueue(label: "com.clipboard.monitor.skip-test")
    )
    let collector = SkipCollector(stream: monitor.skips, expecting: 1)

    pasteboard.put(types: [(.string, Data(repeating: 0x41, count: 2000))])
    await monitor.pulse()

    let skips = await collector.wait(timeout: 0.5)
    XCTAssertEqual(skips.count, 1)
    XCTAssertEqual(skips.first?.reason, "tooLarge")
    XCTAssertEqual(skips.first?.bytes, 2000)
    XCTAssertEqual(skips.first?.limit, 1000)
    XCTAssertEqual(skips.first?.bundleID, "com.test.source")
  }

  func testFakeMonitorPushSkipDeliversToStream() async {
    let monitor = FakeClipboardMonitor()
    let collector = SkipCollector(stream: monitor.skips, expecting: 2)

    monitor.push(
      skip: SkipEvent(
        reason: "tooLarge", bytes: 100, limit: 50, types: ["public.png"],
        bundleID: "com.test"
      )
    )
    monitor.push(
      skip: SkipEvent(
        reason: "tooLarge", bytes: 200, limit: 50, types: [], bundleID: nil
      )
    )

    let skips = await collector.wait(timeout: 0.5)
    XCTAssertEqual(skips.count, 2)
    XCTAssertEqual(skips[0].bytes, 100)
    XCTAssertEqual(skips[1].bytes, 200)
  }
}

final class SkipCollector {
  private actor Buffer {
    private(set) var events: [SkipEvent] = []
    var count: Int { events.count }
    func append(_ e: SkipEvent) { events.append(e) }
  }
  private let buffer = Buffer()
  private let task: Task<Void, Never>

  init(stream: AsyncStream<SkipEvent>, expecting: Int) {
    let buffer = self.buffer
    self.task = Task.detached {
      for await skip in stream {
        await buffer.append(skip)
        if await buffer.count >= expecting { break }
      }
    }
  }

  func wait(timeout: TimeInterval) async -> [SkipEvent] {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if task.isCancelled { break }
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
    task.cancel()
    return await buffer.events
  }
}
