import ClipboardCore
import Foundation

/// One owned, cancellable CPU worker; no model/image path is supplied by callers.
public struct NativeDesktopImageClassifier: DesktopImageClassifying, Sendable {
  private let executable: URL
  private let timeout: TimeInterval
  public init(executable: URL? = nil, timeout: TimeInterval = 15) {
    #if os(Windows)
      let name = "clipboard-image-worker.exe"
    #else
      let name = "clipboard-image-worker"
    #endif
    self.executable =
      executable
      ?? (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
      .deletingLastPathComponent().appendingPathComponent(name)
    self.timeout = timeout
  }

  public func classify(_ image: Data) async throws -> DesktopImageClassification {
    do {
      let bytes = try await NativeDesktopByteWorker(
        executable: executable, timeout: timeout, inputLimit: 16 * 1024 * 1024,
        outputLimit: 4096
      ).run(image)
      try Task.checkCancellation()
      return try DesktopImageClassification(workerOutput: bytes)
    } catch DesktopServiceError.fileUnavailable {
      throw DesktopServiceError.unavailable
    }
  }
}
