import XCTest

@testable import ClipboardCore

final class DesktopImageClassificationTests: XCTestCase {
  private actor Classifier: DesktopImageClassifying {
    private(set) var inputs: [Data] = []
    func classify(_ image: Data) throws -> DesktopImageClassification {
      inputs.append(image)
      return try .init(width: 100, height: 50, labels: [.init(name: "dog", confidence: 0.8)])
    }
  }
  private struct UnavailableOCR: DesktopOCRRecognizing {
    func recognize(_ image: Data, language: String?) throws -> String {
      throw DesktopServiceError.unavailable
    }
  }
  private actor HeldOCR: DesktopOCRRecognizing {
    private var continuation: CheckedContinuation<String, Never>?
    private let signal: XCTestExpectation
    init(signal: XCTestExpectation) { self.signal = signal }
    func recognize(_ image: Data, language: String?) async -> String {
      await withCheckedContinuation {
        continuation = $0
        signal.fulfill()
      }
    }
    func finish() {
      continuation?.resume(returning: "")
      continuation = nil
    }
  }
  private func item() -> ClipItem {
    .init(
      createdAt: Date(), kind: .image, preview: "Synthetic image", sha256: "fixture", sizeBytes: 4,
      payloads: [.init(pasteboardType: "public.png", inlineData: Data([1, 2, 3, 4]))])
  }
  private func service(
    ocr: any DesktopOCRRecognizing, classifier: (any DesktopImageClassifying)? = nil
  ) -> DesktopAnalysis {
    .init(
      credentials: InMemoryDesktopCredentials(), transport: FakeDesktopAITransport(),
      ocr: ocr, blobRoot: nil, imageClassifier: classifier)
  }

  func testOCRWinsWithoutStartingTheClassifierAndOriginalImageIsUnchanged() async throws {
    let classifier = Classifier()
    let candidate = item()
    let result = try await service(
      ocr: FakeDesktopOCR(result: "  Recognized text  "), classifier: classifier
    )
    .summarizeImageLocally(candidate)
    XCTAssertEqual(result, .init(text: "Recognized text", source: .localOCR))
    let calls = await classifier.inputs
    XCTAssertTrue(calls.isEmpty)
    XCTAssertEqual(candidate.payloads.first?.inlineData, Data([1, 2, 3, 4]))
  }

  func testEmptyAndUnavailableOCRUseTheOfflineClassifierWithOriginalBytes() async throws {
    let classifier = Classifier()
    let candidate = item()
    for ocr: any DesktopOCRRecognizing in [FakeDesktopOCR(result: " \n"), UnavailableOCR()] {
      let result = try await service(ocr: ocr, classifier: classifier).summarizeImageLocally(
        candidate)
      XCTAssertEqual(result, .init(text: "dog", source: .localImage))
    }
    let inputs = await classifier.inputs
    XCTAssertEqual(inputs, [Data([1, 2, 3, 4]), Data([1, 2, 3, 4])])
    do {
      _ = try await service(ocr: FakeDesktopOCR(result: "")).summarizeImageLocally(candidate)
      XCTFail("Missing model capability succeeded")
    } catch { XCTAssertEqual(error as? DesktopServiceError, .unavailable) }
  }

  func testPrivateAndUnsupportedItemsFailBeforeEitherEngineOrPayloadResolution() async {
    let ocr = FakeDesktopOCR()
    let classifier = Classifier()
    let analyzer = service(ocr: ocr, classifier: classifier)
    var sensitive = item()
    sensitive.sensitive = true
    sensitive.payloads = [.init(pasteboardType: "public.png", blobPath: "must-not-resolve")]
    var concealed = item()
    concealed.payloads = [.init(pasteboardType: SensitivityFilter.concealedType)]
    for candidate in [sensitive, concealed] {
      do {
        _ = try await analyzer.summarizeImageLocally(candidate)
        XCTFail("Private image reached analysis")
      } catch { XCTAssertEqual(error as? DesktopServiceError, .sensitiveContent) }
    }
    var text = item()
    text.kind = .text
    do {
      _ = try await analyzer.summarizeImageLocally(text)
      XCTFail("Non-image analysis succeeded")
    } catch { XCTAssertEqual(error as? DesktopServiceError, .disabled) }
    let ocrCalls = await ocr.calls
    let classifierCalls = await classifier.inputs
    XCTAssertEqual(ocrCalls, 0)
    XCTAssertTrue(classifierCalls.isEmpty)
  }

  func testCancelledLateOCRCannotStartClassification() async {
    let started = expectation(description: "OCR is awaiting a result")
    let ocr = HeldOCR(signal: started)
    let classifier = Classifier()
    let analyzer = service(ocr: ocr, classifier: classifier)
    let candidate = item()
    let task = Task { try await analyzer.summarizeImageLocally(candidate) }
    await fulfillment(of: [started], timeout: 3)
    task.cancel()
    await ocr.finish()
    do {
      _ = try await task.value
      XCTFail("Cancelled image task succeeded")
    } catch { XCTAssertTrue(error is CancellationError) }
    let calls = await classifier.inputs
    XCTAssertTrue(calls.isEmpty)
  }

  func testResultConfidenceOrderingUniquenessAndDimensionsFallback() throws {
    let result = try DesktopImageClassification(
      width: 20, height: 10,
      labels: [
        .init(name: "animal", confidence: 0.1), .init(name: "dog", confidence: 0.8),
        .init(name: "dog", confidence: 0.11),
      ])
    XCTAssertEqual(result.summary, "dog, animal")
    XCTAssertEqual(
      try DesktopImageClassification(width: 20, height: 10, labels: []).summary, "Image (20×10)")
    XCTAssertEqual(
      try DesktopImageClassification(
        width: 20, height: 10, labels: [.init(name: "uncertain", confidence: 0.09)]
      ).summary,
      "Image (20×10)")
    let data = Data(
      "{\"width\":20,\"height\":10,\"labels\":[{\"name\":\"dog\",\"confidence\":0.8}]}".utf8)
    XCTAssertEqual(try DesktopImageClassification(workerOutput: data).summary, "dog")
  }

  func testWorkerMetadataRejectsInvalidGeometryNamesConfidenceAndBudgets() {
    XCTAssertThrowsError(try DesktopImageClassification(width: 0, height: 1, labels: []))
    XCTAssertThrowsError(try DesktopImageClassification(width: 32768, height: 32768, labels: []))
    for label in [
      DesktopImageClassification.Label(name: "bad\nname", confidence: 0.5),
      .init(name: String(repeating: "x", count: 129), confidence: 0.5),
      .init(name: "dog", confidence: .infinity), .init(name: "dog", confidence: -0.1),
    ] {
      XCTAssertThrowsError(try DesktopImageClassification(width: 1, height: 1, labels: [label]))
    }
    XCTAssertThrowsError(
      try DesktopImageClassification(
        width: 1, height: 1,
        labels: Array(repeating: .init(name: "dog", confidence: 0.5), count: 4)))
    XCTAssertThrowsError(
      try DesktopImageClassification(workerOutput: Data(repeating: 32, count: 4097)))
    XCTAssertThrowsError(try DesktopImageClassification(workerOutput: Data("{}".utf8)))
    XCTAssertThrowsError(try DesktopImageClassification(workerOutput: Data([255, 0])))
  }
}
