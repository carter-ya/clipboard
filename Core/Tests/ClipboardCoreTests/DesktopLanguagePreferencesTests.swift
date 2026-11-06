import XCTest

@testable import ClipboardCore

final class DesktopLanguagePreferencesTests: XCTestCase {
  func testWindowsDisplayLanguageListOverridesEnglishFoundationFallback() {
    let buffer = Array("zh-CN\0en-US\0\0".utf16)
    let languages = DesktopLanguagePreferences.windowsPreferredLanguages(buffer: buffer)
    XCTAssertEqual(languages, ["zh-cn", "en-us"])
    XCTAssertEqual(
      DesktopUILanguage.resolve(override: nil, preferredLanguages: languages), .simplifiedChinese)
    XCTAssertEqual(
      DesktopStringCatalog.text("Preferences", language: nil, preferredLanguages: languages), "偏好设置"
    )
    XCTAssertEqual(
      DesktopUILanguage.resolve(override: "en", preferredLanguages: languages), .english)
  }

  func testWindowsMultiStringStopsAtTerminatorAndKeepsPriority() {
    XCTAssertEqual(
      DesktopLanguagePreferences.windowsPreferredLanguages(
        buffer: Array("zh-TW\0ja-JP\0zh-TW\0\0en-US\0".utf16)), ["zh-tw", "ja-jp"])
    XCTAssertEqual(DesktopLanguagePreferences.windowsPreferredLanguages(buffer: [0, 0]), [])
    XCTAssertEqual(DesktopLanguagePreferences.windowsPreferredLanguages(buffer: []), [])
    XCTAssertEqual(
      DesktopLanguagePreferences.windowsPreferredLanguages(buffer: Array("en-US".utf16)), [])
  }

  func testMessageLocalePrecedenceAndEncodingNormalization() {
    XCTAssertEqual(
      DesktopLanguagePreferences.linuxPreferredLanguages(
        environment: ["LC_ALL": "zh_TW.UTF-8", "LC_MESSAGES": "de_DE", "LANG": "en_US"],
        fallback: ["en"]), ["zh-tw"])
    XCTAssertEqual(
      DesktopLanguagePreferences.linuxPreferredLanguages(
        environment: ["LC_ALL": "", "LC_MESSAGES": "ko_KR.UTF-8", "LANG": "en_US"],
        fallback: ["en"]), ["ko-kr"])
    XCTAssertEqual(
      DesktopLanguagePreferences.linuxPreferredLanguages(
        environment: ["LANG": "de_DE.UTF-8@euro"], fallback: ["en"]), ["de-de"])
  }

  func testLanguagePriorityListOverridesMessageLocaleAndKeepsOrder() {
    XCTAssertEqual(
      DesktopLanguagePreferences.linuxPreferredLanguages(
        environment: ["LANG": "en_US.UTF-8", "LANGUAGE": "zh_TW:zh_Hant_HK:en_US.UTF-8:zh_TW"],
        fallback: ["en"]), ["zh-tw", "zh-hant-hk", "en-us"])
    XCTAssertEqual(
      DesktopLanguagePreferences.linuxPreferredLanguages(
        environment: ["LANG": "en_US.UTF-8", "LANGUAGE": "zh_CN:C:POSIX:C"],
        fallback: ["en"]), ["zh-cn", "en"])
  }

  func testCPOSIXLocaleKeepsEnglishDespiteLanguageList() {
    for locale in ["C", "POSIX", "C.UTF-8"] {
      XCTAssertEqual(
        DesktopLanguagePreferences.linuxPreferredLanguages(
          environment: ["LC_ALL": locale, "LANG": "zh_CN", "LANGUAGE": "zh_CN"],
          fallback: ["zh-CN"]), ["en"], locale)
    }
  }

  func testMissingOrMalformedPreferencesUseFoundationFallback() {
    XCTAssertEqual(
      DesktopLanguagePreferences.linuxPreferredLanguages(environment: [:], fallback: ["ja-JP"]),
      ["ja-JP"])
    XCTAssertEqual(
      DesktopLanguagePreferences.linuxPreferredLanguages(
        environment: ["LANG": "invalid/value", "LANGUAGE": ":"], fallback: ["en"]), ["en"])
    XCTAssertEqual(
      DesktopLanguagePreferences.linuxPreferredLanguages(
        environment: ["LANG": "--"], fallback: ["ja-JP"]), ["ja-JP"])
  }
}
