import XCTest

@testable import ClipboardCore

final class DesktopFileTextTests: XCTestCase {
  private actor Reader: DesktopFileTextReading {
    var calls: [(URL, Int)] = []
    let body: String
    init(
      body: String = "A synthetic file summary begins with this sentence. "
        + String(repeating: "More context. ", count: 20)
    ) { self.body = body }
    func text(from file: URL, maxBytes: Int) -> String {
      calls.append((file, maxBytes))
      return body
    }
  }
  private func item(_ urls: [URL] = [URL(fileURLWithPath: "/synthetic/private-name.txt")])
    -> ClipItem
  {
    .init(
      createdAt: Date(), kind: .file, preview: "", sha256: "fixture", sizeBytes: 0,
      payloads: [
        .init(pasteboardType: "public.file-url", inlineData: ClipboardFormats.fileURLData(urls))
      ])
  }
  private func settings() -> DesktopAISettings {
    var value = DesktopAISettings()
    value.enabled = true
    value.model = "fixture"
    return value
  }
  func testFileContentPermissionIsIndependentAndOnlyFirstBodyEntersRequest() async throws {
    let reader = Reader()
    let transport = FakeDesktopAITransport()
    let ocr = FakeDesktopOCR()
    let service = DesktopAnalysis(
      credentials: InMemoryDesktopCredentials(), transport: transport,
      ocr: ocr, blobRoot: nil, fileReader: reader)
    var configuration = settings()
    do {
      _ = try await service.summarize(item(), settings: configuration)
      XCTFail("Unapproved file read")
    } catch { XCTAssertEqual(error as? DesktopServiceError, .disabled) }
    let initial = await reader.calls
    XCTAssertTrue(initial.isEmpty)
    configuration.allowText = false
    configuration.allowFiles = true
    let first = URL(fileURLWithPath: "/synthetic/private-name.txt")
    _ = try await service.summarize(
      item([first, URL(fileURLWithPath: "/synthetic/second.txt")]), settings: configuration)
    let calls = await reader.calls
    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(calls.first?.0, first)
    XCTAssertEqual(calls.first?.1, DesktopFileTextPolicy.maximumBytes)
    let requests = await transport.requests
    XCTAssertEqual(requests.count, 1)
    let body = String(decoding: try XCTUnwrap(requests.first?.httpBody), as: UTF8.self)
    XCTAssertTrue(body.contains("A synthetic file summary"))
    XCTAssertFalse(body.contains("private-name"))
    XCTAssertFalse(body.contains("second.txt"))
    let local = try await service.summarizeLocally(item())
    XCTAssertEqual(local, "A synthetic file summary begins with this sentence.")
    let afterLocal = await transport.requests
    let ocrCalls = await ocr.calls
    XCTAssertEqual(afterLocal.count, 1)
    XCTAssertEqual(ocrCalls, 0)
  }
  func testSensitiveAndConcealedFilesFailBeforeReadingOrNetworking() async {
    let reader = Reader()
    let transport = FakeDesktopAITransport()
    let service = DesktopAnalysis(
      credentials: InMemoryDesktopCredentials(), transport: transport,
      ocr: FakeDesktopOCR(), blobRoot: nil, fileReader: reader)
    var configuration = settings()
    configuration.allowFiles = true
    for concealed in [false, true] {
      var candidate = item()
      candidate.sensitive = !concealed
      if concealed {
        candidate.payloads.append(
          .init(pasteboardType: SensitivityFilter.concealedType, inlineData: Data()))
      }
      do {
        _ = try await service.summarize(candidate, settings: configuration)
        XCTFail("Private file read")
      } catch { XCTAssertEqual(error as? DesktopServiceError, .sensitiveContent) }
      do {
        _ = try await service.summarizeLocally(candidate)
        XCTFail("Private local file read")
      } catch { XCTAssertEqual(error as? DesktopServiceError, .sensitiveContent) }
    }
    let calls = await reader.calls
    let requests = await transport.requests
    XCTAssertTrue(calls.isEmpty)
    XCTAssertTrue(requests.isEmpty)
  }
  func testRemoteURLUnknownFormatsAndEmbeddedCredentialsNeverReachReader() async throws {
    let reader = Reader()
    let service = DesktopAnalysis(
      credentials: InMemoryDesktopCredentials(), transport: FakeDesktopAITransport(),
      ocr: FakeDesktopOCR(), blobRoot: nil, fileReader: reader)
    var configuration = settings()
    configuration.allowFiles = true
    for value in [
      "https://example.invalid/a.txt", "file://server/share/a.txt", "file:///tmp/a.exe",
      "file:///tmp/a.txt?secret=fixture", "file:///tmp/a.txt#fragment",
      "file://name:password@localhost/tmp/a.txt",
    ] {
      do {
        _ = try await service.summarize(
          item([try XCTUnwrap(URL(string: value))]), settings: configuration)
        XCTFail("Unsupported file accepted")
      } catch {}
    }
    let calls = await reader.calls
    XCTAssertTrue(calls.isEmpty)
    try DesktopFileTextPolicy.validate(URL(fileURLWithPath: "/synthetic/FILE.TXT"))
    try DesktopFileTextPolicy.validate(URL(fileURLWithPath: "/synthetic/DOCUMENT.PDF"))
  }
  private actor SuspendedReader: DesktopFileTextReading {
    private var pending: CheckedContinuation<String, Never>?
    private var waiting: CheckedContinuation<Void, Never>?
    func text(from file: URL, maxBytes: Int) async -> String {
      await withCheckedContinuation {
        pending = $0
        waiting?.resume()
        waiting = nil
      }
    }
    func started() async { if pending == nil { await withCheckedContinuation { waiting = $0 } } }
    func finish() {
      pending?.resume(returning: "Synthetic file body released after permission revocation.")
      pending = nil
    }
  }
  @MainActor func testRevokedFilePermissionCancelsActiveReadBeforeAnyTransport() async {
    let reader = SuspendedReader()
    let transport = FakeDesktopAITransport()
    let service = DesktopAnalysis(
      credentials: InMemoryDesktopCredentials(), transport: transport,
      ocr: FakeDesktopOCR(), blobRoot: nil, fileReader: reader)
    var configuration = settings()
    configuration.allowFiles = true
    let candidate = item()
    var live = DesktopSettings()
    live.ai = configuration
    let drained = expectation(description: "cancelled file read drained")
    var cancelled = false
    let scheduler = DesktopAnalysisScheduler(
      busyChanged: { if !$0 { drained.fulfill() } },
      perform: { request in
        guard request.isAllowed(item: candidate, settings: live) else { return }
        do { _ = try await service.summarize(candidate, settings: live.ai) } catch {
          cancelled = error is CancellationError
        }
      })
    scheduler.submit(.init(id: candidate.id, remote: true, automatic: false))
    await reader.started()
    live.ai.allowFiles = false
    XCTAssertFalse(scheduler.recheckCurrent(id: UUID(), item: candidate, settings: live))
    XCTAssertTrue(scheduler.recheckCurrent(id: candidate.id, item: candidate, settings: live))
    await reader.finish()
    await fulfillment(of: [drained], timeout: 3)
    XCTAssertTrue(cancelled)
    let requests = await transport.requests
    XCTAssertTrue(requests.isEmpty)
  }

  func testMissingFileReferenceUsesAFileErrorBeforeReadingBody() async {
    let reader = Reader()
    let service = DesktopAnalysis(
      credentials: InMemoryDesktopCredentials(), transport: FakeDesktopAITransport(),
      ocr: FakeDesktopOCR(), blobRoot: nil, fileReader: reader)
    var candidate = item()
    candidate.payloads[0].inlineData = nil
    var configuration = settings()
    configuration.allowFiles = true
    do {
      _ = try await service.summarize(candidate, settings: configuration)
      XCTFail("Missing reference accepted")
    } catch { XCTAssertEqual(error as? DesktopServiceError, .fileUnavailable) }
    let calls = await reader.calls
    XCTAssertTrue(calls.isEmpty)
  }
  func testReaderResponseStillHasABoundAndRejectsBinaryText() async {
    for text in [
      String(repeating: "x", count: DesktopFileTextPolicy.maximumBytes + 1), "synthetic\0binary",
    ] {
      let service = DesktopAnalysis(
        credentials: InMemoryDesktopCredentials(), transport: FakeDesktopAITransport(),
        ocr: FakeDesktopOCR(), blobRoot: nil, fileReader: Reader(body: text))
      var configuration = settings()
      configuration.allowFiles = true
      do {
        _ = try await service.summarize(item(), settings: configuration)
        XCTFail("Invalid file response accepted")
      } catch {
        XCTAssertEqual(
          error as? DesktopServiceError, text.contains("\0") ? .invalidValue : .tooLarge)
      }
    }
  }
  @MainActor func testFileSettingsUpgradeAndLiveManualAutomaticPermissions() async throws {
    var value = DesktopSettings()
    let request = DesktopAnalysisScheduler.Request(id: item().id, remote: false, automatic: false)
    var candidate = item()
    candidate.id = request.id
    XCTAssertFalse(request.isAllowed(item: candidate, settings: value))
    value.localTextSummariesEnabled = true
    XCTAssertFalse(request.isAllowed(item: candidate, settings: value))
    value.localFileSummariesEnabled = true
    XCTAssertTrue(request.isAllowed(item: candidate, settings: value))
    let automatic = DesktopAnalysisScheduler.Request(
      id: candidate.id, remote: false, automatic: true)
    XCTAssertFalse(automatic.isAllowed(item: candidate, settings: value))
    value.automaticLocalFileSummaries = true
    XCTAssertTrue(automatic.isAllowed(item: candidate, settings: value))
    value.localFileSummariesEnabled = false
    XCTAssertFalse(automatic.isAllowed(item: candidate, settings: value))
    var legacy = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(value.ai)) as? [String: Any])
    legacy.removeValue(forKey: "allowFiles")
    let upgraded = try JSONDecoder().decode(
      DesktopAISettings.self, from: JSONSerialization.data(withJSONObject: legacy))
    XCTAssertFalse(upgraded.allowFiles)
    value.ai.allowFiles = true
    let restored = try JSONDecoder().decode(DesktopSettings.self, from: JSONEncoder().encode(value))
    XCTAssertEqual(restored, value)
    XCTAssertFalse(restored.ai.enabled)
  }
}
