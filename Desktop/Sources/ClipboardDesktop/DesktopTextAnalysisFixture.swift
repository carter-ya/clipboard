import ClipboardCore
import Foundation

/// Only a private smoke profile can delay/fail an analysis. Successful released
/// requests still invoke the supplied real native worker and fixed model.
enum DesktopTextAnalysisFixture {
  @MainActor private static var session: Session?
  @MainActor static func processor(
    _ native: any DesktopLocalLanguageProcessing, engine: DesktopLocalTextEngine
  ) -> any DesktopLocalLanguageProcessing {
    guard CommandLine.arguments.contains("--smoke-root"),
      CommandLine.arguments.contains("--smoke-local-text"),
      DesktopApplicationContext.profile != "production",
      let root = DesktopApplicationContext.dataRoot
    else { return native }
    let owner = session ?? Session(root: root)
    session = owner
    return Adapter(native: native, engine: engine, session: owner)
  }
  private struct Adapter: DesktopLocalLanguageProcessing {
    let native: any DesktopLocalLanguageProcessing
    let engine: DesktopLocalTextEngine
    let session: Session
    func process(text: String, task: DesktopLocalLanguageTask, language: String?) async throws
      -> DesktopLocalLanguageOutput
    {
      try await session.process(native, engine: engine, text: text, task: task, language: language)
    }
  }
  private actor Session {
    let root: URL
    var calls: [DesktopLocalTextEngine: Int] = [:]
    init(root: URL) { self.root = root }
    func process(
      _ native: any DesktopLocalLanguageProcessing, engine: DesktopLocalTextEngine,
      text: String, task: DesktopLocalLanguageTask, language: String?
    ) async throws -> DesktopLocalLanguageOutput {
      let count = (calls[engine] ?? 0) + 1
      calls[engine] = count
      let prefix = ".local-text-" + engine.rawValue
      defer {
        try? Data(String(count).utf8).write(
          to: root.appendingPathComponent(prefix + "-finished"), options: .atomic)
      }
      do {
        try Data(String(count).utf8).write(
          to: root.appendingPathComponent(prefix + "-started"), options: .atomic)
      } catch { throw DesktopServiceError.unavailable }
      let deadline = ContinuousClock.now.advanced(by: .seconds(60))
      while !FileManager.default.fileExists(
        atPath: root.appendingPathComponent(prefix + "-release").path)
      {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw DesktopServiceError.unavailable }
        try await Task.sleep(nanoseconds: 50_000_000)
      }
      try Task.checkCancellation()
      if count == 1 { throw DesktopServiceError.unavailable }
      return try await native.process(text: text, task: task, language: language)
    }
  }
}
