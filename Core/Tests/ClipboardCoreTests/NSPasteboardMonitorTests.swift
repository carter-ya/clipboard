import AppKit
import XCTest

@testable import ClipboardCore

final class NSPasteboardMonitorTests: XCTestCase {

  func testEmitsOnChangeCountIncrement() async {
    let pasteboard = FakePasteboard()
    let monitor = makeMonitor(pasteboard: pasteboard, maxClipSizeBytes: 0)
    let collector = StreamCollector(stream: monitor.changes, expecting: 1)

    pasteboard.put(types: [(.string, Data("hello".utf8))])
    await monitor.pulse()

    let items = await collector.wait(timeout: 1.0)
    XCTAssertEqual(items.count, 1)
    XCTAssertEqual(items.first?.payloads.map(\.pasteboardType), ["public.utf8-plain-text"])
    XCTAssertEqual(items.first?.totalBytes, 5)
  }

  func testSkipsIdenticalChangeCount() async {
    let pasteboard = FakePasteboard()
    let monitor = makeMonitor(pasteboard: pasteboard, maxClipSizeBytes: 0)
    let collector = StreamCollector(stream: monitor.changes, expecting: 2)

    pasteboard.put(types: [(.string, Data("a".utf8))])
    await monitor.pulse()
    await monitor.pulse()

    let items = await collector.wait(timeout: 0.4)
    XCTAssertEqual(items.count, 1, "second tick with same changeCount must not emit")
  }

  func testCapturesBundleID() async {
    let pasteboard = FakePasteboard()
    let workspace = StubWorkspaceProvider(bundleID: "com.test.source")
    let monitor = makeMonitor(
      pasteboard: pasteboard,
      maxClipSizeBytes: 0,
      workspace: workspace
    )
    let collector = StreamCollector(stream: monitor.changes, expecting: 1)

    pasteboard.put(types: [(.string, Data("x".utf8))])
    await monitor.pulse()

    let items = await collector.wait(timeout: 1.0)
    XCTAssertEqual(items.first?.bundleID, "com.test.source")
  }

  func testExtractsMultipleTypes() async {
    let pasteboard = FakePasteboard()
    let monitor = makeMonitor(pasteboard: pasteboard, maxClipSizeBytes: 0)
    let collector = StreamCollector(stream: monitor.changes, expecting: 1)

    pasteboard.put(types: [
      (.string, Data("hi".utf8)),
      (.html, Data("<b>hi</b>".utf8)),
    ])
    await monitor.pulse()

    let items = await collector.wait(timeout: 1.0)
    XCTAssertEqual(items.first?.payloads.count, 2)
    XCTAssertEqual(items.first?.totalBytes, 2 + 9)
  }

  func testRejectsOversized() async {
    let pasteboard = FakePasteboard()
    let monitor = makeMonitor(pasteboard: pasteboard, maxClipSizeBytes: 1000)
    let collector = StreamCollector(stream: monitor.changes, expecting: 1)

    pasteboard.put(types: [(.string, Data(repeating: 0x41, count: 2000))])
    await monitor.pulse()

    let items = await collector.wait(timeout: 0.4)
    XCTAssertEqual(items.count, 0, "oversized clips must be rejected and not emitted")
  }

  func testMarksSensitiveWhenFilterDecides() async {
    let pasteboard = FakePasteboard()
    let sensitive = AlwaysSensitiveFilter(reason: "concealedType")
    let monitor = makeMonitor(
      pasteboard: pasteboard,
      maxClipSizeBytes: 0,
      extraFilters: [sensitive]
    )
    let collector = StreamCollector(stream: monitor.changes, expecting: 1)

    pasteboard.put(types: [(.string, Data("secret".utf8))])
    await monitor.pulse()

    let items = await collector.wait(timeout: 1.0)
    XCTAssertEqual(items.count, 1)
    XCTAssertEqual(items.first?.isSensitive, true)
    XCTAssertEqual(items.first?.sensitivityReason, "concealedType")
  }

  func testFileURLUsesStatWithoutReadingContents() async throws {
    let tmp = URL(
      fileURLWithPath: NSTemporaryDirectory()
    ).appendingPathComponent("clipboard-test-\(UUID().uuidString)")
    let body = Data(repeating: 0x42, count: 123)
    try body.write(to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let pasteboard = FakePasteboard()
    let monitor = makeMonitor(pasteboard: pasteboard, maxClipSizeBytes: 0)
    let collector = StreamCollector(stream: monitor.changes, expecting: 1)

    let urlData = Data(tmp.absoluteString.utf8)
    pasteboard.put(types: [(.fileURL, urlData)])
    await monitor.pulse()

    let items = await collector.wait(timeout: 1.0)
    XCTAssertEqual(items.first?.totalBytes, 123, "totalBytes should reflect stat() of the file")
    XCTAssertEqual(
      items.first?.payloads.first?.data,
      urlData,
      "payload still carries the url bytes, NOT the file contents"
    )
  }

  // MARK: - Helpers

  private func makeMonitor(
    pasteboard: FakePasteboard,
    maxClipSizeBytes: Int,
    workspace: WorkspaceProvider = StubWorkspaceProvider(bundleID: nil),
    extraFilters: [any ClipFilter] = []
  ) -> NSPasteboardMonitor {
    var filters: [any ClipFilter] = [SizeFilter(maxClipSizeBytes: maxClipSizeBytes)]
    filters.append(contentsOf: extraFilters)
    filters.append(NoOpSensitivityFilter())
    filters.append(NoOpBlocklistFilter())
    return NSPasteboardMonitor(
      pasteboard: pasteboard,
      filter: FilterChain(filters: filters),
      maxClipSizeBytes: maxClipSizeBytes,
      pollInterval: 0.3,
      leeway: .milliseconds(10),
      workspace: workspace,
      queue: DispatchQueue(label: "com.clipboard.monitor.test")
    )
  }
}

// MARK: - Fakes

final class FakePasteboard: PasteboardProtocol, @unchecked Sendable {
  private let lock = NSLock()
  private var _changeCount: Int = 0
  private var storage: [(NSPasteboard.PasteboardType, Data)] = []

  var changeCount: Int {
    lock.withLock { _changeCount }
  }

  var availableTypes: [NSPasteboard.PasteboardType]? {
    lock.withLock { storage.map(\.0) }
  }

  func data(for type: NSPasteboard.PasteboardType) -> Data? {
    lock.withLock { storage.first(where: { $0.0 == type })?.1 }
  }

  func put(types: [(NSPasteboard.PasteboardType, Data)]) {
    lock.withLock {
      storage = types
      _changeCount += 1
    }
  }
}

private struct AlwaysSensitiveFilter: ClipFilter {
  let reason: String
  func evaluate(_ item: RawClipItem, context: ClipContext) -> FilterDecision {
    .markSensitive(reason)
  }
}

actor ItemBuffer {
  private(set) var items: [RawClipItem] = []
  var count: Int { items.count }
  func append(_ item: RawClipItem) { items.append(item) }
}

final class StreamCollector {
  private let buffer = ItemBuffer()
  private let task: Task<Void, Never>

  init(stream: AsyncStream<RawClipItem>, expecting: Int) {
    let buffer = self.buffer
    self.task = Task.detached {
      for await item in stream {
        await buffer.append(item)
        if await buffer.count >= expecting { break }
      }
    }
  }

  func wait(timeout: TimeInterval) async -> [RawClipItem] {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if task.isCancelled { break }
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
    task.cancel()
    return await buffer.items
  }
}
