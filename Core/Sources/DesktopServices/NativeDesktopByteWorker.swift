import CDesktopServices
import ClipboardCore
import Foundation

#if os(Linux)
  import Glibc
#endif

/// Shared bounded private-pipe ownership for the PDF and image workers. Never
/// place copied paths/content in arguments, environment or error diagnostics.
struct NativeDesktopByteWorker: Sendable {
  let executable: URL
  let timeout: TimeInterval
  let inputLimit: Int
  let outputLimit: Int
  var unavailableExitCodes: Set<Int32> = []

  func run(_ data: Data) async throws -> Data {
    guard (1...(16 * 1024 * 1024)).contains(inputLimit),
      (1...(1024 * 1024)).contains(outputLimit), timeout.isFinite, timeout > 0
    else { throw DesktopServiceError.invalidValue }
    guard !data.isEmpty, data.count <= inputLimit else { throw DesktopServiceError.tooLarge }
    let run = DesktopByteWorkerRun(
      executable: executable, timeout: timeout, outputLimit: outputLimit,
      unavailableExitCodes: unavailableExitCodes)
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      let bytes: Data = try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
          continuation.resume(with: Result { try run.extract(data) })
        }
      }
      try Task.checkCancellation()
      return bytes
    } onCancel: {
      run.cancel()
    }
  }
}

private final class DesktopByteWorkerRun: @unchecked Sendable {
  private let executable: URL
  private let timeout: TimeInterval
  private let outputLimit: Int
  private let unavailableExitCodes: Set<Int32>
  private let lock = NSLock()
  private var process: Process?
  private var cancelled = false
  private var expired = false
  init(executable: URL, timeout: TimeInterval, outputLimit: Int, unavailableExitCodes: Set<Int32>) {
    self.executable = executable
    self.timeout = timeout
    self.outputLimit = outputLimit
    self.unavailableExitCodes = unavailableExitCodes
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
  func extract(_ data: Data) throws -> Data {
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
          cds_worker_pipe_write(
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
        guard chunk.count <= outputLimit - bytes.count else {
          throw DesktopServiceError.tooLarge
        }
        bytes.append(chunk)
      }
      process.waitUntilExit()
      try checkState()
      if process.terminationReason == .exit,
        unavailableExitCodes.contains(process.terminationStatus)
      {
        throw DesktopServiceError.unavailable
      }
      if process.terminationStatus == 3 { throw DesktopServiceError.tooLarge }
      guard process.terminationReason == .exit, process.terminationStatus == 0 else {
        throw DesktopServiceError.invalidValue
      }
      return bytes
    } catch {
      try checkState()
      if let error = error as? DesktopServiceError { throw error }
      if error is CancellationError { throw CancellationError() }
      throw DesktopServiceError.fileUnavailable
    }
  }
}
