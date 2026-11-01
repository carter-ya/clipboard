import XCTest

@testable import ClipboardCore

final class DesktopAnalysisOptInTests: XCTestCase {
  func testExistingConfigurationRetainsTextBehaviorAndRoundTripsExplicitOptOut() throws {
    var settings = DesktopAISettings()
    settings.enabled = true
    settings.model = "fixture"
    var legacy = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
    legacy.removeValue(forKey: "allowText")
    let decoded = try JSONDecoder().decode(
      DesktopAISettings.self, from: JSONSerialization.data(withJSONObject: legacy))
    XCTAssertTrue(decoded.allowText)
    XCTAssertFalse(decoded.allowImages)
    settings.allowText = false
    let restored = try JSONDecoder().decode(
      DesktopAISettings.self, from: JSONEncoder().encode(settings))
    XCTAssertEqual(restored, settings)
    for malformed in ["false" as Any, NSNull()] {
      legacy["allowText"] = malformed
      XCTAssertThrowsError(
        try JSONDecoder().decode(
          DesktopAISettings.self, from: JSONSerialization.data(withJSONObject: legacy)))
    }
  }

  func testTextOptOutPrecedesBlobResolutionAndTransportWithoutBlockingImageOptIn() async throws {
    let transport = FakeDesktopAITransport()
    let ocr = FakeDesktopOCR()
    let service = DesktopAnalysis(
      credentials: InMemoryDesktopCredentials(), transport: transport, ocr: ocr, blobRoot: nil)
    var settings = DesktopAISettings()
    settings.enabled = true
    settings.model = "fixture"
    settings.allowText = false
    settings.allowImages = true
    for kind in [ClipKind.text, .rtf, .mixed, .file] {
      let candidate = ClipItem(
        createdAt: Date(), kind: kind, preview: "", sha256: "fixture", sizeBytes: 10,
        payloads: [.init(pasteboardType: "public.utf8-plain-text", blobPath: "missing.txt")])
      do {
        _ = try await service.summarize(candidate, settings: settings)
        XCTFail("Excluded content was resolved")
      } catch { XCTAssertEqual(error as? DesktopServiceError, .disabled) }
    }
    let image = ClipItem(
      createdAt: Date(), kind: .image, preview: "", sha256: "fixture", sizeBytes: 1,
      payloads: [.init(pasteboardType: "public.png", inlineData: Data([0]))])
    let result = try await service.summarize(image, settings: settings)
    XCTAssertEqual(result, "Fixture summary")
    let requests = await transport.requests
    XCTAssertEqual(requests.count, 1)
    // Text permission and remote image upload consent do not disable local OCR.
    settings.allowImages = false
    let recognized = try await service.recognize(image)
    XCTAssertEqual(recognized, "Synthetic OCR fixture")
  }

  @MainActor func testQueuedAndManualRemoteWorkRecheckPerKindPermission() {
    var settings = DesktopSettings()
    settings.ai.enabled = true
    settings.automaticSummaries = true
    for kind in [ClipKind.text, .rtf, .mixed] {
      let item = ClipItem(
        createdAt: Date(), kind: kind, preview: "", sha256: "fixture", sizeBytes: 0)
      for automatic in [true, false] {
        let request = DesktopAnalysisScheduler.Request(
          id: item.id, remote: true, automatic: automatic)
        settings.ai.allowText = true
        XCTAssertTrue(request.isAllowed(item: item, settings: settings))
        settings.ai.allowText = false
        XCTAssertFalse(request.isAllowed(item: item, settings: settings))
      }
    }
    let image = ClipItem(
      createdAt: Date(), kind: .image, preview: "", sha256: "fixture", sizeBytes: 0)
    let remote = DesktopAnalysisScheduler.Request(id: image.id, remote: true, automatic: true)
    XCTAssertFalse(remote.isAllowed(item: image, settings: settings))
    settings.ai.allowImages = true
    XCTAssertTrue(remote.isAllowed(item: image, settings: settings))
    settings.automaticOCR = true
    settings.ai.enabled = false
    XCTAssertTrue(
      DesktopAnalysisScheduler.Request(id: image.id, remote: false, automatic: true)
        .isAllowed(item: image, settings: settings))
  }
}
