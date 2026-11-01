import ClipboardCore
import Foundation
import XCTest

@testable import DesktopServices

final class NativeSystemLanguageTests: XCTestCase {
  #if os(Linux)
    func testSystemLanguagePriorityControlsLocalModelRequestsAndLabels() async throws {
      let flag = "CLIPBOARD_TEST_LOCAL_SYSTEM_LANGUAGE_CHILD"
      let receiptKey = "CLIPBOARD_TEST_LOCAL_SYSTEM_LANGUAGE_RECEIPT"
      if ProcessInfo.processInfo.environment[flag] == "1" {
        XCTAssertEqual(DesktopUILanguage.resolve(override: nil), .simplifiedChinese)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = root.appendingPathComponent("worker")
        let script = """
          #!/usr/bin/python3
          import json,sys
          assert len(sys.argv) == 1
          request=json.load(sys.stdin)
          assert request['language']=='Simplified Chinese'
          json.dump({'task':'summary','summary':'公开合成摘要。','language':None,'entities':[],'inputTruncated':False},sys.stdout)
          """
        try Data((script + "\n").utf8).write(to: worker)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: worker.path)
        let result = try await NativeDesktopLanguageModel(
          model: root.appendingPathComponent("synthetic.gguf"), executable: worker
        ).process(text: "Public synthetic system language fixture", task: .summary, language: nil)
        XCTAssertEqual(result.summary, "公开合成摘要。")
        let input = "Apple Inc. met officials."
        let output = try DesktopLocalLanguageOutput(
          task: .enrichment, languageCode: "en", entities: ["Apple Inc."])
        let rendered = try output.renderedText(for: input)
        XCTAssertEqual(rendered, "英语 · Apple Inc.")
        XCTAssertEqual(try output.renderedText(for: input, language: "en"), "English · Apple Inc.")
        guard result.summary == "公开合成摘要。", rendered == "英语 · Apple Inc." else { return }
        let receipt = try XCTUnwrap(ProcessInfo.processInfo.environment[receiptKey])
        try Data("passed".utf8).write(to: URL(fileURLWithPath: receipt), options: .atomic)
        return
      }
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      defer { try? FileManager.default.removeItem(at: root) }
      let receipt = root.appendingPathComponent("receipt")
      let process = Process()
      process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
      process.arguments = [
        "DesktopServicesTests.NativeSystemLanguageTests/testSystemLanguagePriorityControlsLocalModelRequestsAndLabels"
      ]
      var environment = ProcessInfo.processInfo.environment
      environment[flag] = "1"
      environment[receiptKey] = receipt.path
      environment["LANG"] = "en_US.UTF-8"
      environment["LC_ALL"] = "en_US.UTF-8"
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
      XCTAssertEqual(process.terminationStatus, 0, "The owned language-priority child must succeed")
      XCTAssertEqual(try? String(contentsOf: receipt, encoding: .utf8), "passed")
    }
  #endif
}
