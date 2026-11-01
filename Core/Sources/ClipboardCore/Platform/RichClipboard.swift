import Foundation

public struct RichClipboardSnapshot: Sendable, Equatable {
  public let payloads: [RawPayload]
  public let sourceAppID: String?
  public let sensitive: Bool
  public let revision: UInt64
  public init(
    payloads: [RawPayload], sourceAppID: String? = nil, sensitive: Bool = false, revision: UInt64
  ) {
    self.payloads = payloads
    self.sourceAppID = sourceAppID
    self.sensitive = sensitive
    self.revision = revision
  }
}

public protocol RichClipboardAccess: AnyObject, Sendable {
  var canMonitor: Bool { get }
  func revision() -> UInt64
  func read(maxBytes: Int) throws -> RichClipboardSnapshot?
  func write(payloads: [RawPayload], sensitive: Bool) throws
}

extension RichClipboardAccess {
  public var canMonitor: Bool { true }
}

public final class FakeRichClipboard: RichClipboardAccess, @unchecked Sendable {
  private let lock = NSLock()
  private var value: RichClipboardSnapshot?
  private var token: UInt64 = 0
  public init() {}
  public func revision() -> UInt64 { lock.withLock { token } }
  public func read(maxBytes: Int) throws -> RichClipboardSnapshot? {
    try lock.withLock {
      if let value, value.payloads.reduce(0, { $0 + $1.data.count }) > maxBytes {
        throw TextClipboardError.tooLarge(maxBytes + 1)
      }
      return value
    }
  }
  public func write(payloads: [RawPayload], sensitive: Bool) throws {
    lock.withLock {
      token &+= 1
      value = .init(payloads: payloads, sensitive: sensitive, revision: token)
    }
  }
  public func push(_ snapshot: RichClipboardSnapshot) {
    lock.withLock {
      token = snapshot.revision
      value = snapshot
    }
  }
}

public final class RichPasteboardWriter: PasteboardWriting, Sendable {
  private let clipboard: any RichClipboardAccess
  private let resolver: PayloadResolver
  public init(clipboard: any RichClipboardAccess, blobRoot: URL? = nil) {
    self.clipboard = clipboard
    resolver = PayloadResolver(blobRoot: blobRoot)
  }
  public func write(_ item: ClipItem) throws {
    var payloads: [RawPayload] = []
    var total = 0
    let supported: Set<String> = [
      "public.utf8-plain-text", "public.plain-text", "public.string", "public.html", "public.rtf",
      "public.png", "public.jpeg", "public.tiff", "com.microsoft.bmp", "public.file-url",
    ]
    for payload in item.payloads where supported.contains(payload.pasteboardType) {
      let data = try resolver.data(for: payload)
      total += data.count
      guard total <= 16 * 1024 * 1024 else { throw TextClipboardError.tooLarge(total) }
      payloads.append(.init(pasteboardType: payload.pasteboardType, data: data))
    }
    guard !payloads.isEmpty else { throw TextClipboardError.noTextPayload }
    try clipboard.write(payloads: payloads, sensitive: item.sensitive)
  }
}

public final class RichClipboardMonitor: ClipboardMonitoring, @unchecked Sendable {
  public let changes: AsyncStream<RawClipItem>
  public let skips: AsyncStream<SkipEvent>
  private let changeOutput: AsyncStream<RawClipItem>.Continuation
  private let skipOutput: AsyncStream<SkipEvent>.Continuation
  private let clipboard: any RichClipboardAccess
  private let filter: any ClipFilter
  private let maxBytes: Int
  private let queue = DispatchQueue(label: "com.clipboard.monitor.rich")
  private let key = DispatchSpecificKey<Bool>()
  private var timer: DispatchSourceTimer?
  private var lastRevision: UInt64
  private let interval: TimeInterval
  public init(
    clipboard: any RichClipboardAccess, filter: any ClipFilter = FilterChain(filters: []),
    maxBytes: Int = 10 * 1024 * 1024, interval: TimeInterval = 0.3
  ) {
    self.clipboard = clipboard
    self.filter = filter
    self.maxBytes = min(16 * 1024 * 1024, max(1, maxBytes))
    self.interval = max(0.01, interval)
    lastRevision = clipboard.revision()
    (changes, changeOutput) = AsyncStream.makeStream()
    (skips, skipOutput) = AsyncStream.makeStream()
    queue.setSpecific(key: key, value: true)
  }
  private func sync(_ action: () -> Void) {
    if DispatchQueue.getSpecific(key: key) != nil { action() } else { queue.sync(execute: action) }
  }
  public func start() {
    sync {
      guard timer == nil else { return }
      guard clipboard.canMonitor else {
        emitSkip("unsupportedSession", bytes: 0, source: nil)
        return
      }
      lastRevision = clipboard.revision()
      guard clipboard.canMonitor else {
        emitSkip("unsupportedSession", bytes: 0, source: nil)
        return
      }
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
  private func tick() {
    guard clipboard.canMonitor else {
      timer?.cancel()
      timer = nil
      emitSkip("unsupportedSession", bytes: 0, source: nil)
      return
    }
    let revision = clipboard.revision()
    guard revision != lastRevision else { return }
    do {
      guard let snapshot = try clipboard.read(maxBytes: maxBytes) else {
        lastRevision = revision
        return
      }
      var total = snapshot.payloads.reduce(0) { $0 + $1.data.count }
      for payload in snapshot.payloads where payload.pasteboardType == "public.file-url" {
        guard let urls = try? ClipboardFormats.fileURLs(from: payload.data) else { continue }
        for url in urls where url.host == nil || url.host == "" || url.host == "localhost" {
          if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? NSNumber
          {
            let sum = total.addingReportingOverflow(max(0, size.intValue))
            total = sum.overflow ? Int.max : sum.partialValue
          }
        }
      }
      lastRevision = snapshot.revision
      guard total <= maxBytes else {
        emitSkip("tooLarge", bytes: total, source: snapshot.sourceAppID)
        return
      }
      var raw = RawClipItem(
        payloads: snapshot.payloads, bundleID: snapshot.sourceAppID,
        changeCount: Int(truncatingIfNeeded: snapshot.revision), totalBytes: total,
        isSensitive: snapshot.sensitive,
        sensitivityReason: snapshot.sensitive ? "nativeClipboardHint" : nil)
      let context = ClipContext(
        sourceBundleID: snapshot.sourceAppID, changeCount: raw.changeCount, timestamp: raw.timestamp
      )
      switch filter.evaluate(raw, context: context) {
      case .accept: changeOutput.yield(raw)
      case .markSensitive(let reason):
        raw.isSensitive = true
        raw.sensitivityReason = reason
        changeOutput.yield(raw)
      case .reject(let reason): emitSkip(reason, bytes: total, source: snapshot.sourceAppID)
      }
    } catch TextClipboardError.tooLarge(let size) {
      lastRevision = revision
      emitSkip("tooLarge", bytes: size, source: nil)
    } catch TextClipboardError.unsupportedSession {
      timer?.cancel()
      timer = nil
      emitSkip("unsupportedSession", bytes: 0, source: nil)
    } catch {
      // Transient native contention retries without logging content.
    }
  }
  private func emitSkip(_ reason: String, bytes: Int, source: String?) {
    skipOutput.yield(
      .init(reason: reason, bytes: bytes, limit: maxBytes, types: [], bundleID: source))
  }
  deinit {
    timer?.cancel()
    changeOutput.finish()
    skipOutput.finish()
  }
}
