import Foundation

public final class FakeClipboardMonitor: ClipboardMonitoring {
  public let changes: AsyncStream<RawClipItem>
  private let continuation: AsyncStream<RawClipItem>.Continuation
  private(set) public var isStarted: Bool = false

  public init() {
    let (stream, continuation) = AsyncStream.makeStream(of: RawClipItem.self)
    self.changes = stream
    self.continuation = continuation
  }

  public func start() { isStarted = true }
  public func stop() { isStarted = false }

  public func push(_ item: RawClipItem) {
    continuation.yield(item)
  }

  public func finish() {
    continuation.finish()
  }
}
