#if os(Linux)
  import ClipboardCore
  import Foundation
  import XCTest

  @testable import DesktopServices

  final class NativeImageProcessTests: XCTestCase {
    private func fixture(_ body: String) throws -> URL {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "private-image-process-" + UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      addTeardownBlock { try? FileManager.default.removeItem(at: root) }
      let file = root.appendingPathComponent("worker")
      try Data(("#!/usr/bin/python3\n" + body + "\n").utf8).write(to: file)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
      return file
    }
    func testOnlySuccessfulBoundedClassificationMetadataIsAccepted() async throws {
      let file = try fixture(
        "import sys\nsys.stdin.buffer.read()\nsys.stdout.write('{\"width\":2,\"height\":3,\"labels\":[]}')"
      )
      let result = try await NativeDesktopImageClassifier(executable: file).classify(Data([1]))
      XCTAssertEqual(result.summary, "Image (2×3)")
      for body in [
        "import sys\nsys.stdout.write('{\"width\":2,\"height\":3,\"labels\":[]}')\nsys.exit(4)",
        "import sys\nsys.stdout.write('{}')",
      ] {
        let invalid = try fixture(body)
        do {
          _ = try await NativeDesktopImageClassifier(executable: invalid).classify(Data([1]))
          XCTFail("Failed or malformed metadata was accepted")
        } catch { XCTAssertEqual(error as? DesktopServiceError, .invalidValue) }
      }
    }
    func testOutputAndInputBudgetsAreIndependent() async throws {
      let file = try fixture("import sys\nsys.stdin.buffer.read()\nsys.stdout.write('x' * 4097)")
      do {
        _ = try await NativeDesktopImageClassifier(executable: file).classify(Data([1]))
        XCTFail("Excess worker metadata was accepted")
      } catch { XCTAssertEqual(error as? DesktopServiceError, .tooLarge) }
      let missing = file.deletingLastPathComponent().appendingPathComponent("not-an-executable")
      do {
        _ = try await NativeDesktopImageClassifier(executable: missing).classify(
          Data(repeating: 1, count: 16 * 1024 * 1024 + 1))
        XCTFail("Excess image reached process launch")
      } catch { XCTAssertEqual(error as? DesktopServiceError, .tooLarge) }
    }
    func testDeadlineAndCancellationReapOnlyTheOwnedWorker() async throws {
      let file = try fixture(
        "import pathlib,time\npathlib.Path(__file__ + '.ready').touch()\ntime.sleep(20)")
      let start = Date()
      do {
        _ = try await NativeDesktopImageClassifier(executable: file, timeout: 0.15).classify(
          Data([1]))
        XCTFail("Unresponsive classifier succeeded")
      } catch { XCTAssertEqual(error as? DesktopServiceError, .unavailable) }
      XCTAssertLessThan(Date().timeIntervalSince(start), 3)
      let held = try fixture(
        "import pathlib,time\npathlib.Path(__file__ + '.ready').touch()\ntime.sleep(20)")
      let task = Task {
        try await NativeDesktopImageClassifier(executable: held).classify(
          Data(repeating: 1, count: 16 * 1024 * 1024))
      }
      let ready = held.path + ".ready"
      let deadline = Date().addingTimeInterval(3)
      while !FileManager.default.fileExists(atPath: ready), Date() < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
      }
      XCTAssertTrue(FileManager.default.fileExists(atPath: ready))
      let cancellationStart = Date()
      task.cancel()
      do {
        _ = try await task.value
        XCTFail("Cancelled classifier succeeded")
      } catch { XCTAssertTrue(error is CancellationError) }
      XCTAssertLessThan(Date().timeIntervalSince(cancellationStart), 3)
    }
  }
#endif
