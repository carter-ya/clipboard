import XCTest

@testable import ClipboardCore

final class DesktopServicesTests: XCTestCase {
  private func item(sensitive: Bool = false, concealed: Bool = false, image: Bool = false)
    -> ClipItem
  {
    var payloads = [
      Payload(
        pasteboardType: image ? "public.png" : "public.utf8-plain-text",
        inlineData: Data("Synthetic fixture".utf8))
    ]
    if concealed {
      payloads.append(.init(pasteboardType: SensitivityFilter.concealedType, inlineData: Data()))
    }
    return .init(
      createdAt: Date(), kind: image ? .image : .text, preview: "", sha256: "fixture",
      sizeBytes: 17, sensitive: sensitive, payloads: payloads)
  }
  func testDisabledAndSensitiveContentNeverReachNetworkOrOCR() async throws {
    let transport = FakeDesktopAITransport()
    let ocr = FakeDesktopOCR()
    let service = DesktopAnalysis(
      credentials: InMemoryDesktopCredentials(), transport: transport, ocr: ocr, blobRoot: nil)
    var settings = DesktopAISettings()
    do {
      _ = try await service.summarize(item(), settings: settings)
      XCTFail("disabled request sent")
    } catch { XCTAssertEqual(error as? DesktopServiceError, .disabled) }
    settings.enabled = true
    settings.model = "fixture-model"
    for candidate in [item(sensitive: true, image: true), item(concealed: true, image: true)] {
      do {
        _ = try await service.summarize(candidate, settings: settings)
        XCTFail("sensitive request sent")
      } catch { XCTAssertEqual(error as? DesktopServiceError, .sensitiveContent) }
      do {
        _ = try await service.recognize(candidate)
        XCTFail("sensitive OCR ran")
      } catch { XCTAssertEqual(error as? DesktopServiceError, .sensitiveContent) }
    }
    let requests = await transport.requests
    let calls = await ocr.calls
    XCTAssertTrue(requests.isEmpty)
    XCTAssertEqual(calls, 0)
  }
  func testRemoteRequestUsesChosenModelAndCredentialWithoutPersistingItInSettings() async throws {
    let transport = FakeDesktopAITransport()
    let credentials = InMemoryDesktopCredentials()
    let service = DesktopAnalysis(
      credentials: credentials, transport: transport, ocr: FakeDesktopOCR(), blobRoot: nil)
    var settings = DesktopAISettings()
    settings.enabled = true
    settings.usesCredential = true
    settings.model = "fixture-model"
    try await credentials.save("synthetic-key", account: settings.credentialAccount)
    let summary = try await service.summarize(item(), settings: settings, language: "zh-Hans")
    XCTAssertEqual(summary, "Fixture summary")
    let requests = await transport.requests
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(
      requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-key")
    XCTAssertEqual(requests.first?.url?.path, "/v1/chat/completions")
    XCTAssertTrue(
      String(decoding: requests.first?.httpBody ?? Data(), as: UTF8.self).contains("fixture-model"))
    XCTAssertFalse(
      String(decoding: try JSONEncoder().encode(settings), as: UTF8.self).contains("synthetic-key"))
  }
  func testMissingRequiredCredentialFailsBeforeTransport() async throws {
    let transport = FakeDesktopAITransport()
    let service = DesktopAnalysis(
      credentials: InMemoryDesktopCredentials(), transport: transport, ocr: FakeDesktopOCR(),
      blobRoot: nil)
    var settings = DesktopAISettings()
    settings.enabled = true
    settings.usesCredential = true
    settings.model = "fixture"
    do {
      _ = try await service.summarize(item(), settings: settings)
      XCTFail("missing credential accepted")
    } catch { XCTAssertEqual(error as? DesktopServiceError, .unavailable) }
    let requests = await transport.requests
    XCTAssertTrue(requests.isEmpty)
  }
  func testImageUploadRequiresSeparateOptInAndHonorsResponseBound() async throws {
    let transport = FakeDesktopAITransport(
      response: .init(data: Data(repeating: 65, count: 65537), status: 200))
    let service = DesktopAnalysis(
      credentials: InMemoryDesktopCredentials(), transport: transport, ocr: FakeDesktopOCR(),
      blobRoot: nil)
    var settings = DesktopAISettings()
    settings.enabled = true
    settings.model = "fixture"
    do {
      _ = try await service.summarize(item(image: true), settings: settings)
      XCTFail("image upload not gated")
    } catch { XCTAssertEqual(error as? DesktopServiceError, .disabled) }
    settings.allowImages = true
    do {
      _ = try await service.summarize(item(image: true), settings: settings)
      XCTFail("oversized response accepted")
    } catch { XCTAssertEqual(error as? DesktopServiceError, .tooLarge) }
    let requests = await transport.requests
    XCTAssertEqual(requests.count, 1)
  }
  func testOCRRunsLocallyAndReturnsBoundedText() async throws {
    let ocr = FakeDesktopOCR(result: String(repeating: "x", count: 9000))
    let service = DesktopAnalysis(
      credentials: InMemoryDesktopCredentials(), transport: FakeDesktopAITransport(), ocr: ocr,
      blobRoot: nil)
    let text = try await service.recognize(item(image: true))
    XCTAssertEqual(text.count, 8000)
  }
  func testEndpointValidationRejectsEmbeddedSecretsAndPublicCleartext() throws {
    var settings = DesktopAISettings()
    settings.model = "fixture"
    for endpoint in [
      "https://name:password@example.com/v1", "https://example.com/v1?key=value",
      "https://example.com/v1#key", "http://example.com/v1",
    ] {
      settings.endpoint = endpoint
      XCTAssertThrowsError(try settings.validate())
    }
    settings.endpoint = "http://127.0.0.1:12345/v1"
    try settings.validate()
    settings.endpoint = "https://example.com/v1"
    let account = settings.credentialAccount
    settings.endpoint += "/"
    XCTAssertEqual(settings.credentialAccount, account)
  }
}
