import ClipboardCore
import Foundation
import XCTest

@testable import DesktopServices

final class NativeTextTaggerTests: XCTestCase {
  func testRealNativeLanguageAndEntitiesWhenExplicitlyConfigured() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let worker = environment["CLIPBOARD_TEST_TEXT_WORKER"],
      let model = environment["CLIPBOARD_TEST_ENTITY_MODEL"]
    else { throw XCTSkip("Explicit native entity fixture is not configured") }
    let text =
      "Apple Inc. CEO Tim Cook met officials in Tokyo to discuss the company investment. "
      + "The meeting focused on the research center and jobs for local engineers."
    let executable = URL(fileURLWithPath: worker)
    let languageOnly = try await NativeDesktopTextTagger(executable: executable)
      .process(text: text, task: .enrichment, language: "en")
    XCTAssertEqual(languageOnly.languageCode, "en")
    XCTAssertTrue(languageOnly.entities.isEmpty)
    let result = try await NativeDesktopTextTagger(
      model: URL(fileURLWithPath: model), executable: executable
    )
    .process(text: text, task: .enrichment, language: "en")
    XCTAssertEqual(result.languageCode, "en")
    XCTAssertTrue(result.entities.contains("Tim Cook"))
    XCTAssertTrue(result.entities.contains("Tokyo"))
    XCTAssertFalse(result.entities.contains("research center"))
    XCTAssertFalse(result.inputTruncated)
  }

  #if os(Linux)
    private func fixture(_ body: String) throws -> URL {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "private-text-tagger-" + UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      addTeardownBlock { try? FileManager.default.removeItem(at: root) }
      let file = root.appendingPathComponent("worker")
      try Data(("#!/usr/bin/python3\n" + body + "\n").utf8).write(to: file)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
      return file
    }

    func testPrivateJSONHasExplicitNullAndUnicodeModelPaths() async throws {
      let file = try fixture(
        """
        import json,sys
        assert len(sys.argv) == 1
        value=json.load(sys.stdin)
        assert set(value)=={'model','text','task'}
        assert value['task']=='enrichment' and value['text']=='合成🙂text'
        assert value['model'] in (None,'/tmp/private 模型.onnx')
        json.dump({'task':'enrichment','language':'zh-Hant','entities':['合成'],'inputTruncated':False},sys.stdout)
        """)
      for model in [nil, URL(fileURLWithPath: "/tmp/private 模型.onnx")] {
        let result = try await NativeDesktopTextTagger(model: model, executable: file)
          .process(text: "合成🙂text", task: .enrichment, language: "en")
        XCTAssertEqual(result.languageCode, "zh-Hant")
        XCTAssertEqual(result.entities, ["合成"])
      }
    }

    func testUnsupportedTaskInvalidURLAndFailedOutputAreRefused() async throws {
      let missing = URL(fileURLWithPath: "/tmp/private-tagger-missing-" + UUID().uuidString)
      do {
        _ = try await NativeDesktopTextTagger(executable: missing)
          .process(text: "Synthetic", task: .summary, language: "en")
        XCTFail("A tagger accepted the generative task")
      } catch { XCTAssertEqual(error as? DesktopServiceError, .disabled) }
      for value in [
        "https://example.invalid/model.onnx", "file://remote.invalid/model.onnx",
        "file:///tmp/model.onnx?token=synthetic",
      ] {
        do {
          _ = try await NativeDesktopTextTagger(
            model: try XCTUnwrap(URL(string: value)), executable: missing
          )
          .process(text: "Synthetic", task: .enrichment, language: "en")
          XCTFail("An invalid model URL reached launch")
        } catch { XCTAssertEqual(error as? DesktopServiceError, .invalidValue) }
      }
      let file = try fixture(
        "import json,sys\njson.load(sys.stdin)\njson.dump({'task':'summary','summary':'Wrong task','entities':[],'inputTruncated':False},sys.stdout)"
      )
      do {
        _ = try await NativeDesktopTextTagger(executable: file)
          .process(text: "Synthetic", task: .enrichment, language: "en")
        XCTFail("Wrong result task was accepted")
      } catch { XCTAssertEqual(error as? DesktopServiceError, .invalidValue) }
      let failed = try fixture(
        "import sys\nsys.stdin.buffer.read()\nsys.stdout.write('{}')\nsys.exit(2)")
      do {
        _ = try await NativeDesktopTextTagger(executable: failed)
          .process(text: "Synthetic", task: .enrichment, language: "en")
        XCTFail("Failed worker was accepted")
      } catch { XCTAssertEqual(error as? DesktopServiceError, .invalidValue) }
    }

    func testDeadlineCancellationAndOutputBounds() async throws {
      let held = try fixture(
        "import pathlib,time\npathlib.Path(__file__+'.ready').touch()\ntime.sleep(20)")
      do {
        _ = try await NativeDesktopTextTagger(executable: held, timeout: 0.15)
          .process(text: "Synthetic", task: .enrichment, language: "en")
        XCTFail("Unresponsive tagger succeeded")
      } catch { XCTAssertEqual(error as? DesktopServiceError, .unavailable) }
      let large = try fixture("import sys\nsys.stdin.buffer.read()\nsys.stdout.write('x'*4097)")
      do {
        _ = try await NativeDesktopTextTagger(executable: large)
          .process(text: "Synthetic", task: .enrichment, language: "en")
        XCTFail("Unbounded metadata was accepted")
      } catch { XCTAssertEqual(error as? DesktopServiceError, .tooLarge) }
      let paused = try fixture(
        "import pathlib,time\npathlib.Path(__file__+'.ready').touch()\ntime.sleep(20)")
      let task = Task {
        try await NativeDesktopTextTagger(executable: paused)
          .process(text: "Synthetic", task: .enrichment, language: "en")
      }
      let ready = paused.path + ".ready"
      let deadline = Date().addingTimeInterval(3)
      while !FileManager.default.fileExists(atPath: ready), Date() < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
      }
      XCTAssertTrue(FileManager.default.fileExists(atPath: ready))
      task.cancel()
      do {
        _ = try await task.value
        XCTFail("Cancelled tagger succeeded")
      } catch { XCTAssertTrue(error is CancellationError) }
    }
  #endif
}
