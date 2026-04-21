import AppKit
import Foundation

public final class NSPasteboardMonitor: ClipboardMonitoring, @unchecked Sendable {
  public let changes: AsyncStream<RawClipItem>
  public let skips: AsyncStream<SkipEvent>

  private let continuation: AsyncStream<RawClipItem>.Continuation
  private let skipsContinuation: AsyncStream<SkipEvent>.Continuation
  private let pasteboard: PasteboardProtocol
  private let filter: any ClipFilter
  private let workspace: WorkspaceProvider
  private let pollInterval: TimeInterval
  private let leeway: DispatchTimeInterval
  private let queue: DispatchQueue
  private let maxClipSizeBytes: Int
  private let fileManager: FileManager

  private var timer: DispatchSourceTimer?
  private var lastChangeCount: Int

  public init(
    pasteboard: PasteboardProtocol = NSPasteboard.general,
    filter: any ClipFilter,
    maxClipSizeBytes: Int,
    pollInterval: TimeInterval = 0.3,
    leeway: DispatchTimeInterval = .milliseconds(80),
    workspace: WorkspaceProvider = SystemWorkspaceProvider(),
    queue: DispatchQueue = DispatchQueue(label: "com.clipboard.monitor"),
    fileManager: FileManager = .default
  ) {
    self.pasteboard = pasteboard
    self.filter = filter
    self.maxClipSizeBytes = maxClipSizeBytes
    self.pollInterval = pollInterval
    self.leeway = leeway
    self.workspace = workspace
    self.queue = queue
    self.fileManager = fileManager
    self.lastChangeCount = pasteboard.changeCount

    let (stream, continuation) = AsyncStream.makeStream(of: RawClipItem.self)
    self.changes = stream
    self.continuation = continuation

    let (skipStream, skipContinuation) = AsyncStream.makeStream(of: SkipEvent.self)
    self.skips = skipStream
    self.skipsContinuation = skipContinuation
  }

  public func start() {
    queue.async { [weak self] in
      guard let self, self.timer == nil else { return }
      let timer = DispatchSource.makeTimerSource(queue: self.queue)
      timer.schedule(
        deadline: .now() + self.pollInterval,
        repeating: self.pollInterval,
        leeway: self.leeway
      )
      timer.setEventHandler { [weak self] in self?.tick() }
      self.timer = timer
      timer.resume()
    }
  }

  public func stop() {
    queue.async { [weak self] in
      self?.timer?.cancel()
      self?.timer = nil
    }
  }

  /// Testing hook: drive one polling tick synchronously on `queue`.
  public func pulse() async {
    await withCheckedContinuation { cont in
      queue.async {
        self.tick()
        cont.resume()
      }
    }
  }

  private func tick() {
    let currentChangeCount = pasteboard.changeCount
    guard currentChangeCount != lastChangeCount else { return }
    lastChangeCount = currentChangeCount

    let bundleID = workspace.frontmostBundleIdentifier()
    let types = pasteboard.availableTypes ?? []
    let typeStrings = types.map(\.rawValue)

    var payloads: [RawPayload] = []
    var totalBytes = 0

    for type in types {
      guard let data = pasteboard.data(for: type) else { continue }
      if type.rawValue == "public.file-url" {
        let fileBytes = resolvedFileSize(from: data)
        totalBytes += fileBytes
        payloads.append(RawPayload(pasteboardType: type.rawValue, data: data))
      } else {
        totalBytes += data.count
        payloads.append(RawPayload(pasteboardType: type.rawValue, data: data))
      }
    }

    let rawItem = RawClipItem(
      payloads: payloads,
      bundleID: bundleID,
      changeCount: currentChangeCount,
      totalBytes: totalBytes,
      timestamp: Date()
    )

    let context = ClipContext(
      sourceBundleID: bundleID,
      changeCount: currentChangeCount,
      timestamp: rawItem.timestamp
    )

    let decision = filter.evaluate(rawItem, context: context)
    switch decision {
    case .accept:
      Log.monitor.info(
        """
        monitor.change{changeCount:\(currentChangeCount, privacy: .public), \
        types:\(typeStrings, privacy: .public), \
        bundleID:\(bundleID ?? "nil", privacy: .public)}
        """
      )
      continuation.yield(rawItem)
    case .reject(let reason):
      Log.monitor.info(
        """
        monitor.skipped{reason:"\(reason, privacy: .public)", \
        bytes:\(totalBytes, privacy: .public), \
        limit:\(self.maxClipSizeBytes, privacy: .public), \
        types:\(typeStrings, privacy: .public), \
        bundleID:\(bundleID ?? "nil", privacy: .public)}
        """
      )
      skipsContinuation.yield(
        SkipEvent(
          reason: reason,
          bytes: totalBytes,
          limit: maxClipSizeBytes,
          types: typeStrings,
          bundleID: bundleID
        )
      )
    case .markSensitive(let reason):
      Log.monitor.info(
        """
        monitor.sensitive{reason:"\(reason, privacy: .public)", \
        types:\(typeStrings, privacy: .public), \
        bundleID:\(bundleID ?? "nil", privacy: .public)}
        """
      )
      var sensitive = rawItem
      sensitive.isSensitive = true
      sensitive.sensitivityReason = reason
      continuation.yield(sensitive)
    }
  }

  private func resolvedFileSize(from urlData: Data) -> Int {
    guard let urlString = String(data: urlData, encoding: .utf8),
      let url = URL(string: urlString)
    else { return 0 }
    let path = url.isFileURL ? url.path : urlString
    let attrs = try? fileManager.attributesOfItem(atPath: path)
    return (attrs?[.size] as? Int) ?? 0
  }

  deinit {
    timer?.cancel()
    continuation.finish()
    skipsContinuation.finish()
  }
}
