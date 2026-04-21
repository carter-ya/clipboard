import Foundation

public final class FakeClipboardMonitor: ClipboardMonitoring {
  public let changes: AsyncStream<RawClipItem>
  public let skips: AsyncStream<SkipEvent>
  private let continuation: AsyncStream<RawClipItem>.Continuation
  private let skipsContinuation: AsyncStream<SkipEvent>.Continuation
  public private(set) var isStarted: Bool = false

  public init() {
    let (stream, continuation) = AsyncStream.makeStream(of: RawClipItem.self)
    self.changes = stream
    self.continuation = continuation

    let (skipStream, skipContinuation) = AsyncStream.makeStream(of: SkipEvent.self)
    self.skips = skipStream
    self.skipsContinuation = skipContinuation
  }

  public func start() { isStarted = true }
  public func stop() { isStarted = false }

  public func push(_ item: RawClipItem) {
    continuation.yield(item)
  }

  public func push(skip: SkipEvent) {
    skipsContinuation.yield(skip)
  }

  public func finish() {
    continuation.finish()
    skipsContinuation.finish()
  }
}
