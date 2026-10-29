import Foundation

public enum TextClipboardError: Error, Equatable {
  case unavailable
  case unsupportedSession
  case tooLarge(Int)
  case timeout
  case invalidText
  case noTextPayload
}

public struct TextClipboardSnapshot: Sendable, Equatable {
  public let text: String
  public let sensitive: Bool
  public let revision: UInt64

  public init(text: String, sensitive: Bool = false, revision: UInt64) {
    self.text = text
    self.sensitive = sensitive
    self.revision = revision
  }
}

/// A bounded UTF-8 boundary; native types are normalized before entering Core.
public protocol TextClipboardAccess: AnyObject, Sendable {
  func revision() -> UInt64
  func read(maxBytes: Int) throws -> TextClipboardSnapshot?
  func write(text: String, sensitive: Bool) throws
}

public final class FakeTextClipboard: TextClipboardAccess, @unchecked Sendable {
  private let lock = NSLock()
  private var current: TextClipboardSnapshot?
  private var token: UInt64 = 0

  public init() {}
  public func revision() -> UInt64 { lock.withLock { token } }
  public func read(maxBytes: Int) throws -> TextClipboardSnapshot? {
    try lock.withLock {
      if let current, current.text.utf8.count > maxBytes {
        throw TextClipboardError.tooLarge(current.text.utf8.count)
      }
      return current
    }
  }
  public func write(text: String, sensitive: Bool) throws {
    lock.withLock {
      token &+= 1
      current = TextClipboardSnapshot(text: text, sensitive: sensitive, revision: token)
    }
  }
}

public final class TextPasteboardWriter: PasteboardWriting, Sendable {
  private let clipboard: any TextClipboardAccess
  private let resolver: PayloadResolver

  public init(clipboard: any TextClipboardAccess, blobRoot: URL? = nil) {
    self.clipboard = clipboard
    self.resolver = PayloadResolver(blobRoot: blobRoot)
  }

  public func write(_ item: ClipItem) throws {
    let priorities = ["public.utf8-plain-text", "public.plain-text", "public.string"]
    guard
      let payload = priorities.compactMap({ type in
        item.payloads.first { $0.pasteboardType == type }
      }).first
    else { throw TextClipboardError.noTextPayload }
    let bytes = try resolver.data(for: payload)
    guard let text = String(data: bytes, encoding: .utf8), !text.contains("\0") else {
      throw TextClipboardError.invalidText
    }
    try clipboard.write(text: text, sensitive: item.sensitive)
  }
}

/// Mirrors the existing monitor contract. Source-app attribution is unavailable
/// in this text-only experiment; native secret markers remain authoritative.
public final class TextClipboardMonitor: ClipboardMonitoring, @unchecked Sendable {
  public let changes: AsyncStream<RawClipItem>
  public let skips: AsyncStream<SkipEvent>
  private let changesContinuation: AsyncStream<RawClipItem>.Continuation
  private let skipsContinuation: AsyncStream<SkipEvent>.Continuation
  private let clipboard: any TextClipboardAccess
  private let filter: any ClipFilter
  private let maxBytes: Int
  private let interval: TimeInterval
  private let queue = DispatchQueue(label: "com.clipboard.monitor.text")
  private let queueKey = DispatchSpecificKey<Bool>()
  private var timer: DispatchSourceTimer?
  private var lastRevision: UInt64

  public init(
    clipboard: any TextClipboardAccess,
    filter: any ClipFilter = FilterChain(filters: []),
    maxBytes: Int = 1024 * 1024,
    interval: TimeInterval = 0.08
  ) {
    self.clipboard = clipboard
    self.filter = filter
    self.maxBytes = min(16 * 1024 * 1024, max(1, maxBytes))
    self.interval = max(0.01, interval)
    self.lastRevision = clipboard.revision()
    (self.changes, self.changesContinuation) = AsyncStream.makeStream(of: RawClipItem.self)
    (self.skips, self.skipsContinuation) = AsyncStream.makeStream(of: SkipEvent.self)
    queue.setSpecific(key: queueKey, value: true)
  }

  public func start() {
    sync {
      guard timer == nil else { return }
      // Discard changes made while monitoring was stopped.
      lastRevision = clipboard.revision()
      let timer = DispatchSource.makeTimerSource(queue: queue)
      timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(20))
      timer.setEventHandler { [weak self] in self?.tick() }
      self.timer = timer
      timer.resume()
    }
  }

  public func stop() {
    sync {
      timer?.cancel()
      timer = nil
    }
  }
  public func pulse() { sync { tick() } }

  private func sync<T>(_ operation: () throws -> T) rethrows -> T {
    if DispatchQueue.getSpecific(key: queueKey) != nil { return try operation() }
    return try queue.sync(execute: operation)
  }

  private func tick() {
    let revision = clipboard.revision()
    guard revision != lastRevision else { return }
    do {
      guard let snapshot = try clipboard.read(maxBytes: maxBytes) else {
        lastRevision = revision
        return
      }
      lastRevision = snapshot.revision
      let bytes = Data(snapshot.text.utf8)
      var raw = RawClipItem(
        payloads: [RawPayload(pasteboardType: "public.utf8-plain-text", data: bytes)],
        changeCount: Int(truncatingIfNeeded: snapshot.revision), totalBytes: bytes.count,
        isSensitive: snapshot.sensitive,
        sensitivityReason: snapshot.sensitive ? "nativeClipboardHint" : nil
      )
      if snapshot.sensitive {
        raw.payloads.append(
          RawPayload(pasteboardType: SensitivityFilter.concealedType, data: Data()))
      }
      let context = ClipContext(
        sourceBundleID: nil, changeCount: raw.changeCount, timestamp: raw.timestamp)
      switch filter.evaluate(raw, context: context) {
      case .accept: changesContinuation.yield(raw)
      case .markSensitive(let reason):
        raw.isSensitive = true
        raw.sensitivityReason = reason
        changesContinuation.yield(raw)
      case .reject(let reason): skip(reason: reason, bytes: bytes.count)
      }
    } catch TextClipboardError.tooLarge(let bytes) {
      lastRevision = revision
      skip(reason: "tooLarge", bytes: bytes)
    } catch {
      // Contention, a changing owner or a timeout is retried on the next tick.
      // No payload, error body or source text is logged.
    }
  }

  private func skip(reason: String, bytes: Int) {
    skipsContinuation.yield(
      SkipEvent(
        reason: reason, bytes: bytes, limit: maxBytes,
        types: ["public.utf8-plain-text"], bundleID: nil))
  }

  deinit {
    timer?.cancel()
    changesContinuation.finish()
    skipsContinuation.finish()
  }
}
