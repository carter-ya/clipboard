import XCTest

@testable import ClipboardCore

final class DesktopLocalTextSummaryTests: XCTestCase {
  func testLeadSentenceAndUnicodeBoundariesHaveStrictOutputBudgets() throws {
    let lead = "The synthetic project completed its native platform checks."
    XCTAssertEqual(
      DesktopLocalTextSummary.summarize(lead + String(repeating: " More context.", count: 20)), lead
    )
    let chinese = "这是一个只在本地处理的合成文本摘录测试，用于确认中文句子的边界。"
    XCTAssertEqual(
      DesktopLocalTextSummary.summarize(chinese + String(repeating: "后续合成内容。", count: 40)), chinese)
    XCTAssertNil(DesktopLocalTextSummary.summarize("Short synthetic text"))
    XCTAssertNil(DesktopLocalTextSummary.summarize(String(repeating: "\0", count: 200)))
    for input in [
      String(repeating: "😀中文e\u{301}", count: 10000),
      String(repeating: "a" + String(repeating: "\u{301}", count: 200), count: 200),
    ] {
      let summary = try XCTUnwrap(DesktopLocalTextSummary.summarize(input))
      XCTAssertLessThanOrEqual(summary.count, 200)
      XCTAssertLessThanOrEqual(summary.utf8.count, 2048)
      XCTAssertFalse(summary.contains("\u{FFFD}"))
    }
  }

  func testLocalTextAndRichTextNeverUseCredentialsTransportOrOCR() async throws {
    let transport = FakeDesktopAITransport()
    let ocr = FakeDesktopOCR()
    let service = DesktopAnalysis(
      credentials: InMemoryDesktopCredentials(), transport: transport,
      ocr: ocr, blobRoot: nil)
    let text =
      "This synthetic sentence is a useful local excerpt. "
      + String(repeating: "Additional context. ", count: 20)
    for (kind, type, body) in [
      (ClipKind.text, "public.utf8-plain-text", text),
      (.rtf, "public.html", "<p>" + text + "</p><script>ignored</script>"),
    ] {
      let item = ClipItem(
        createdAt: Date(), kind: kind, preview: "", sha256: "fixture", sizeBytes: body.utf8.count,
        payloads: [.init(pasteboardType: type, inlineData: Data(body.utf8))])
      let result = try await service.summarizeLocally(item)
      XCTAssertEqual(result, "This synthetic sentence is a useful local excerpt.")
    }
    let requests = await transport.requests
    let calls = await ocr.calls
    XCTAssertTrue(requests.isEmpty)
    XCTAssertEqual(calls, 0)
  }

  func testSensitiveConcealedAndUnsupportedItemsFailBeforeResolution() async {
    let service = DesktopAnalysis(
      credentials: InMemoryDesktopCredentials(), transport: FakeDesktopAITransport(),
      ocr: FakeDesktopOCR(), blobRoot: nil)
    for concealed in [false, true] {
      var item = ClipItem(
        createdAt: Date(), kind: .text, preview: "", sha256: "fixture", sizeBytes: 1,
        sensitive: !concealed,
        payloads: [.init(pasteboardType: "public.utf8-plain-text", blobPath: "missing.txt")])
      if concealed {
        item.payloads.append(
          .init(pasteboardType: SensitivityFilter.concealedType, inlineData: Data()))
      }
      do {
        _ = try await service.summarizeLocally(item)
        XCTFail("Private content was resolved")
      } catch { XCTAssertEqual(error as? DesktopServiceError, .sensitiveContent) }
    }
    for kind in [ClipKind.image, .file] {
      let item = ClipItem(
        createdAt: Date(), kind: kind, preview: "", sha256: "fixture", sizeBytes: 1)
      do {
        _ = try await service.summarizeLocally(item)
        XCTFail("Unsupported content accepted")
      } catch { XCTAssertEqual(error as? DesktopServiceError, .disabled) }
    }
  }

  @MainActor func testManualAndAutomaticLocalPermissionAreIndependentOfRemoteAI() async throws {
    var settings = try JSONDecoder().decode(DesktopSettings.self, from: Data("{}".utf8))
    XCTAssertFalse(settings.localTextSummariesEnabled)
    XCTAssertFalse(settings.automaticLocalSummaries)
    let item = ClipItem(
      createdAt: Date(), kind: .text, preview: "", sha256: "fixture", sizeBytes: 0)
    let manual = DesktopAnalysisScheduler.Request(id: item.id, remote: false, automatic: false)
    let automatic = DesktopAnalysisScheduler.Request(id: item.id, remote: false, automatic: true)
    XCTAssertFalse(manual.isAllowed(item: item, settings: settings))
    settings.localTextSummariesEnabled = true
    XCTAssertTrue(manual.isAllowed(item: item, settings: settings))
    XCTAssertFalse(automatic.isAllowed(item: item, settings: settings))
    settings.automaticLocalSummaries = true
    XCTAssertTrue(automatic.isAllowed(item: item, settings: settings))
    XCTAssertFalse(settings.ai.enabled)
    let restored = try JSONDecoder().decode(
      DesktopSettings.self, from: JSONEncoder().encode(settings))
    XCTAssertEqual(restored, settings)
    settings.localTextSummariesEnabled = false
    XCTAssertFalse(automatic.isAllowed(item: item, settings: settings))
  }
}
