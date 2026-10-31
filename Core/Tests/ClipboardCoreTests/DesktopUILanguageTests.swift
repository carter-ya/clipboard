import XCTest

@testable import ClipboardCore

final class DesktopUILanguageTests: XCTestCase {
  func testSystemMatchingDistinguishesChineseScriptAndRegion() {
    for tag in ["zh-TW", "zh_HK", "ZH-mo", "zh-Hant-CN"] {
      XCTAssertEqual(DesktopUILanguage.resolve(override: tag), .traditionalChinese)
    }
    for tag in ["zh", "zh-CN", "zh-SG", "zh-Hans-TW"] {
      XCTAssertEqual(DesktopUILanguage.resolve(override: tag), .simplifiedChinese)
    }
    XCTAssertEqual(
      DesktopUILanguage.resolve(override: nil, preferredLanguages: ["fr-FR", "ja-JP"]), .japanese)
    XCTAssertEqual(DesktopUILanguage.resolve(override: "de", preferredLanguages: ["ja"]), .german)
    XCTAssertEqual(
      DesktopUILanguage.resolve(override: "unsupported", preferredLanguages: ["ja"]), .english)
    XCTAssertEqual(DesktopUILanguage.resolve(override: nil, preferredLanguages: []), .english)
  }

  func testAllSevenCatalogsContainEveryMessageAndKeepFormatArguments() throws {
    let keys = try XCTUnwrap(DesktopStringCatalog.tables["en"])
    XCTAssertGreaterThan(keys.count, 130)
    XCTAssertEqual(DesktopStringCatalog.tables.count, 7)
    for language in DesktopUILanguage.allCases {
      let table = try XCTUnwrap(DesktopStringCatalog.tables[language.rawValue])
      XCTAssertEqual(Set(table.keys), Set(keys.keys), language.rawValue)
      for (key, value) in table {
        XCTAssertFalse(value.isEmpty, key)
        for placeholder in ["{count}", "{added}", "{skipped}", "{bytes}", "{missing}"] {
          XCTAssertEqual(
            key.contains(placeholder), value.contains(placeholder), "\(language): \(key)")
        }
      }
    }
    XCTAssertEqual(Set(DesktopUILanguage.allCases.map(\.shellIndex)), Set(0...6))
  }

  func testLocalizedCountsImportsAndUnknownText() {
    XCTAssertEqual(DesktopStringCatalog.text("42 items", language: "zh-Hant"), "42 條")
    XCTAssertEqual(DesktopStringCatalog.text("Image · 2048 bytes", language: "ko"), "이미지 · 2048바이트")
    XCTAssertEqual(
      DesktopStringCatalog.text("Imported 2 items; 3 duplicates skipped.", language: "ja"),
      "2 件を読み込み、重複する 3 件をスキップしました。")
    XCTAssertEqual(
      DesktopStringCatalog.text(
        "Imported 2 items; 3 skipped; 4 missing blobs.", language: "zh-Hans"),
      "已导入 2 项；跳过 3 项；缺失文件 4 项。")
    XCTAssertEqual(
      DesktopStringCatalog.text("synthetic original clipboard text", language: "ko"),
      "synthetic original clipboard text")
    XCTAssertEqual(
      DesktopStringCatalog.text("Preferences", language: nil, preferredLanguages: ["es-MX"]),
      "Preferencias")
    XCTAssertEqual(DesktopStringCatalog.text("Preferences", language: "zh-TW"), "偏好設定")
    XCTAssertEqual(DesktopStringCatalog.text("Start recording", language: "zh-TW"), "開始錄製")
    XCTAssertNotEqual(
      DesktopStringCatalog.text("Preferences", language: "zh-TW"),
      DesktopStringCatalog.text("Preferences", language: "zh-CN"))
  }
}
