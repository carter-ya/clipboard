#if os(Linux)
  import ClipboardCore
  import Foundation
  import XCTest

  @testable import DesktopServices

  final class NativePDFProcessTests: XCTestCase {
    private func fixture(_ body: String) throws -> URL {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "private-pdf-process-" + UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      addTeardownBlock { try? FileManager.default.removeItem(at: root) }
      let file = root.appendingPathComponent("worker")
      try Data(("#!/usr/bin/python3\n" + body + "\n").utf8).write(to: file)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
      return file
    }
    func testCompletedPipeReturnsOnlyValidatedUTF8() async throws {
      let file = try fixture(
        "import sys\nsys.stdin.buffer.read()\nsys.stdout.write('Synthetic PDF text')")
      let text = try await NativeDesktopPDFText(executable: file).text(
        from: Data([37, 80, 68, 70]))
      XCTAssertEqual(text, "Synthetic PDF text")
      let failure = try fixture(
        "import sys\nsys.stdin.buffer.read()\nsys.stdout.write('partial text')\nsys.exit(4)")
      do {
        _ = try await NativeDesktopPDFText(executable: failure).text(from: Data([37]))
        XCTFail("Partial failed extraction accepted")
      } catch { XCTAssertEqual(error as? DesktopServiceError, .invalidValue) }
    }
    func testExcessOutputCannotEscapeByteLimit() async throws {
      let file = try fixture(
        "import sys\nsys.stdin.buffer.read()\nsys.stdout.buffer.write(b'x' * (1024 * 1024 + 1))")
      do {
        _ = try await NativeDesktopPDFText(executable: file).text(from: Data([37]))
        XCTFail("Excess output accepted")
      } catch { XCTAssertEqual(error as? DesktopServiceError, .tooLarge) }
    }
    func testWorkerDeadlineStopsAnUnresponsiveChild() async throws {
      let file = try fixture("import time\ntime.sleep(20)")
      let start = Date()
      do {
        _ = try await NativeDesktopPDFText(executable: file, timeout: 0.15).text(from: Data([37]))
        XCTFail("Unresponsive worker accepted")
      } catch { XCTAssertEqual(error as? DesktopServiceError, .fileUnavailable) }
      XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
    func testCancellationDuringBlockedInputReapsTheOwnedWorker() async throws {
      let file = try fixture(
        "import pathlib,time\npathlib.Path(__file__ + '.ready').touch()\ntime.sleep(20)")
      let task = Task {
        try await NativeDesktopPDFText(executable: file).text(
          from: Data(repeating: 65, count: DesktopFileTextPolicy.maximumBytes))
      }
      let ready = file.path + ".ready"
      let deadline = Date().addingTimeInterval(3)
      while !FileManager.default.fileExists(atPath: ready), Date() < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
      }
      XCTAssertTrue(FileManager.default.fileExists(atPath: ready))
      let start = Date()
      task.cancel()
      do {
        _ = try await task.value
        XCTFail("Cancelled worker accepted")
      } catch {
        XCTAssertTrue(error is CancellationError)
      }
      XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
  }
#endif
