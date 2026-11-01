import ClipboardCore
import Foundation

/// CPU inference with a fixed, independently verified model. Both the asset
/// path and text travel only through owned private pipes, never arguments/logs.
public struct NativeDesktopLanguageModel: DesktopLocalLanguageProcessing, Sendable {
  private let model: URL
  private let executable: URL
  private let timeout: TimeInterval

  public init(model: URL, executable: URL? = nil, timeout: TimeInterval = 90) {
    self.model = model
    #if os(Windows)
      let name = "clipboard-language-worker.exe"
    #else
      let name = "clipboard-language-worker"
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
    guard task == .summary else { throw DesktopServiceError.disabled }
    guard model.isFileURL, [nil, "", "localhost"].contains(model.host),
      let components = URLComponents(url: model, resolvingAgainstBaseURL: false),
      components.user == nil, components.password == nil,
      components.query == nil, components.fragment == nil,
      !model.path.contains("\0"), model.path.utf8.count <= 4096,
      !text.isEmpty, text.utf8.count <= 65536
    else { throw DesktopServiceError.invalidValue }
    guard
      let path = model.standardizedFileURL.withUnsafeFileSystemRepresentation({
        $0.map { String(cString: $0) }
      }), !path.contains("\0"), path.utf8.count <= 4096
    else {
      throw DesktopServiceError.invalidValue
    }
    try Task.checkCancellation()
    struct Input: Encodable {
      let model: String
      let text: String
      let task: DesktopLocalLanguageTask
      let language: String?
    }
    let responseTag =
      language.flatMap { $0.isEmpty || $0 == "system" ? nil : $0 }
      ?? DesktopUILanguage.resolve(override: nil).rawValue
    let data = try JSONEncoder().encode(
      Input(
        model: path, text: text, task: task,
        language: remoteAIResponseLanguageName(for: responseTag)))
    do {
      let bytes = try await NativeDesktopByteWorker(
        executable: executable, timeout: timeout, inputLimit: 512 * 1024, outputLimit: 4096,
        unavailableExitCodes: [3, 11]
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
