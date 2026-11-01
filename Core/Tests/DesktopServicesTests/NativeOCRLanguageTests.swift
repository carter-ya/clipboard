import Foundation
import XCTest

@testable import DesktopServices

final class NativeOCRLanguageTests: XCTestCase {
  func testSystemChineseRequestsEnglishAndChinesePacks() {
    for preferred in ["zh-CN", "zh-Hans", "zh_TW", "ZH-HK"] {
      XCTAssertEqual(
        NativeDesktopOCR.linuxLanguages(language: nil, preferredLanguages: [preferred]),
        "eng+chi_sim", preferred)
    }
  }

  func testExplicitLanguageTakesPrecedenceAndMissingLocaleUsesEnglish() {
    XCTAssertEqual(
      NativeDesktopOCR.linuxLanguages(language: "en", preferredLanguages: ["zh-CN"]), "eng")
    XCTAssertEqual(
      NativeDesktopOCR.linuxLanguages(language: "zh-Hant", preferredLanguages: ["en-US"]),
      "eng+chi_sim")
    XCTAssertEqual(NativeDesktopOCR.linuxLanguages(language: nil, preferredLanguages: []), "eng")
    XCTAssertEqual(
      NativeDesktopOCR.linuxLanguages(language: nil, preferredLanguages: ["de-DE"]), "eng")
  }

  #if os(Linux)
    func testNativeSystemChineseOCR() async throws {
      let childFlag = "CLIPBOARD_TEST_SYSTEM_OCR_CHILD"
      let receiptKey = "CLIPBOARD_TEST_SYSTEM_OCR_RECEIPT"
      if ProcessInfo.processInfo.environment[childFlag] == "1" {
        let selected = NativeDesktopOCR.linuxLanguages(language: nil)
        XCTAssertEqual(selected, "eng+chi_sim")
        let imageURL = try XCTUnwrap(
          Bundle.module.url(
            forResource: "system-chinese", withExtension: "png", subdirectory: "Fixtures"))
        let recognized = try await NativeDesktopOCR().recognize(Data(contentsOf: imageURL))
        let containsChinese = recognized.filter { !$0.isWhitespace }.contains("中文")
        XCTAssertTrue(containsChinese, "The fixed public Chinese fixture must be recognized")
        guard selected == "eng+chi_sim", containsChinese else { return }
        let receipt = try XCTUnwrap(ProcessInfo.processInfo.environment[receiptKey])
        try Data("passed".utf8).write(to: URL(fileURLWithPath: receipt), options: .atomic)
        return
      }
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "clipboard-system-ocr-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      defer { try? FileManager.default.removeItem(at: root) }
      let receipt = root.appendingPathComponent("receipt")
      let process = Process()
      process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
      process.arguments = [
        "DesktopServicesTests.NativeOCRLanguageTests/testNativeSystemChineseOCR"
      ]
      var environment = ProcessInfo.processInfo.environment
      environment[childFlag] = "1"
      environment[receiptKey] = receipt.path
      environment["LANG"] = "zh_CN.UTF-8"
      environment["LC_ALL"] = "zh_CN.UTF-8"
      environment["LANGUAGE"] = "zh_CN:zh"
      process.environment = environment
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try process.run()
      let deadline = DispatchSource.makeTimerSource(queue: .global())
      deadline.schedule(deadline: .now() + 15)
      deadline.setEventHandler { if process.isRunning { process.terminate() } }
      deadline.resume()
      defer { deadline.cancel() }
      process.waitUntilExit()
      XCTAssertEqual(process.terminationStatus, 0, "The owned native OCR child must succeed")
      // An empty test selection can exit zero; require proof the native case ran.
      XCTAssertEqual(try? String(contentsOf: receipt, encoding: .utf8), "passed")
    }
  #endif
}
