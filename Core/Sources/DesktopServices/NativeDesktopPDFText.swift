import ClipboardCore
import Foundation

/// Bounded PDF decoding using the shared owned-process transport.
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
    let bytes = try await NativeDesktopByteWorker(
      executable: executable, timeout: timeout,
      inputLimit: DesktopFileTextPolicy.maximumBytes,
      outputLimit: DesktopFileTextPolicy.maximumBytes
    ).run(data)
    guard let text = String(data: bytes, encoding: .utf8), !text.contains("\0"),
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw DesktopServiceError.invalidValue }
    return text
  }
}
