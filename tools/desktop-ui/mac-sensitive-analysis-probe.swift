// Actual App coordinator/remote code, fake HTTP and engines, volatile defaults.
// This executable never creates a window or accesses any pasteboard.
import ClipboardCore
import Foundation

private final class Signal: @unchecked Sendable {
  private let lock = NSLock()
  private var signalled = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func signal() {
    lock.lock()
    signalled = true
    let pending = waiters
    waiters.removeAll()
    lock.unlock()
    for waiter in pending { waiter.resume() }
  }
  func wait() async {
    await withCheckedContinuation { continuation in
      lock.lock()
      if signalled {
        lock.unlock()
        continuation.resume()
      } else {
        waiters.append(continuation)
        lock.unlock()
      }
    }
  }
}
private actor FetchGate {
  private var pending: CheckedContinuation<Void, Never>?
  private var entered: CheckedContinuation<Void, Never>?
  func hold() async {
    await withCheckedContinuation {
      pending = $0
      entered?.resume()
      entered = nil
    }
  }
  func started() async { if pending == nil { await withCheckedContinuation { entered = $0 } } }
  func release() {
    pending?.resume()
    pending = nil
  }
}
private actor Counts {
  var requests = 0
  var fallback = 0
  func request() { requests += 1 }
  func fallBack() { fallback += 1 }
}
private enum StubEngines { static let counts = Counts() }
struct VisionImageSummarizer: ImageSummarizer {
  func summarize(imageData: Data) async -> String? {
    await StubEngines.counts.fallBack()
    return nil
  }
}
struct NaturalLanguageTextSummarizer: TextSummarizer {
  func summarize(text: String) async -> String? {
    await StubEngines.counts.fallBack()
    return nil
  }
}
@available(macOS 26.0, *) struct FoundationModelsSummarizer {
  init(responseLanguage: String?) {}
  func summarize(text: String) async -> String? {
    await StubEngines.counts.fallBack()
    return nil
  }
  func summarizeFile(url: URL) async -> String? {
    await StubEngines.counts.fallBack()
    return nil
  }
}
private final class HeldKey: @unchecked Sendable {
  let started = Signal()
  let release = DispatchSemaphore(value: 0)
  func read() -> String? {
    started.signal()
    guard release.wait(timeout: .now() + 5) == .success else { return nil }
    return "synthetic-test-credential"
  }
}
@main private struct MacSensitiveAnalysisProbe {
  @MainActor static func main() async throws {
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    let manual = CommandLine.arguments.contains("--manual")
    let store = try await JSONSnapshotClipStore(
      root: root, inlineThresholdBytes: 1, sensitiveTextMasking: false)
    let defaults = UserDefaults(suiteName: "clipboard-private-analysis-" + UUID().uuidString)!
    defaults.setVolatileDomain(
      [
        "summariesEnabled": true, "allowTextSummaries": true,
        "skipSensitive": false, "languageOverride": "en",
      ], forName: UserDefaults.argumentDomain)
    let preferences = PreferencesStore(defaults: defaults)
    let gate = FetchGate()
    let cancelled = Signal()
    let counts = Counts()
    let remote = RemoteOpenAISummarizer(
      baseURL: URL(string: "https://example.invalid/v1")!,
      keyProvider: { "synthetic-test-credential" }, model: "synthetic-fixture", timeout: 5,
      maxImageBytes: 1024,
      fetcher: { request, _ in
        await counts.request()
        return await withTaskCancellationHandler(
          operation: {
            await gate.hold()
            return (
              Data(),
              HTTPURLResponse(
                url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            )
          }, onCancel: { cancelled.signal() })
      })
    let coordinator = SummaryCoordinator(
      store: store,
      resolver: PayloadResolver(blobRoot: root.appendingPathComponent("blobs")),
      prefsStore: preferences, remoteFactory: { _ in remote })
    let progress = coordinator.progressEvents
    defer { coordinator.stop() }
    let bytes = Data(("sk-" + String(repeating: "Synthetic123", count: 4)).utf8)
    let payload = RawPayload(pasteboardType: "public.utf8-plain-text", data: bytes)
    if !manual { coordinator.start() }
    await store.insert(RawClipItem(payloads: [payload], totalBytes: bytes.count))
    let before = await store.all()
    let id = before[0].id
    var retry: Task<Void, Never>?
    if manual {
      coordinator.start()
      retry = Task { @MainActor in await coordinator.retry(before[0]) }
    }
    await gate.started()
    await store.insert(
      RawClipItem(
        payloads: [payload], totalBytes: bytes.count,
        isSensitive: true, sensitivityReason: "credentialPattern"))
    FileHandle.standardOutput.write(
      Data("Waiting for actual Mac owned-attempt cancellation\n".utf8))
    await cancelled.wait()
    await gate.release()
    for await event in progress {
      if case .failed(let completed) = event, completed == id { break }
      if case .finished(let completed) = event, completed == id {
        fatalError("sensitive_attempt_published_success")
      }
    }
    await retry?.value
    let fallback = await StubEngines.counts.fallback
    let requests = await counts.requests
    let current = await store.item(id: id)
    precondition(
      fallback == 0 && requests == 1 && current?.sensitive == true && current?.summary == nil)
    coordinator.stop()
    print(
      "PASS actual Mac observer cancels its held \(manual ? "manual" : "automatic") attempt without starting a local fallback"
    )
    #if !LIFECYCLE_ONLY
      if !manual {
        let key = HeldKey()
        let directCalls = Counts()
        let other = RawPayload(
          pasteboardType: "public.utf8-plain-text",
          data: Data(("sk-" + String(repeating: "DirectSynthetic123", count: 4)).utf8))
        await store.insert(RawClipItem(payloads: [other], totalBytes: other.data.count))
        let next = await store.all()
        let otherID = next[0].id
        let checked = RemoteOpenAISummarizer(
          baseURL: URL(string: "https://example.invalid/v1")!,
          keyProvider: { key.read() }, model: "synthetic-fixture", timeout: 5, maxImageBytes: 1024,
          fetcher: { request, _ in
            await directCalls.request()
            return (
              Data(),
              HTTPURLResponse(
                url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            )
          }
        ).authorizing {
          guard let item = await store.item(id: otherID) else { return false }
          return !item.sensitive
        }
        let work = Task.detached { await checked.summarize(text: "synthetic private request") }
        await key.started.wait()
        await store.insert(
          RawClipItem(
            payloads: [other], totalBytes: other.data.count,
            isSensitive: true, sensitivityReason: "credentialPattern"))
        key.release.signal()
        let result = await work.value
        let sent = await directCalls.requests
        precondition(result == nil && sent == 0)
        print(
          "PASS actual Mac dispatch rechecks current sensitivity after a held key provider without UI cancellation"
        )
      }
    #endif
    await store.flush()
  }
}
