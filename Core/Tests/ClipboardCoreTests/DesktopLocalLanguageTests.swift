import XCTest

@testable import ClipboardCore

final class DesktopLocalLanguageTests: XCTestCase {
  private actor Reader: DesktopFileTextReading {
    private(set) var calls: [URL] = []
    func text(from file: URL, maxBytes: Int) -> String {
      calls.append(file)
      return String(repeating: "Synthetic file body. ", count: 4000)
    }
  }
  private actor Processor: DesktopLocalLanguageProcessing {
    private(set) var inputs: [String] = []
    private let output: DesktopLocalLanguageOutput
    init(_ output: DesktopLocalLanguageOutput) { self.output = output }
    func process(text: String, task: DesktopLocalLanguageTask, language: String?) throws
      -> DesktopLocalLanguageOutput
    {
      inputs.append(text)
      return output
    }
  }
  private func item(_ text: String = "Hello") -> ClipItem {
    let bytes = Data(text.utf8)
    return .init(
      createdAt: Date(), kind: .text, preview: text, sha256: "fixture", sizeBytes: bytes.count,
      payloads: [.init(pasteboardType: "public.utf8-plain-text", inlineData: bytes)])
  }
  private func service(_ processor: (any DesktopLocalLanguageProcessing)? = nil) -> DesktopAnalysis
  {
    .init(
      credentials: InMemoryDesktopCredentials(), transport: FakeDesktopAITransport(),
      ocr: FakeDesktopOCR(), blobRoot: nil, localLanguage: processor)
  }

  func testGenerativeAnalysisAcceptsShortTextAndPreservesOriginalPayload() async throws {
    let processor = Processor(try .init(task: .summary, summary: "A localized generated summary."))
    let original = item()
    let result = try await service(processor).analyzeLanguageLocally(original, task: .summary)
    XCTAssertEqual(result.text, "A localized generated summary.")
    XCTAssertEqual(result.task, .summary)
    XCTAssertFalse(result.inputTruncated)
    let inputs = await processor.inputs
    XCTAssertEqual(inputs, ["Hello"])
    XCTAssertEqual(original.payloads[0].inlineData, Data("Hello".utf8))
    do {
      _ = try await service(processor).analyzeLanguageLocally(original, task: .enrichment)
      XCTFail("Baseline enrichment ignored its minimum text length")
    } catch { XCTAssertEqual(error as? DesktopServiceError, .invalidValue) }
  }

  func testPrivateItemsFailBeforeMissingPayloadOrModelResolution() async throws {
    var missing = item()
    missing.payloads = [.init(pasteboardType: "public.utf8-plain-text", blobPath: "must-not-read")]
    var sensitive = missing
    sensitive.sensitive = true
    var concealed = missing
    concealed.payloads.append(.init(pasteboardType: SensitivityFilter.concealedType))
    for candidate in [sensitive, concealed] {
      for task in [DesktopLocalLanguageTask.summary, .enrichment] {
        do {
          _ = try await service().analyzeLanguageLocally(candidate, task: task)
          XCTFail("Private item reached model or payload resolution")
        } catch { XCTAssertEqual(error as? DesktopServiceError, .sensitiveContent) }
      }
    }
    do {
      _ = try await service().analyzeLanguageLocally(missing, task: .summary)
      XCTFail("Missing local capability reached a payload read")
    } catch { XCTAssertEqual(error as? DesktopServiceError, .unavailable) }
    var image = missing
    image.kind = .image
    do {
      _ = try await service().analyzeLanguageLocally(image, task: .summary)
      XCTFail("Language worker accepted an image")
    } catch { XCTAssertEqual(error as? DesktopServiceError, .disabled) }
  }

  func testBoundedUnicodeInputReportsTruncationWithoutChangingTheItem() async throws {
    let processor = Processor(try .init(task: .summary, summary: "A bounded summary."))
    let body = String(repeating: "中文🙂", count: 10_000)
    let original = item(body)
    let result = try await service(processor).analyzeLanguageLocally(original, task: .summary)
    XCTAssertTrue(result.inputTruncated)
    let inputs = await processor.inputs
    XCTAssertEqual(inputs.count, 1)
    XCTAssertLessThanOrEqual(inputs[0].utf8.count, 65536)
    XCTAssertFalse(inputs[0].contains("\u{FFFD}"))
    XCTAssertEqual(original.payloads[0].inlineData, Data(body.utf8))
  }

  func testCopiedFileUsesOnlyFirstBodyAndPrivateFilesNeverReachTheReader() async throws {
    let reader = Reader()
    let processor = Processor(try .init(task: .summary, summary: "A generated file summary."))
    let transport = FakeDesktopAITransport()
    let analyzer = DesktopAnalysis(
      credentials: InMemoryDesktopCredentials(), transport: transport, ocr: FakeDesktopOCR(),
      blobRoot: nil, fileReader: reader, localLanguage: processor)
    let first = URL(fileURLWithPath: "/synthetic/private-name.pdf")
    var original = item()
    original.kind = .file
    original.payloads = [
      .init(
        pasteboardType: "public.file-url",
        inlineData: ClipboardFormats.fileURLData([
          first, URL(fileURLWithPath: "/synthetic/second.txt"),
        ]))
    ]
    for concealed in [false, true] {
      var candidate = original
      candidate.sensitive = !concealed
      if concealed {
        candidate.payloads.append(.init(pasteboardType: SensitivityFilter.concealedType))
      }
      do {
        _ = try await analyzer.analyzeLanguageLocally(candidate, task: .summary)
        XCTFail("Private file reached the local reader")
      } catch { XCTAssertEqual(error as? DesktopServiceError, .sensitiveContent) }
    }
    let before = await reader.calls
    XCTAssertTrue(before.isEmpty)
    let result = try await analyzer.analyzeLanguageLocally(original, task: .summary)
    XCTAssertTrue(result.inputTruncated)
    XCTAssertEqual(result.text, "A generated file summary.")
    let calls = await reader.calls
    let inputs = await processor.inputs
    let requests = await transport.requests
    XCTAssertEqual(calls, [first])
    XCTAssertEqual(inputs.count, 1)
    XCTAssertLessThanOrEqual(inputs[0].utf8.count, 65536)
    XCTAssertFalse(inputs[0].contains("private-name"))
    XCTAssertFalse(inputs[0].contains("second.txt"))
    XCTAssertTrue(requests.isEmpty)
    XCTAssertEqual(original.payloads.count, 1)
  }

  func testEnrichmentKeepsOnlyOriginalEntitySpellingAndLocalizesLanguage() throws {
    let input =
      "Apple Inc. and Tim Cook announced plans in Tokyo. "
      + String(repeating: "Context. ", count: 15)
    let output = try DesktopLocalLanguageOutput(
      task: .enrichment, languageCode: "en",
      entities: ["Apple Inc.", "tim cook", "Imaginary City", "Tokyo", "TIM COOK"])
    XCTAssertEqual(
      try output.renderedText(for: input, language: "en"), "English · Apple Inc., Tim Cook, Tokyo")
    let fallback = try DesktopLocalLanguageOutput(task: .enrichment, languageCode: "und")
    XCTAssertTrue(try fallback.renderedText(for: input).hasPrefix("Apple Inc."))
  }

  func testMalformedWorkerMetadataAndReasoningOnlyResponsesAreRefused() throws {
    for data in [Data(), Data(repeating: 32, count: 4097)] {
      XCTAssertThrowsError(try DesktopLocalLanguageOutput(workerOutput: data))
    }
    for json in [
      "{}", "{\"task\":\"remote\"}",
      "{\"task\":\"summary\",\"summary\":\"OK\",\"entities\":[],\"inputTruncated\":\"true\"}",
    ] {
      XCTAssertThrowsError(try DesktopLocalLanguageOutput(workerOutput: Data(json.utf8)))
    }
    XCTAssertThrowsError(
      try DesktopLocalLanguageOutput(task: .summary, summary: "<think>Only reasoning</think>"))
    XCTAssertThrowsError(try DesktopLocalLanguageOutput(task: .summary, summary: "Unsafe\0value"))
    XCTAssertThrowsError(try DesktopLocalLanguageOutput(task: .enrichment, languageCode: "English"))
    XCTAssertThrowsError(
      try DesktopLocalLanguageOutput(
        task: .enrichment, entities: Array(repeating: "Name", count: 6)))
    let bounded = try DesktopLocalLanguageOutput(
      task: .summary, summary: String(repeating: "🙂", count: 300))
    XCTAssertEqual(bounded.summary?.count, 200)
    XCTAssertLessThanOrEqual(bounded.summary?.utf8.count ?? 0, 2048)
  }

  func testDifferentTaskResultIsRejectedAndCancelledWorkNeverEntersTheProcessor() async throws {
    let wrong = Processor(try .init(task: .enrichment, languageCode: "en"))
    do {
      _ = try await service(wrong).analyzeLanguageLocally(item(), task: .summary)
      XCTFail("Worker task mismatch succeeded")
    } catch { XCTAssertEqual(error as? DesktopServiceError, .invalidValue) }
    let processor = Processor(try .init(task: .summary, summary: "Must not be used"))
    let analyzer = service(processor)
    let candidate = item()
    let task = Task {
      while !Task.isCancelled { await Task.yield() }
      return try await analyzer.analyzeLanguageLocally(candidate, task: .summary)
    }
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Cancelled work succeeded")
    } catch is CancellationError {}
    let calls = await processor.inputs
    XCTAssertTrue(calls.isEmpty)
  }
}
