import ClipboardCore
import Foundation

/// Trained language identification plus optional fixed-model entity tagging.
/// Text and the optional local model path travel only through private pipes.
public struct NativeDesktopTextTagger: DesktopLocalLanguageProcessing, Sendable {
  private let model: URL?
  private let executable: URL
  private let timeout: TimeInterval

  public init(model: URL? = nil, executable: URL? = nil, timeout: TimeInterval = 20) {
    self.model = model
    #if os(Windows)
      let name = "clipboard-text-worker.exe"
    #else
      let name = "clipboard-text-worker"
    #endif
    self.executable =
      executable
      ?? (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
      .deletingLastPathComponent().appendingPathComponent(name)
    self.timeout = timeout
  }

  public func process(text: String, task: DesktopLocalLanguageTask, language: String?) async throws
    -> DesktopLocalLanguageOutput
  {
    guard task == .enrichment else { throw DesktopServiceError.disabled }
    guard !text.isEmpty, text.utf8.count <= 65536 else { throw DesktopServiceError.invalidValue }
    let path: String?
    if let model {
      guard model.isFileURL, [nil, "", "localhost"].contains(model.host),
        let components = URLComponents(url: model, resolvingAgainstBaseURL: false),
        components.user == nil, components.password == nil,
        components.query == nil, components.fragment == nil,
        !model.path.contains("\0"), model.path.utf8.count <= 4096,
        let file = model.standardizedFileURL.withUnsafeFileSystemRepresentation({
          $0.map { String(cString: $0) }
        }), !file.contains("\0"), file.utf8.count <= 4096
      else { throw DesktopServiceError.invalidValue }
      path = file
    } else {
      path = nil
    }
    try Task.checkCancellation()
    // JSON null is required for language-only mode, rather than an absent key.
    let value: [String: Any] = [
      "model": path as Any? ?? NSNull(), "text": text, "task": task.rawValue,
    ]
    let data = try JSONSerialization.data(withJSONObject: value)
    do {
      let bytes = try await NativeDesktopByteWorker(
        executable: executable, timeout: timeout, inputLimit: 512 * 1024, outputLimit: 4096
      ).run(data)
      try Task.checkCancellation()
      let output = try DesktopLocalLanguageOutput(workerOutput: bytes)
      guard output.task == task else { throw DesktopServiceError.invalidValue }
      return output
    } catch DesktopServiceError.fileUnavailable {
      throw DesktopServiceError.unavailable
    }
  }
}
