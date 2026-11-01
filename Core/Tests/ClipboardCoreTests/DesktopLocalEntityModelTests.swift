import XCTest

@testable import ClipboardCore

final class DesktopLocalEntityModelTests: XCTestCase {
  func testFixedEntityAssetKeepsLicenseAcceptanceAndImmutablePublicURLs() throws {
    let definition = try DesktopLocalEntityModelDefinition.bundled()
    try definition.validate()
    XCTAssertTrue(definition.licenseAcceptanceRequired)
    XCTAssertEqual(definition.license, "AFL-3.0")
    XCTAssertEqual(definition.size, 178_451_275)
    XCTAssertNil(definition.url.user)
    XCTAssertNil(definition.url.password)
    XCTAssertNil(definition.url.query)
  }

  func testEntityMetadataCannotRemoveAcceptanceOrChangeTheTrustBoundary() throws {
    let definition = try DesktopLocalEntityModelDefinition.bundled()
    let valid: [String: Any] = [
      "id": definition.id, "repository": definition.repository, "revision": definition.revision,
      "filename": definition.filename, "url": definition.url.absoluteString,
      "sha256": definition.sha256, "size": definition.size, "license": definition.license,
      "licenseURL": definition.licenseURL.absoluteString,
      "cardURL": definition.cardURL.absoluteString,
      "licenseAcceptanceRequired": true,
    ]
    XCTAssertNoThrow(
      try DesktopLocalEntityModelDefinition.decode(JSONSerialization.data(withJSONObject: valid)))
    for (key, value) in [
      ("licenseAcceptanceRequired", false as Any), ("revision", "main"),
      ("filename", "../model.onnx"), ("url", "http://127.0.0.1/model.onnx"),
      ("license", "Apache-2.0"), ("licenseURL", "https://example.invalid/license"),
      ("size", -1), ("size", Int64(3) * 1024 * 1024 * 1024),
    ] {
      var changed = valid
      changed[key] = value
      let data = try JSONSerialization.data(withJSONObject: changed)
      XCTAssertThrowsError(try DesktopLocalEntityModelDefinition.decode(data))
      XCTAssertThrowsError(
        try JSONDecoder().decode(DesktopLocalEntityModelDefinition.self, from: data))
    }
  }

  func testChineseScriptIdentifiersAndSystemDisplayLocaleRemainAccurate() throws {
    for script in ["zh-Hans", "zh-Hant"] {
      let output = try DesktopLocalLanguageOutput(
        task: .enrichment, languageCode: script, entities: ["北京"])
      let name = try XCTUnwrap(Locale(identifier: "en").localizedString(forLanguageCode: script))
      XCTAssertEqual(try output.renderedText(for: "北京", language: "en"), name + " · 北京")
      XCTAssertEqual(
        try output.renderedText(for: "北京", language: "system"), try output.renderedText(for: "北京"))
    }
    for invalid in ["zh-hant", "zh-CN", "zh-Hant\n", "en-US", "english"] {
      XCTAssertThrowsError(try DesktopLocalLanguageOutput(task: .enrichment, languageCode: invalid))
    }
  }
}
