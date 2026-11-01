import ClipboardCore
import Foundation
import XCTest

@testable import DesktopServices

final class ModelCapabilityTests: XCTestCase {
  #if os(Linux)
    private func fixture(_ body: String) throws -> URL {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "private-capability-" + UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      addTeardownBlock { try? FileManager.default.removeItem(at: root) }
      let file = root.appendingPathComponent("worker")
      try Data(("#!/usr/bin/python3\n" + body + "\n").utf8).write(to: file)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
      return file
    }
    func testCapabilityQueryContainsNoTextOrModelAndChecksExactResponse() async throws {
      let file = try fixture(
        """
        import json,sys
        assert len(sys.argv)==1
        assert json.load(sys.stdin)=={'task':'capability'}
        json.dump({'available':True},sys.stdout)
        """)
      let language = try await NativeDesktopLanguageModel.isSupported(executable: file)
      let names = try await NativeDesktopTextTagger.isSupported(executable: file)
      XCTAssertTrue(language)
      XCTAssertTrue(names)
      for output in [
        "{}", "{\"available\":1}", "{\"available\":true,\"unexpected\":true}",
        "{\"available\":false}",
      ] {
        let invalid = try fixture(
          "import sys\nsys.stdin.buffer.read()\nsys.stdout.write(\(String(reflecting: output)))")
        let supported = try await NativeDesktopLanguageModel.isSupported(executable: invalid)
        XCTAssertFalse(supported)
      }
    }
    func testUnsupportedOrMissingWorkerDoesNotOfferADownload() async throws {
      let unsupported = try fixture("import sys\nsys.stdin.buffer.read()\nsys.exit(11)")
      let rejected = try await NativeDesktopLanguageModel.isSupported(executable: unsupported)
      XCTAssertFalse(rejected)
      let missing = unsupported.appendingPathExtension("absent")
      let absent = try await NativeDesktopTextTagger.isSupported(executable: missing)
      XCTAssertFalse(absent)
    }
    func testCancellingCapabilityQueryDrainsItsOwnedWorker() async throws {
      let file = try fixture(
        "import pathlib,time\npathlib.Path(__file__+'.ready').touch()\ntime.sleep(20)")
      let task = Task { try await NativeDesktopTextTagger.isSupported(executable: file) }
      let deadline = Date().addingTimeInterval(2)
      while !FileManager.default.fileExists(atPath: file.path + ".ready"), Date() < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
      }
      XCTAssertTrue(FileManager.default.fileExists(atPath: file.path + ".ready"))
      task.cancel()
      do {
        _ = try await task.value
        XCTFail("Capability cancellation was swallowed")
      } catch { XCTAssertTrue(error is CancellationError) }
    }
  #endif
}
