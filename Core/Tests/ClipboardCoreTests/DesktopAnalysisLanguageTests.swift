import XCTest

@testable import ClipboardCore

final class DesktopAnalysisLanguageTests: XCTestCase {
  func testSystemAndRegionalTagsResolveToPromptLanguageNames() {
    for (tag, expected) in [
      ("zh_CN", "Simplified Chinese"), ("zh-hans", "Simplified Chinese"),
      ("zh-Hans-TW", "Simplified Chinese"),
      ("zh_TW", "Traditional Chinese"), ("zh-hant", "Traditional Chinese"),
      ("ja-JP", "Japanese"), ("ko_KR", "Korean"), ("de-DE", "German"),
      ("es-ES", "Spanish"), ("en-US", "English"),
    ] {
      XCTAssertEqual(
        DesktopAnalysis.responseLanguage(language: nil, preferredLanguages: [tag]), expected)
      XCTAssertEqual(
        DesktopAnalysis.responseLanguage(language: tag, preferredLanguages: ["en"]), expected)
    }
    XCTAssertEqual(
      DesktopAnalysis.responseLanguage(language: nil, preferredLanguages: []), "English")
  }
  func testRemoteTextAndImageRequestsUseChosenResponseLanguage() async throws {
    for (language, name) in [
      (nil, DesktopAnalysis.responseLanguage(language: nil)), ("zh-Hans", "Simplified Chinese"),
      ("zh-Hant", "Traditional Chinese"),
    ] {
      for image in [false, true] {
        let transport = FakeDesktopAITransport()
        let service = DesktopAnalysis(
          credentials: InMemoryDesktopCredentials(), transport: transport,
          ocr: FakeDesktopOCR(), blobRoot: nil)
        var settings = DesktopAISettings()
        settings.enabled = true
        settings.allowImages = true
        settings.model = "synthetic-language-fixture"
        let data = Data("Public synthetic language fixture".utf8)
        let item = ClipItem(
          createdAt: Date(), kind: image ? .image : .text, preview: "", sha256: "fixture",
          sizeBytes: data.count, sensitive: false,
          payloads: [
            .init(pasteboardType: image ? "public.png" : "public.utf8-plain-text", inlineData: data)
          ])
        _ = try await service.summarize(item, settings: settings, language: language)
        let requests = await transport.requests
        let body = try XCTUnwrap(requests.first?.httpBody)
        let actual = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages =
          image
          ? buildRemoteOpenAIImageMessages(
            data, mime: "image/png", responseLanguage: name)
          : buildRemoteOpenAITextMessages(
            String(decoding: data, as: UTF8.self), responseLanguage: name)
        let expected =
          try JSONSerialization.jsonObject(with: JSONEncoder().encode(messages)) as? NSArray
        XCTAssertEqual(actual["messages"] as? NSArray, expected)
      }
    }
  }
}
