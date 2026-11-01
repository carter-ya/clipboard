import ClipboardCore
import Foundation
import XCTest

@testable import DesktopServices

final class NativeLanguageProcessTests: XCTestCase {
  func testRealPinnedWorkerThroughTheSwiftAdapterWhenExplicitlyConfigured() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let worker = environment["CLIPBOARD_TEST_LANGUAGE_WORKER"],
      let model = environment["CLIPBOARD_TEST_LANGUAGE_MODEL"]
    else { throw XCTSkip("Explicit native model fixture is not configured") }
    let processor = NativeDesktopLanguageModel(
      model: URL(fileURLWithPath: model), executable: URL(fileURLWithPath: worker))
    let text =
      "The project team met on Tuesday to review schedules and paperwork. "
      + "After inspecting a damaged fuel valve, NASA engineers postponed the Mars launch "
      + "until Friday to complete repairs and safety checks."
    let result = try await processor.process(text: text, task: .summary, language: "en")
    XCTAssertEqual(result.task, .summary)
    XCTAssertFalse(result.inputTruncated)
    let summary = try result.renderedText(for: text).lowercased()
    XCTAssertTrue(summary.contains("nasa"))
    XCTAssertTrue(summary.contains("mars"))
    XCTAssertTrue(summary.contains("postpon") || summary.contains("delay"))
    XCTAssertFalse(summary.hasPrefix("the project team met"))
  }

  #if os(Linux)
    private func fixture(_ body: String) throws -> URL {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "private-language-process-" + UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      addTeardownBlock { try? FileManager.default.removeItem(at: root) }
      let file = root.appendingPathComponent("worker")
      try Data(("#!/usr/bin/python3\n" + body + "\n").utf8).write(to: file)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
      return file
    }

    func testUnsupportedCPUIsUnavailableWithoutMaskingOtherWorkerFailures() async throws {
      for (code, expected) in [
        (11, DesktopServiceError.unavailable), (3, .unavailable), (2, .invalidValue),
      ] {
        let file = try fixture("import sys\nsys.stdin.buffer.read()\nsys.exit(\(code))")
        do {
          _ = try await NativeDesktopLanguageModel(
            model: URL(fileURLWithPath: "/tmp/synthetic.gguf"), executable: file
          ).process(text: "Synthetic", task: .summary, language: "en")
          XCTFail("Failed worker succeeded")
        } catch { XCTAssertEqual(error as? DesktopServiceError, expected) }
        if code == 11 {
          do {
            _ = try await NativeDesktopByteWorker(
              executable: file, timeout: 2, inputLimit: 1024, outputLimit: 1024
            ).run(Data("{}".utf8))
            XCTFail("Generic worker accepted an unexpected exit")
          } catch { XCTAssertEqual(error as? DesktopServiceError, .invalidValue) }
        }
      }
    }

    func testUnicodeModelAndTextUsePrivateJSONPipesAndWrongTaskIsRefused() async throws {
      let file = try fixture(
        """
        import json,sys
        assert len(sys.argv) == 1
        value = json.load(sys.stdin)
        assert value == {'model': '/tmp/private 日本語 model.gguf', 'text': '合成🙂text', 'task': 'summary', 'language': 'Japanese'}
        json.dump({'task':'summary','summary':'合成の要約。','language':None,'entities':[],'inputTruncated':False},sys.stdout)
        """)
      let result = try await NativeDesktopLanguageModel(
        model: URL(fileURLWithPath: "/tmp/private 日本語 model.gguf"), executable: file
      ).process(text: "合成🙂text", task: .summary, language: "ja")
      XCTAssertEqual(result.summary, "合成の要約。")
      let wrong = try fixture(
        """
        import json,sys
        json.load(sys.stdin)
        json.dump({'task':'enrichment','language':'en','entities':[],'inputTruncated':False},sys.stdout)
        """)
      do {
        _ = try await NativeDesktopLanguageModel(
          model: URL(fileURLWithPath: "/tmp/synthetic.gguf"), executable: wrong
        ).process(text: "Synthetic", task: .summary, language: "en")
        XCTFail("Different task response was accepted")
      } catch { XCTAssertEqual(error as? DesktopServiceError, .invalidValue) }
    }

    func testUnavailableModelCapabilityAndInvalidInputFailWithoutWorkerLaunch() async throws {
      let missing = URL(fileURLWithPath: "/tmp/private-language-missing-" + UUID().uuidString)
      let processor = NativeDesktopLanguageModel(model: missing, executable: missing)
      do {
        _ = try await processor.process(text: "Synthetic", task: .enrichment, language: "en")
        XCTFail("Generative worker accepted the dedicated NLP task")
      } catch { XCTAssertEqual(error as? DesktopServiceError, .disabled) }
      do {
        _ = try await processor.process(text: "", task: .summary, language: "en")
        XCTFail("Empty input reached the missing worker")
      } catch { XCTAssertEqual(error as? DesktopServiceError, .invalidValue) }
      for value in [
        "https://example.invalid/model.gguf", "file://remote.invalid/model.gguf",
        "file:///tmp/synthetic.gguf?token=synthetic", "file:///tmp/synthetic.gguf#fragment",
      ] {
        let invalid = NativeDesktopLanguageModel(
          model: try XCTUnwrap(URL(string: value)), executable: missing)
        do {
          _ = try await invalid.process(text: "Synthetic", task: .summary, language: "en")
          XCTFail("Nonlocal or decorated model URL reached the worker")
        } catch { XCTAssertEqual(error as? DesktopServiceError, .invalidValue) }
      }
      do {
        _ = try await processor.process(text: "Synthetic", task: .summary, language: "en")
        XCTFail("Missing worker succeeded")
      } catch { XCTAssertEqual(error as? DesktopServiceError, .unavailable) }
    }

    func testDeadlineAndCancellationRejectLateResults() async throws {
      let file = try fixture(
        "import pathlib,time\npathlib.Path(__file__ + '.ready').touch()\ntime.sleep(20)")
      let model = URL(fileURLWithPath: "/tmp/synthetic.gguf")
      let start = Date()
      do {
        _ = try await NativeDesktopLanguageModel(model: model, executable: file, timeout: 0.15)
          .process(text: "Synthetic", task: .summary, language: "en")
        XCTFail("Unresponsive worker succeeded")
      } catch { XCTAssertEqual(error as? DesktopServiceError, .unavailable) }
      XCTAssertLessThan(Date().timeIntervalSince(start), 3)
      let held = try fixture(
        "import pathlib,time\npathlib.Path(__file__ + '.ready').touch()\ntime.sleep(20)")
      let task = Task {
        try await NativeDesktopLanguageModel(model: model, executable: held)
          .process(text: "Synthetic", task: .summary, language: "en")
      }
      let ready = held.path + ".ready"
      let deadline = Date().addingTimeInterval(3)
      while !FileManager.default.fileExists(atPath: ready), Date() < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
      }
      XCTAssertTrue(FileManager.default.fileExists(atPath: ready))
      task.cancel()
      do {
        _ = try await task.value
        XCTFail("Cancelled worker succeeded")
      } catch { XCTAssertTrue(error is CancellationError) }
    }
  #endif
}
