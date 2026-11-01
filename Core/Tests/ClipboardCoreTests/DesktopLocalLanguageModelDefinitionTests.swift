import XCTest

@testable import ClipboardCore

final class DesktopLocalLanguageModelDefinitionTests: XCTestCase {
  func testBundledModelUsesImmutablePublicMetadataAndNoCredentials() throws {
    let definition = try DesktopLocalLanguageModelDefinition.bundled()
    try definition.validate()
    XCTAssertNil(definition.url.user)
    XCTAssertNil(definition.url.password)
    XCTAssertNil(definition.url.query)
    XCTAssertEqual(definition.url.scheme, "https")
    XCTAssertEqual(definition.sha256.count, 64)
    XCTAssertGreaterThan(definition.size, 100 * 1024 * 1024)
    XCTAssertEqual(definition.license, "Apache-2.0")
  }

  func testMovingRevisionsExternalURLsTraversalAndUnboundedFilesAreRefused() throws {
    let valid: [String: Any] = [
      "id": "synthetic-model", "repository": "fixture/model",
      "revision": String(repeating: "a", count: 40),
      "filename": "model.gguf",
      "url":
        "https://huggingface.co/fixture/model/resolve/\(String(repeating: "a", count: 40))/model.gguf",
      "sha256": String(repeating: "b", count: 64), "size": 1, "license": "Apache-2.0",
      "licenseURL":
        "https://huggingface.co/fixture/model/resolve/\(String(repeating: "a", count: 40))/LICENSE",
      "cardURL":
        "https://huggingface.co/fixture/model/blob/\(String(repeating: "a", count: 40))/README.md",
    ]
    XCTAssertNoThrow(
      try DesktopLocalLanguageModelDefinition.decode(JSONSerialization.data(withJSONObject: valid)))
    var standardLicense = valid
    standardLicense["licenseURL"] = "https://www.apache.org/licenses/LICENSE-2.0.txt"
    XCTAssertNoThrow(
      try DesktopLocalLanguageModelDefinition.decode(
        JSONSerialization.data(withJSONObject: standardLicense)))
    let mutations: [(String, Any)] = [
      ("revision", "main"), ("repository", "fixture/../model"), ("filename", "../model.gguf"),
      ("url", "http://127.0.0.1/model.gguf"),
      ("url", "https://huggingface.co.evil.invalid/model.gguf"),
      ("sha256", "not-a-digest"), ("size", -1), ("size", Int64(9) * 1024 * 1024 * 1024),
      ("licenseURL", "https://example.invalid/license"),
    ]
    for (key, value) in mutations {
      var changed = valid
      changed[key] = value
      let data = try JSONSerialization.data(withJSONObject: changed)
      XCTAssertThrowsError(
        try DesktopLocalLanguageModelDefinition.decode(data))
      XCTAssertThrowsError(
        try JSONDecoder().decode(DesktopLocalLanguageModelDefinition.self, from: data))
    }
    XCTAssertThrowsError(
      try DesktopLocalLanguageModelDefinition.decode(Data(repeating: 32, count: 4097)))
  }
}
