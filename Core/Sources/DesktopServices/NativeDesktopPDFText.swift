import CDesktopServices
import ClipboardCore
import Foundation

#if os(Linux)
  import Glibc
#endif

/// One owned process per PDF. Only bytes cross its pipes; no copied path, password,
/// document text or exception is placed in arguments, environment or diagnostics.
struct NativeDesktopPDFText: Sendable {
  let executable: URL
  let timeout: TimeInterval
  init(executable: URL? = nil, timeout: TimeInterval = 15) {
    #if os(Windows)
      let name = "clipboard-pdf-worker.exe"
    #else
      let name = "clipboard-pdf-worker"
    #endif
    self.executable =
      executable
      ?? (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
      .deletingLastPathComponent().appendingPathComponent(name)
    self.timeout = timeout
  }
  func text(from data: Data) async throws -> String {
    guard !data.isEmpty, data.count <= DesktopFileTextPolicy.maximumBytes else {
      throw DesktopServiceError.tooLarge
    }
    let run = PDFTextRun(executable: executable, timeout: timeout)
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      let text: String = try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
          continuation.resume(with: Result { try run.extract(data) })
        }
      }
      try Task.checkCancellation()
      return text
    } onCancel: {
      run.cancel()
    }
  }
}

private final class PDFTextRun: @unchecked Sendable {
  private let executable: URL
  private let timeout: TimeInterval
  private let lock = NSLock()
  private var process: Process?
  private var cancelled = false
  private var expired = false
  init(executable: URL, timeout: TimeInterval) {
    self.executable = executable
    self.timeout = timeout
  }
  func cancel() {
    lock.lock()
    defer { lock.unlock() }
    cancelled = true
    if let process { stopOwned(process) }
  }
  private func launch(_ next: Process) throws {
    lock.lock()
    defer { lock.unlock() }
    guard !cancelled else { throw CancellationError() }
    try next.run()
    process = next
  }
  private func expire() {
    lock.lock()
    defer { lock.unlock() }
    if let process, process.isRunning {
      expired = true
      stopOwned(process)
    }
  }
  private func stopOwned(_ child: Process) {
    guard child.isRunning else { return }
    #if os(Linux)
      // Only this owned decoder is killed; it has no user state to unwind.
      _ = Glibc.kill(child.processIdentifier, SIGKILL)
    #else
      child.terminate()
    #endif
  }
  private func checkState() throws {
    lock.lock()
    defer { lock.unlock() }
    if cancelled { throw CancellationError() }
    if expired { throw DesktopServiceError.fileUnavailable }
  }
  func extract(_ data: Data) throws -> String {
    let process = Process()
    process.executableURL = executable
    process.arguments = []
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
      try launch(process)
      let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
      timer.schedule(deadline: .now() + timeout)
      timer.setEventHandler { [weak self] in self?.expire() }
      timer.resume()
      defer {
        timer.cancel()
        try? input.fileHandleForWriting.close()
        stopOwned(process)
        process.waitUntilExit()
        try? output.fileHandleForReading.close()
        lock.lock()
        self.process = nil
        lock.unlock()
      }
      #if os(Linux)
        let written = data.withUnsafeBytes {
          cds_pdf_pipe_write(
            input.fileHandleForWriting.fileDescriptor,
            $0.bindMemory(to: UInt8.self).baseAddress, data.count)
        }
        guard written == 1 else { throw DesktopServiceError.fileUnavailable }
      #else
        try input.fileHandleForWriting.write(contentsOf: data)
      #endif
      try input.fileHandleForWriting.close()
      var bytes = Data()
      while let chunk = try output.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
        guard chunk.count <= DesktopFileTextPolicy.maximumBytes - bytes.count else {
          throw DesktopServiceError.tooLarge
        }
        bytes.append(chunk)
      }
      process.waitUntilExit()
      try checkState()
      if process.terminationStatus == 3 { throw DesktopServiceError.tooLarge }
      guard process.terminationReason == .exit, process.terminationStatus == 0,
        let text = String(data: bytes, encoding: .utf8), !text.contains("\0"),
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { throw DesktopServiceError.invalidValue }
      return text
    } catch {
      try checkState()
      if let error = error as? DesktopServiceError { throw error }
      if error is CancellationError { throw CancellationError() }
      throw DesktopServiceError.fileUnavailable
    }
  }
}
